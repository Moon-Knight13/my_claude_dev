#!/usr/bin/env bash
# eval-set.sh — the operator-owned sensitivity eval set: check it, freeze its
# held-out split, draft cases with a local model, and export it encrypted
# (SP1a story 1.1; FR-35, FR-38, FR-50, NFR-5, NFR-7).
#
# The eval set measures how often the classifier misses sensitive content. That
# number is only honest if three things hold, and this tool enforces them:
#   1. The held-out split is written by the operator and frozen by digest before
#      any tuning, so the classifier is never scored on cases it was tuned on.
#   2. Every case is labelled by the operator. A local model may draft tuning
#      cases, but never the held-out split, never as a classifier candidate, and
#      no cloud model may author a case at all.
#   3. The fixtures stay on the hub. They describe real sensitive material, so
#      nothing here prints case text, and they leave the hub only encrypted.
#
# Usage: eval-set.sh [--config-dir DIR] <command> [options]
#   validate                 check the whole set against every rule
#   freeze [--reason R]      record the held-out digest (R: initial | leaked)
#   frozen-check             exit 0 only if the held-out split matches its freeze
#   draft [--category C]     draft one unlabelled case from the request on stdin
#   export --out FILE        write the store as one gpg-encrypted archive
#
# Config: <config-dir>/lane2.conf (default config dir /etc/lane2), parsed, never
# sourced; the last assignment wins, except LANE2_EVAL_CANDIDATE, which repeats.
# The config directory is a flag, not an environment variable: hub tools read no
# security-relevant setting from the environment (architecture conventions).
#
# Store: <LANE2_STATE_ROOT>/eval/ (mode 0700, files 0600) holding tuning.jsonl,
# heldout.jsonl, freeze.jsonl, drafts.jsonl. Case format: docs/SP1A_EVAL_SET.md.
#
# Exit: 0 ok, 2 usage, 3 rule failed or refused, >=4 fault. Callers treat
# anything but 0 as "do not run the eval".
#
# Refusing inside a container is defence in depth, not the boundary: the
# container never has the eval store mounted (AD-7), so there is nothing to read.
set -euo pipefail

EVALSET_CATEGORIES=(plain obfuscated buried-5k buried-20k multi-block inference adversarial)
EVALSET_MAX_STDIN=65536          # bytes read from a draft request
EVALSET_MAX_RESPONSE=1048576     # bytes read from the drafting model

ok()   { printf '  OK  %s\n' "$1"; }
fail() { printf ' FAIL %s\n' "$1"; }
die()  { printf ' FAIL %s\n' "$2" >&2; exit "$1"; }

# --- environment -------------------------------------------------------------

evalset_in_container() {
    [[ -f /.dockerenv || -f /run/.containerenv ]] && return 0
    [[ -n "${DEVCONTAINER:-}${REMOTE_CONTAINERS:-}${CODESPACES:-}${container:-}" ]] && return 0
    grep -qE 'docker|containerd|kubepods|lxc|libpod' /proc/1/cgroup 2>/dev/null && return 0
    return 1
}

# evalset_load_config <file> — sets EVALSET_CONF[KEY] (last wins) and
# EVALSET_CANDIDATES (every LANE2_EVAL_CANDIDATE line, in order).
declare -A EVALSET_CONF=()
EVALSET_CANDIDATES=()
evalset_load_config() {
    local file="$1" line key val
    EVALSET_CONF=(); EVALSET_CANDIDATES=()
    [[ -f "$file" ]] || return 0
    [[ -r "$file" ]] || die 4 "config unreadable: $file"
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        [[ "$line" =~ ^[[:space:]]*([A-Z0-9_]+)=(.*)$ ]] || continue
        key="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"
        case "$val" in
            \"*\") val="${val%\"}"; val="${val#\"}" ;;
            \'*\') val="${val%\'}"; val="${val#\'}" ;;
            *) val="${val%%[[:space:]]#*}"; val="${val%"${val##*[![:space:]]}"}" ;;
        esac
        if [[ "$key" == LANE2_EVAL_CANDIDATE ]]; then
            EVALSET_CANDIDATES+=("$val")
        else
            EVALSET_CONF["$key"]="$val"
        fi
    done < "$file"
}

conf() { printf '%s' "${EVALSET_CONF[$1]:-${2:-}}"; }

# --- store -------------------------------------------------------------------

# evalset_store [create] — prints the eval store path after checking its modes.
# A looser mode or a foreign owner is a fault, never a silent chmod.
evalset_store() {
    local root store f mode
    root="$(conf LANE2_STATE_ROOT /var/lib/lane2)"
    store="$root/eval"
    if [[ ! -d "$store" ]]; then
        [[ "${1:-}" == create ]] || die 4 "no eval store at $store"
        [[ -d "$root" ]] || die 4 "state root missing: $root"
        mkdir -m 700 "$store" 2>/dev/null || die 4 "cannot create eval store: $store"
    fi
    [[ -L "$store" ]] && die 4 "eval store is a symlink: $store"
    mode="$(stat -c '%a %u' "$store")"
    [[ "$mode" == "700 $(id -u)" ]] || die 4 "eval store must be mode 0700 and owned by you (is $mode): $store"
    for f in "$store"/*; do
        [[ -e "$f" ]] || continue
        [[ -L "$f" ]] && die 4 "symlink in eval store: ${f##*/}"
        mode="$(stat -c '%a' "$f")"
        [[ "$mode" == 600 || "$mode" == 400 ]] || die 4 "store file must be mode 0600 (is $mode): ${f##*/}"
    done
    printf '%s' "$store"
}

evalset_lock() { # evalset_lock <store> — one writer at a time, bounded wait
    exec 9>>"$1/.lock"
    chmod 600 "$1/.lock"
    flock -w 10 9 || die 4 "eval store is locked by another command"
}

# Digest of the canonicalised held-out file: every case as sorted-key compact
# JSON, lines sorted, so whitespace and line order do not change it.
evalset_digest() {
    local canon
    canon="$(jq -cS . "$1" 2>/dev/null)" || die 4 "held-out split is not valid JSON lines"
    printf '%s\n' "$canon" | sed '/^$/d' | LC_ALL=C sort | sha256sum | cut -d' ' -f1
}

# --- sizing ------------------------------------------------------------------

# evalset_cp_required <bound-percent> <misses> — smallest number of sensitive
# held-out cases for which <misses> misses still give a one-sided 95%
# Clopper-Pearson upper bound <= bound. That is the smallest n with
# P(X <= misses | n, bound) <= 0.05.
evalset_cp_required() {
    awk -v b="$1" -v k="$2" 'BEGIN {
        p = b / 100; q = 1 - p
        for (n = k + 1; n <= 10000000; n++) {
            t = exp(n * log(q)); s = t
            for (i = 1; i <= k; i++) { t = t * (n - i + 1) / i * p / q; s += t }
            if (s <= 0.05) { print n; exit }
        }
        exit 1
    }'
}

# --- validation --------------------------------------------------------------

# evalset_stats <tuning> <heldout> — one JSON object of counts. Never case text.
evalset_stats() {
    local cats
    cats="$(printf '%s\n' "${EVALSET_CATEGORIES[@]}" | jq -R . | jq -sc .)"
    jq -n --argjson cats "$cats" \
          --slurpfile t "$1" --slurpfile h "$2" '
      def nonempty_str: type == "string" and length > 0;
      def bad_format:
          (type != "object")
          or ((.id | nonempty_str) | not)
          or ((.category | IN($cats[])) | not)
          or (.label != null and ((.label | IN("sensitive", "nonsensitive")) | not))
          or ((.hard_negative | type) != "boolean")
          or (.hard_negative == true and .label == "sensitive")
          or (.split != ._file)
          or (if .category == "multi-block"
              then ((.blocks | type) != "array") or ((.blocks | length) < 2)
                   or ([.blocks[] | nonempty_str] | all | not)
              else ((.prompt | nonempty_str) | not) end);
      def good_provenance:
          (.provenance | type) == "string"
          and (.provenance == "operator" or (.provenance | test("^local:[^@\\s]+@[0-9a-f]{64}$")));
      ([$t[] | objects | . + {_file: "tuning"}] + [$h[] | objects | . + {_file: "heldout"}]) as $all
      | ([$t[], $h[]] | map(select(type != "object")) | length) as $nonobj
      | [$all[] | select(.label == "nonsensitive")] as $neg
      | [$all[] | select(.label == "sensitive")] as $pos
      | [$pos[] | select(.category != "adversarial")] as $mix
      | {
          cases: (($all | length) + $nonobj),
          tuning: ($t | length), heldout: ($h | length),
          bad_format: (([$all[] | select(bad_format)] | length) + $nonobj),
          dup_ids: ([$all[].id] | group_by(.) | map(select(length > 1)) | length),
          bad_provenance: ([$all[] | select(good_provenance | not)] | length),
          unlabelled: ([$all[] | select(.labelled_by != "operator" or .label == null)] | length),
          heldout_not_operator: ([$all[] | select(._file == "heldout" and .provenance != "operator")] | length),
          nonsensitive: ($neg | length),
          hard_negatives: ([$neg[] | select(.hard_negative == true)] | length),
          missing: [ $cats[] as $c | ("tuning", "heldout") as $s
                     | select([$pos[] | select(.category == $c and ._file == $s)] | length == 0)
                     | "\($c)/\($s)" ],
          missing_heldout: [ $cats[] as $c
                     | select([$pos[] | select(.category == $c and ._file == "heldout")] | length == 0)
                     | $c ],
          mix_total: ($mix | length),
          mix: {
            plain:         ([$mix[] | select(.category == "plain")] | length),
            obfuscated:    ([$mix[] | select(.category == "obfuscated")] | length),
            buried:        ([$mix[] | select(.category | IN("buried-5k", "buried-20k"))] | length),
            "multi-block": ([$mix[] | select(.category == "multi-block")] | length),
            inference:     ([$mix[] | select(.category == "inference")] | length)
          },
          heldout_sensitive: ([$pos[] | select(._file == "heldout")] | length)
        }'
}

# evalset_check <scope> <tuning> <heldout> — print one line per rule; scope is
# "all" (validate) or "heldout" (the rules that apply before freezing).
# Returns 0 when every rule passes, 3 otherwise.
evalset_check() {
    local scope="$1" st bound misses need n v failed=0
    st="$(evalset_stats "$2" "$3" 2>/dev/null)" || die 4 "eval set is not valid JSON lines"
    S() { jq -r "$1" <<<"$st"; }

    rule() { # rule <ok:0|1> <text>
        if [[ "$1" == 1 ]]; then ok "$2"; else fail "$2"; failed=1; fi
    }
    zero() { [[ "$(S "$1")" == 0 ]] && echo 1 || echo 0; }

    rule "$(zero .bad_format)" "case format: $(S .bad_format) of $(S .cases) case(s) malformed"
    rule "$(zero .dup_ids)" "case ids unique: $(S .dup_ids) duplicated id(s)"
    rule "$(zero .bad_provenance)" "provenance is operator or local:<model>@<sha256>: $(S .bad_provenance) case(s) other"
    rule "$(zero .unlabelled)" "every case operator-labelled: $(S .unlabelled) case(s) not"
    rule "$(zero .heldout_not_operator)" "held-out cases operator-written: $(S .heldout_not_operator) case(s) not"

    if [[ "$scope" == all ]]; then
        n="$(S .nonsensitive)"
        rule "$( (( n >= 100 )) && echo 1 || echo 0)" "non-sensitive cases >= 100: $n"
        v="$(S .hard_negatives)"
        rule "$( (( n > 0 && v * 100 >= n * 40 )) && echo 1 || echo 0)" \
             "hard negatives >= 40% of non-sensitive: $v of $n"
        v="$(S '.missing | join(", ")')"
        rule "$( [[ -z "$v" ]] && echo 1 || echo 0)" \
             "every category has a sensitive case in each split${v:+: missing $v}"
        local total g c target mixok=1 detail=""
        total="$(S .mix_total)"
        for g in plain:30 obfuscated:20 buried:15 multi-block:15 inference:20; do
            target="${g#*:}"; g="${g%%:*}"
            c="$(S ".mix[\"$g\"]")"
            detail+="$g $c, "
            # |100*c/total - target| <= 5, in integers
            (( total > 0 )) || { mixok=0; continue; }
            v=$(( 100 * c - target * total ))
            (( v < 0 )) && v=$(( -v ))
            (( v <= 5 * total )) || mixok=0
        done
        rule "$mixok" "sensitive mix within 5 points of 30/20/15/15/20 (of $total: ${detail%, })"
    else
        v="$(S '.missing_heldout | join(", ")')"
        rule "$( [[ -z "$v" ]] && echo 1 || echo 0)" \
             "every category has a sensitive held-out case${v:+: missing $v}"
    fi

    bound="$(conf LANE2_EVAL_MISS_BOUND 10)"
    misses="$(conf LANE2_EVAL_HELDOUT_MISSES 0)"
    if ! [[ "$bound" =~ ^[0-9]+(\.[0-9]+)?$ ]] \
        || ! awk -v b="$bound" 'BEGIN { exit !(b > 0 && b < 100) }'; then
        die 4 "LANE2_EVAL_MISS_BOUND must be a percentage between 0 and 100"
    fi
    [[ "$misses" =~ ^[012]$ ]] || die 4 "LANE2_EVAL_HELDOUT_MISSES must be 0, 1 or 2"
    need="$(evalset_cp_required "$bound" "$misses")" || die 4 "cannot size the held-out split"
    n="$(S .heldout_sensitive)"
    rule "$( (( n >= need )) && echo 1 || echo 0)" \
         "held-out sensitive cases for a <= ${bound}% bound at $misses miss(es): required $need, have $n"

    unset -f S rule zero
    return $(( failed ? 3 : 0 ))
}

# Files for the check; a missing split counts as empty.
evalset_split_file() {
    if [[ -f "$1" ]]; then printf '%s' "$1"; else printf '%s' /dev/null; fi
}

# --- commands ----------------------------------------------------------------

cmd_validate() {
    (( $# == 0 )) || die 2 "usage: eval-set.sh validate"
    local store rc=0
    store="$(evalset_store)"
    echo "== eval set: validate =="
    evalset_check all "$(evalset_split_file "$store/tuning.jsonl")" \
                      "$(evalset_split_file "$store/heldout.jsonl")" || rc=$?
    (( rc == 0 )) && echo "eval set valid." || echo "eval set invalid."
    return "$rc"
}

evalset_last_freeze() { # prints the last freeze record, or nothing
    local f="$1/freeze.jsonl"
    [[ -s "$f" ]] || return 0
    jq -ce . "$f" >/dev/null 2>&1 || die 4 "freeze record is not valid JSON lines"
    tail -n 1 "$f"
}

cmd_freeze() {
    local reason=initial store held last digest count prev rc=0
    while (( $# )); do
        case "$1" in
            --reason) reason="${2:-}"; shift 2 || die 2 "usage: eval-set.sh freeze [--reason initial|leaked]" ;;
            *) die 2 "usage: eval-set.sh freeze [--reason initial|leaked]" ;;
        esac
    done
    [[ "$reason" == initial || "$reason" == leaked ]] || die 2 "reason must be initial or leaked"

    store="$(evalset_store)"
    held="$store/heldout.jsonl"
    [[ -s "$held" ]] || die 4 "no held-out split at $held"
    evalset_lock "$store"

    last="$(evalset_last_freeze "$store")"
    if [[ -n "$last" && "$reason" == initial ]]; then
        fail "held-out split already frozen; re-freeze only with --reason leaked"
        return 3
    fi
    if [[ -z "$last" && "$reason" == leaked ]]; then
        fail "nothing to re-freeze: no freeze record exists; freeze with reason initial"
        return 3
    fi

    echo "== eval set: freeze ($reason) =="
    evalset_check heldout /dev/null "$held" || rc=$?
    if (( rc != 0 )); then
        fail "held-out split invalid; not frozen"
        return "$rc"
    fi

    digest="$(evalset_digest "$held")"
    prev=""
    [[ -n "$last" ]] && prev="$(jq -r .digest <<<"$last")"
    if [[ "$digest" == "$prev" ]]; then
        fail "held-out split unchanged since the last freeze; replace the leaked cases first"
        return 3
    fi
    count="$(jq -s length "$held")"
    (
        umask 077
        jq -nc --arg digest "$digest" --argjson cases "$count" --arg reason "$reason" \
               --arg time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg previous "$prev" \
               '{time: $time, digest: $digest, cases: $cases, reason: $reason,
                 previous: (if $previous == "" then null else $previous end)}' \
            >> "$store/freeze.jsonl"
    )
    chmod 600 "$store/freeze.jsonl"
    ok "held-out split frozen: $count case(s), digest $digest"
}

cmd_frozen_check() {
    (( $# == 0 )) || die 2 "usage: eval-set.sh frozen-check"
    local store held last digest want
    store="$(evalset_store)"
    held="$store/heldout.jsonl"
    last="$(evalset_last_freeze "$store")"
    if [[ -z "$last" ]]; then
        fail "held-out split not frozen: no freeze record"
        return 3
    fi
    [[ -s "$held" ]] || { fail "held-out split missing"; return 3; }
    want="$(jq -r .digest <<<"$last")"
    digest="$(evalset_digest "$held")"
    if [[ "$digest" != "$want" ]]; then
        fail "held-out split changed since it was frozen"
        return 3
    fi
    ok "held-out split matches its freeze record"
}

# A drafting endpoint must be plain http on loopback: no userinfo, no other host.
evalset_loopback() {
    [[ "$1" =~ ^http://(127\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|localhost|\[::1\])(:[0-9]{1,5})?(/[^@]*)?$ ]]
}

cmd_draft() {
    local category="" model sha endpoint cand cid csha store body resp content id
    while (( $# )); do
        case "$1" in
            --category) category="${2:-}"; shift 2 || die 2 "usage: eval-set.sh draft [--category C]" ;;
            *) die 2 "usage: eval-set.sh draft [--category C] < request" ;;
        esac
    done
    if [[ -n "$category" ]]; then
        printf '%s\n' "${EVALSET_CATEGORIES[@]}" | grep -qxF -- "$category" \
            || die 2 "unknown category: $category"
    fi

    model="$(conf LANE2_EVAL_DRAFT_MODEL)"
    sha="$(conf LANE2_EVAL_DRAFT_SHA256 | tr 'A-F' 'a-f')"
    endpoint="$(conf LANE2_EVAL_DRAFT_ENDPOINT)"
    [[ -n "$model" && "$sha" =~ ^[0-9a-f]{64}$ ]] \
        || die 4 "drafting model not configured (LANE2_EVAL_DRAFT_MODEL, LANE2_EVAL_DRAFT_SHA256)"
    evalset_loopback "$endpoint" || die 4 "drafting endpoint must be http on loopback"
    (( ${#EVALSET_CANDIDATES[@]} > 0 )) \
        || die 4 "no classifier candidates configured (LANE2_EVAL_CANDIDATE); cannot prove the drafting model is not one"
    for cand in "${EVALSET_CANDIDATES[@]}"; do
        read -r cid csha <<<"${cand//|/ }"
        csha="$(tr 'A-F' 'a-f' <<<"${csha:-}")"
        [[ -n "$cid" && "$csha" =~ ^[0-9a-f]{64}$ ]] \
            || die 4 "malformed LANE2_EVAL_CANDIDATE (want: <model id> <sha256>)"
        [[ "$cid" == "$model" || "$csha" == "$sha" ]] \
            && die 4 "drafting model is a classifier candidate; pick a different drafting model"
    done

    store="$(evalset_store create)"
    body="$(head -c "$EVALSET_MAX_STDIN" | jq -Rsc --arg model "$model" '
        {model: $model, temperature: 0.7, stream: false,
         messages: [
           {role: "system", content: "Draft one realistic example input for a sensitivity classifier eval set. Reply with the example text only."},
           {role: "user", content: .}]}')"
    resp="$(printf '%s' "$body" \
        | curl -sS --fail --noproxy '*' --max-time 300 \
               -H 'Content-Type: application/json' --data-binary @- \
               "${endpoint%/}/v1/chat/completions" 2>/dev/null \
        | head -c "$EVALSET_MAX_RESPONSE")" || die 4 "drafting model call failed"
    content="$(jq -er '.choices[0].message.content | select(type == "string" and length > 0)' \
        <<<"$resp" 2>/dev/null)" || die 4 "drafting model returned no draft"

    evalset_lock "$store"
    id="draft-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
    (
        umask 077
        jq -nc --arg id "$id" --arg category "$category" --arg prompt "$content" \
               --arg provenance "local:$model@$sha" --arg time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
               '{id: $id, category: (if $category == "" then null else $category end),
                 label: null, hard_negative: false, split: null,
                 provenance: $provenance, labelled_by: null, drafted: $time, prompt: $prompt}' \
            >> "$store/drafts.jsonl"
    )
    chmod 600 "$store/drafts.jsonl"
    ok "draft $id written to the drafts file (unlabelled; label it before it can join the tuning split)"
}

cmd_export() {
    local out="" recipient store files=() f
    while (( $# )); do
        case "$1" in
            --out) out="${2:-}"; shift 2 || die 2 "usage: eval-set.sh export --out FILE" ;;
            --plaintext|--plain|--no-encrypt)
                fail "plaintext export refused: eval fixtures leave the hub only encrypted"
                return 3 ;;
            *) die 2 "usage: eval-set.sh export --out FILE" ;;
        esac
    done
    [[ -n "$out" ]] || die 2 "usage: eval-set.sh export --out FILE"
    [[ -e "$out" ]] && die 2 "refusing to overwrite $out"
    recipient="$(conf LANE2_EVAL_EXPORT_RECIPIENT)"
    [[ "$recipient" =~ ^[0-9A-Fa-f]{40}$ ]] \
        || die 4 "LANE2_EVAL_EXPORT_RECIPIENT must be the full gpg key fingerprint"
    command -v gpg >/dev/null || die 4 "gpg not installed"

    store="$(evalset_store)"
    for f in tuning.jsonl heldout.jsonl freeze.jsonl drafts.jsonl; do
        [[ -f "$store/$f" ]] && files+=("$f")
    done
    (( ${#files[@]} > 0 )) || die 4 "eval store is empty"

    # The archive is streamed straight into gpg: no plaintext copy touches disk.
    if ! ( umask 077
           tar -C "$store" -cf - -- "${files[@]}" \
             | gpg --batch --quiet --yes --trust-model always \
                   --encrypt --recipient "$recipient" --output "$out" ) 2>/dev/null; then
        rm -f -- "$out"
        die 4 "encryption failed; nothing written"
    fi
    ok "encrypted export written: $out (${#files[@]} file(s))"
}

evalset_main() {
    local confdir=/etc/lane2 cmd
    if [[ "${1:-}" == --config-dir ]]; then
        confdir="${2:-}"; shift 2 || die 2 "usage: eval-set.sh [--config-dir DIR] <command>"
        [[ -n "$confdir" ]] || die 2 "usage: eval-set.sh [--config-dir DIR] <command>"
    fi
    cmd="${1:-}"; shift || true

    if evalset_in_container; then
        fail "run on the hub"
        exit 4
    fi
    command -v jq >/dev/null || die 4 "jq not installed"
    evalset_load_config "$confdir/lane2.conf"

    case "$cmd" in
        validate)     cmd_validate "$@" ;;
        freeze)       cmd_freeze "$@" ;;
        frozen-check) cmd_frozen_check "$@" ;;
        draft)        cmd_draft "$@" ;;
        export)       cmd_export "$@" ;;
        *) die 2 "usage: eval-set.sh [--config-dir DIR] validate|freeze|frozen-check|draft|export" ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    evalset_main "$@"
fi
