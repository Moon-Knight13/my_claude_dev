#!/usr/bin/env bash
# eval-harness.sh — run the sensitivity eval and report it honestly; publish a
# scrubbed copy of a run record (SP1a story 1.4; FR-35, FR-36, FR-38, FR-18,
# SM-2, SM-8, SM-C1; AD-1, AD-7, AD-10, AD-19, AD-20).
#
# A run scores every case of one split three ways and reports each separately:
#   floor-only       the gate's term-list floor
#   classifier-only  the gate's classifier layer
#   combined         floor OR classifier: blocked when either layer blocks
# For each row and each category it prints the case count n, misses, the miss
# rate, and its one-sided 95% Clopper-Pearson upper bound; for each row, the
# false-block rate on hard negatives beside the operator's ceiling. A case whose
# layer could not run (classifier fault, policy fault, no answer from the gate)
# goes to an `errors` bucket. It is never counted as a catch or a miss, and it
# is not in n.
#
# Through the gate (story 2.6; AD-1, AD-20): the harness reaches the floor and
# the classifier ONLY through the hub-socket gate `eval` op. It writes the
# cases into a hub-produced manifest directory (<state>/manifests/), asks for
# layers floor and classifier with the bulk budget GATE_EVAL_BUDGET, and builds
# the three rows from the per-layer results. It never loads the term list or
# the classifier prompt and never calls a model; a lint test
# (test-eval-via-gate.sh) fails if it does. The Epic 1 direct path lives on in
# eval-direct.sh only until a `compare` record shows no difference.
#
# Usage: eval-harness.sh [--config-dir DIR] <command> [options]
#   run --split tuning|heldout   score one split; aggregates on stdout, per-case
#                                detail only in the record in the eval store
#   publish <record>             print a scrubbed copy of a run record
#   compare <direct> <gate>      per-case difference count between a direct
#                                (eval-direct.sh) and a gate record; exit 3 on
#                                any difference (the switch stays blocked)
#   latency [--runs N] [--cold]  time the gate end to end at 1k, 5k, and 20k
#                                tokens; record p50, p95, max against NFR-1
#
# Config: <config-dir>/lane2.conf, fleet.conf, and gate.conf (default
# /etc/lane2), parsed, never sourced; the last assignment wins. Nothing is read
# from the environment. Keys: docs/SP1A_EVAL_HARNESS.md.
#
# Store: the eval store of scripts/hub/eval-set.sh (<LANE2_STATE_ROOT>/eval/,
# 0700, files 0600). A run adds record-<stamp>.json; a held-out run also adds a
# line to heldout-runs.jsonl. The harness never reads or writes a verdict cache.
#
# Exit: 0 ok, 2 usage, 3 refused (split not frozen or changed; compare found a
# difference), >=4 fault (config, store, incomplete record, inside a container).
set -euo pipefail

EVALH_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Store, config parser, freeze check, container check; also sources fleet.sh.
# shellcheck source=scripts/hub/eval-set.sh disable=SC1091
source "$EVALH_HERE/eval-set.sh"
# shellcheck source=scripts/lib/hw.sh disable=SC1091
source "$EVALH_HERE/../lib/hw.sh"
# Hub config parsing (lane2_conf_file_get) and the one gate client.
# shellcheck source=scripts/lib/lane2.sh disable=SC1091
source "$EVALH_HERE/../lib/lane2.sh"
# shellcheck source=scripts/lib/gate-client.sh disable=SC1091
source "$EVALH_HERE/../lib/gate-client.sh"

# The production classifier settings file (AD-10), read by the direct path
# (eval-direct.sh). A test seam set by sourcing code, never read from the
# environment.
# shellcheck disable=SC2034
EVALH_SETTINGS="$EVALH_HERE/fleet/classifier.settings.json"
EVALH_MAX_SPLIT_BYTES=67108864      # largest split file scored
EVALH_BATCH=1000                    # cases per gate request (the answer line bounds it)
EVALH_CONFDIR=/etc/lane2
EVALH_MAX_RECORD_BYTES=16777216     # largest record publish reads
EVALH_ROWS=(floor-only classifier-only combined)
EVALH_METHOD="one-sided 95% Clopper-Pearson upper bound (exact binomial)"
# Fields a record must carry (FR-38, SM-8). Any missing or empty one is a fault.
EVALH_REQUIRED=(model_sha256 prompt_sha256 settings_sha256 fixture_digest
    runtime.build runtime.binary_sha256 gpu.model driver.name driver.version
    mesa_version kernel_version cache_mode)

# Multi-block cases are scored as their blocks joined, as eval-classifier.sh does.
EVALH_TEXT_JQ='.prompt // (.blocks // [] | join("\n\n"))'

# --- statistics ----------------------------------------------------------------

# evalh_cp_upper <misses> <n> — one-sided 95% Clopper-Pearson upper bound on the
# miss rate, in percent, rounded UP to two decimals so it never understates. It
# is the p at which P(X <= misses | n, p) = 0.05, found by bisection; each
# binomial term is built in log space so large n does not underflow.
evalh_cp_upper() {
    awk -v k="$1" -v n="$2" '
    function cdf(k, n, p,   q, lt, s, i) {
        q = 1 - p; lt = n * log(q); s = exp(lt)
        for (i = 1; i <= k; i++) { lt += log((n - i + 1) / i) + log(p / q); s += exp(lt) }
        return s
    }
    BEGIN {
        if (n <= 0) { print "-"; exit }
        if (k >= n) { hi = 1 }
        else {
            lo = 0; hi = 1
            for (j = 0; j < 200; j++) { mid = (lo + hi) / 2; if (cdf(k, n, mid) > 0.05) lo = mid; else hi = mid }
        }
        v = hi * 10000; c = int(v); if (c < v) c++
        printf "%.2f\n", c / 100
    }'
}

# --- record inputs ---------------------------------------------------------------

evalh_sha() { sha256sum < "$1" | cut -d' ' -f1; }

# evalh_host_json — hardware and versions for the record (hw.sh probes).
evalh_host_json() {
    local kernel drv_ver hn user home
    # An in-tree driver has no version file; it is the kernel's.
    hw_driver_version
    drv_ver="$HW_DRIVER_VERSION"; kernel="$HW_KERNEL_RELEASE"
    hw_detect_vulkan
    hn="$(hw_read "$HW_PROC/sys/kernel/hostname" || true)"
    user="$(id -un 2>/dev/null || true)"
    home="$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6 || true)"
    jq -nc --arg model "$HW_VK_NAME" --arg pci "$HW_GPU_ID" --arg dname "$HW_GPU_DRIVER" \
           --arg dver "$drv_ver" --arg mesa "$HW_MESA_VERSION" --arg kernel "$kernel" \
           --arg hn "$(hw_clean "$hn")" --arg user "$user" --arg home "$home" '
        {gpu: {model: $model, pci_id: $pci}, driver: {name: $dname, version: $dver},
         mesa_version: $mesa, kernel_version: $kernel,
         host: {hostname: $hn, user: $user, home: $home}}'
}

# evalh_missing <record-json> — prints the first required field that is
# missing or empty; nothing when the record is complete.
evalh_missing() {
    local f
    for f in "${EVALH_REQUIRED[@]}"; do
        jq -e --arg f "$f" 'getpath($f | split(".")) | type == "string" and length > 0' \
            <<<"$1" >/dev/null 2>&1 || { printf '%s' "$f"; return 0; }
    done
}

# --- scoring -----------------------------------------------------------------------

# --- the gate path -----------------------------------------------------------

evalh_gate_conf() { lane2_conf_file_get "$EVALH_CONFDIR/gate.conf" "$1"; }

# evalh_gate_ask <manifest dir> <cases> — one bulk eval request. Sets
# EVALH_CODES (two characters per case) and EVALH_INPUTS (JSON) from a
# well-formed answer; rc 1 when there is none (every case is then an error).
evalh_gate_ask() {
    local dir="$1" n="$2" hdr rc=0
    EVALH_CODES=""; EVALH_INPUTS=""
    hdr="$(jq -nc --arg m "$dir" --arg pv "$EVALH_PV" \
        '{v: 1, op: "eval", layers: ["floor", "classifier"], manifest: $m, policy_version: $pv}')"
    gate_client "$EVALH_SOCK" "$((EVALH_BUDGET + 2))" "$hdr" < /dev/null || rc=$?
    (( rc == 0 || rc == 3 )) || return 1
    # No answer is no answer; jq -e alone would not say so on every version.
    [[ "$GATE_CLIENT_RESPONSE" == \{* ]] || return 1
    # The gate refuses a policy_version that is not its own (Story 2.5).
    if [[ "$(jq -r '.detail.reason // .detail.reason_category // ""' <<<"$GATE_CLIENT_RESPONSE")" == fault:policy ]]; then
        EVALH_PV_MISMATCH=1; return 1
    fi
    jq -e --argjson n "$n" '(.v | type) == "number" and .v == 1
        and (.detail.cases | type) == "string" and (.detail.cases | length) == 2 * $n
        and (.detail.cases | test("^[hce-]*$"))
        and (.detail.inputs.settings_sha256 | type) == "string"' <<<"$GATE_CLIENT_RESPONSE" >/dev/null 2>&1 \
        || return 1
    EVALH_CODES="$(jq -r .detail.cases <<<"$GATE_CLIENT_RESPONSE")"
    EVALH_INPUTS="$(jq -c .detail.inputs <<<"$GATE_CLIENT_RESPONSE")"
}

# evalh_manifest_dir — sets EVALH_MDIR to a fresh manifest directory in the
# manifests store, readable by the gate through the store's group (setgid, 2750).
evalh_manifest_dir() {
    EVALH_MDIR="$EVALH_MANIFESTS/eval-$(date -u +%Y%m%dT%H%M%SZ)-$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"
    ( umask 027; mkdir "$EVALH_MDIR" ) || return 1
    EVALH_MANIFEST_DIRS+=("$EVALH_MDIR")
}

# evalh_prepare <work dir> — the inputs of a gate run, all before any case is
# scored: the gate's own policy_version, prompt and settings checksums, from a
# bulk eval of an empty manifest. Faults stop the run (exit 4).
evalh_prepare() {
    local w="$1" mode d
    mode="$(conf LANE2_EVAL_CACHE_MODE cache_prompt_false)"
    case "$mode" in
        cache_prompt_false) ;;
        np1) die 4 "LANE2_EVAL_CACHE_MODE=np1 belongs to the Epic 1 direct path; the gate calls the classifier as production does" ;;
        *) die 4 "LANE2_EVAL_CACHE_MODE must be cache_prompt_false or np1" ;;
    esac
    fleet_load_config || die 4 "fleet config missing or unreadable: $FLEET_CONF_FILE"
    EVALH_MODEL="$(fleet_member_model classifier)" || die 4 "FLEET_CLASSIFIER_MODEL missing or malformed"
    EVALH_SOCK="$(evalh_gate_conf GATE_HUB_SOCKET)"; EVALH_SOCK="${EVALH_SOCK:-/run/lane2/gate/hub.sock}"
    EVALH_BUDGET="$(evalh_gate_conf GATE_EVAL_BUDGET)"; EVALH_BUDGET="${EVALH_BUDGET:-600}"
    if ! [[ "$EVALH_BUDGET" =~ ^[1-9][0-9]{0,3}$ ]] || (( EVALH_BUDGET > 9000 )); then
        die 4 "GATE_EVAL_BUDGET must be 1..9000 seconds"
    fi
    EVALH_MANIFESTS="$(conf LANE2_STATE_ROOT /var/lib/lane2)/manifests"
    [[ -d "$EVALH_MANIFESTS" && ! -L "$EVALH_MANIFESTS" && -w "$EVALH_MANIFESTS" ]] \
        || die 4 "manifests store missing or not writable: $EVALH_MANIFESTS (run lane2 install)"
    # policy_version and the prompt checksum come from the policy store's record
    # (written by lane2 policy update and lane2 install, on the hub); the gate
    # confirms the policy_version and never sends it back (Story 2.5).
    local pstate
    pstate="$(conf LANE2_STATE_ROOT /var/lib/lane2)/gate-policy/state.json"
    EVALH_PV="$(jq -r '.policy_version // ""' "$pstate" 2>/dev/null)" || EVALH_PV=""
    [[ "$EVALH_PV" =~ ^[0-9a-f]{64}$ ]] \
        || die 4 "record incomplete: policy_version (none recorded in the policy store; run lane2 policy update); nothing scored"
    EVALH_PROMPT_SHA="$(jq -r '.prompt_sha256 // ""' "$pstate" 2>/dev/null)" || EVALH_PROMPT_SHA=""
    [[ "$EVALH_PROMPT_SHA" =~ ^[0-9a-f]{64}$ ]] \
        || die 4 "record incomplete: prompt_sha256 (none recorded in the policy store; run lane2 policy update); nothing scored"
    evalh_manifest_dir || die 4 "cannot create a manifest directory"
    d="$EVALH_MDIR"
    EVALH_PV_MISMATCH=0
    if ! evalh_gate_ask "$d" 0; then
        (( EVALH_PV_MISMATCH )) && die 4 "record incomplete: policy_version (the gate refused it: fault:policy — the gate's policy is missing or not the one recorded in the policy store; run lane2 policy update); nothing scored"
        die 4 "record incomplete: policy_version (the gate's eval op did not answer: $(jq -r '.detail.reason // "no answer"' <<<"${GATE_CLIENT_RESPONSE:-null}" 2>/dev/null || echo "no answer")); nothing scored"
    fi
    rm -rf -- "$d"
    jq -e '.cache_prompt == false' <<<"$EVALH_INPUTS" >/dev/null \
        || die 4 "the production classifier settings enable prompt caching; through the gate the eval cannot force it off"
    EVALH_MODE=cache_prompt_false
    EVALH_MEMBER=classifier
    EVALH_SETTINGS_SHA="$(jq -r '.settings_sha256 // ""' <<<"$EVALH_INPUTS")"
    EVALH_EFF_SHA="$EVALH_SETTINGS_SHA"
    EVALH_FLOOR_OK=1
    EVALH_PATH_TEXT="gate: hub-socket eval op, layers floor and classifier (AD-1, AD-20)"
}

evalh_code() { case "$1" in h) echo block ;; c) echo allow ;; *) echo error ;; esac; }

# evalh_score <work dir> — every case of $w/split.jsonl through the gate, in
# batches of EVALH_BATCH; writes $w/rows.jsonl. A batch without a well-formed
# answer makes each of its cases an error. The gate's policy_version must stay
# the one the run started with.
evalh_score() {
    local w="$1" line d n=0 i fl cl co
    : > "$w/rows.jsonl"; : > "$w/batch.jsonl"
    flush() {
        (( n > 0 )) || return 0
        EVALH_PV_MISMATCH=0
        if ! evalh_gate_ask "$d" "$n"; then EVALH_CODES=""; fi
        (( EVALH_PV_MISMATCH )) && die 4 "policy_version changed during the run; nothing recorded"
        i=0
        while IFS= read -r line; do
            if [[ -n "$EVALH_CODES" ]]; then
                fl="$(evalh_code "${EVALH_CODES:$((2 * i)):1}")"; cl="$(evalh_code "${EVALH_CODES:$((2 * i + 1)):1}")"
            else
                fl=error; cl=error
            fi
            if [[ "$fl" == error || "$cl" == error ]]; then co=error
            elif [[ "$fl" == block || "$cl" == block ]]; then co=block
            else co=allow; fi
            jq -c --arg f "$fl" --arg c "$cl" --arg b "$co" \
                '{id: .id, category: .category, label: .label, hard_negative: (.hard_negative == true),
                  "floor-only": $f, "classifier-only": $c, combined: $b}' <<<"$line" >> "$w/rows.jsonl"
            i=$((i + 1))
        done < "$w/batch.jsonl"
        rm -rf -- "$d"; : > "$w/batch.jsonl"; n=0
    }
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -n "$line" ]] || continue
        if (( n == 0 )); then evalh_manifest_dir || die 4 "cannot create a manifest directory"; d="$EVALH_MDIR"; fi
        n=$((n + 1))
        ( umask 027; jq -j "$EVALH_TEXT_JQ" <<<"$line" > "$d/$(printf '%06d' "$n")" 2>/dev/null ) \
            || ( umask 027; : > "$d/$(printf '%06d' "$n")" )
        printf '%s\n' "$line" >> "$w/batch.jsonl"
        (( n < EVALH_BATCH )) || flush
    done < "$w/split.jsonl"
    flush
    unset -f flush
}

# evalh_aggregate <rows.jsonl> — one TSV line per (row, category) and per row
# for false blocks: kind row category n hits errors rate upper. n excludes
# errors; "hits" is misses for sensitive cases and blocks for hard negatives.
evalh_aggregate() {
    local cats
    cats="$(printf '%s\n' "${EVALSET_CATEGORIES[@]}" | jq -R . | jq -sc .)"
    jq -rs --argjson cats "$cats" '
        . as $r
        | ( ("floor-only", "classifier-only", "combined") as $row
            | ($cats[], "all") as $c
            | [$r[] | select(.label == "sensitive" and ($c == "all" or .category == $c)) | .[$row]] as $v
            | ["miss", $row, $c, ([$v[] | select(. != "error")] | length),
               ([$v[] | select(. == "allow")] | length), ([$v[] | select(. == "error")] | length)] ),
          ( ("floor-only", "classifier-only", "combined") as $row
            | [$r[] | select(.label == "nonsensitive" and .hard_negative == true) | .[$row]] as $v
            | ["fb", $row, "hard-negatives", ([$v[] | select(. != "error")] | length),
               ([$v[] | select(. == "block")] | length), ([$v[] | select(. == "error")] | length)] )
        | @tsv' "$1" \
    | while IFS=$'\t' read -r kind row cat n k e; do
        if (( n > 0 )); then
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$kind" "$row" "$cat" "$n" "$k" "$e" \
                "$(awk -v k="$k" -v n="$n" 'BEGIN { printf "%.2f", 100 * k / n }')" "$(evalh_cp_upper "$k" "$n")"
        else
            printf '%s\t%s\t%s\t%s\t%s\t%s\t-\t-\n' "$kind" "$row" "$cat" "$n" "$k" "$e"
        fi
    done
}

# evalh_aggregates_json <tsv> <ceiling> — the aggregates object for the record.
# Rates go through arithmetic so jq 1.6 and 1.7 print them the same way.
evalh_aggregates_json() {
    jq -Rsc --arg ceiling "$2" --arg method "$EVALH_METHOD" '
        def num: if . == "-" then null else ((tonumber * 100 + 0.5) | floor) / 100 end;
        [split("\n")[] | select(length > 0) | split("\t")] as $l
        | {method: $method,
           false_block_ceiling: (if $ceiling == "" then null else ($ceiling | num) end),
           rows: (reduce $l[] as $x ({};
               if $x[0] == "miss" then
                   .[$x[1]].categories[$x[2]] = {n: ($x[3] | tonumber), misses: ($x[4] | tonumber),
                       errors: ($x[5] | tonumber), miss_rate: ($x[6] | num), miss_rate_upper95: ($x[7] | num)}
               else
                   .[$x[1]].false_block = {n: ($x[3] | tonumber), blocks: ($x[4] | tonumber),
                       errors: ($x[5] | tonumber), rate: ($x[6] | num), rate_upper95: ($x[7] | num)}
               end))}' <<<"$1"
}

# evalh_report <tsv> <ceiling> — the stdout report: aggregates only.
evalh_report() {
    local tsv="$1" ceiling="$2" row kind r cat n k e rate up
    pct() { if [[ "$1" == - ]]; then printf 'n/a'; else printf '%s%%' "$1"; fi; }
    echo "method: $EVALH_METHOD on each rate"
    echo "n counts scored cases; a case whose layer could not run is in errors, never a catch or a miss"
    for row in "${EVALH_ROWS[@]}"; do
        echo "== $row =="
        printf '  %-12s %5s %7s %10s %10s %7s\n' category n misses "miss rate" "95% upper" errors
        while IFS=$'\t' read -r kind r cat n k e rate up; do
            [[ "$kind" == miss && "$r" == "$row" ]] || continue
            printf '  %-12s %5s %7s %10s %10s %7s\n' "$cat" "$n" "$k" "$(pct "$rate")" "$(pct "$up")" "$e"
        done <<<"$tsv"
        while IFS=$'\t' read -r kind r cat n k e rate up; do
            [[ "$kind" == fb && "$r" == "$row" ]] || continue
            printf '  false blocks on hard negatives: n %s, blocks %s, rate %s, 95%% upper %s, errors %s; ceiling %s\n' \
                "$n" "$k" "$(pct "$rate")" "$(pct "$up")" "$e" "$(if [[ -n "$ceiling" ]]; then pct "$ceiling"; else printf 'not set'; fi)"
        done <<<"$tsv"
    done
    unset -f pct
}

# --- commands ----------------------------------------------------------------------

cmd_run() {
    local split="" usage="usage: eval-harness.sh run --split tuning|heldout"
    while (( $# )); do
        case "$1" in
            --split) split="${2:-}"; shift 2 || die 2 "$usage" ;;
            *) die 2 "$usage" ;;
        esac
    done
    [[ "$split" == tuning || "$split" == heldout ]] || die 2 "$usage"

    local store w mode member model model_sha runtime_build runtime_bin ceiling bound
    store="$(evalset_store)"
    w="$(mktemp -d)" || die 4 "no temp directory"
    chmod 700 "$w"
    EVALH_WORK="$w"; EVALH_MANIFEST_DIRS=()
    trap 'evalh_cleanup' EXIT

    # --- the split: frozen-check, then a private copy, under the store lock ------
    evalset_lock "$store"
    cmd_frozen_check || exit 3
    [[ -s "$store/$split.jsonl" ]] || { fail "no $split split in the eval store"; exit 3; }
    (( $(wc -c < "$store/$split.jsonl") <= EVALH_MAX_SPLIT_BYTES )) || die 4 "$split split over $EVALH_MAX_SPLIT_BYTES bytes"
    cp -- "$store/$split.jsonl" "$w/split.jsonl"
    local digest want
    digest="$(evalset_digest "$w/split.jsonl")"
    if [[ "$split" == heldout ]]; then
        want="$(evalset_last_freeze "$store" | jq -r .digest)"
        [[ "$digest" == "$want" ]] || { fail "held-out split changed since it was frozen"; exit 3; }
    fi
    exec 9>&-
    jq -e -s --argjson cats "$(printf '%s\n' "${EVALSET_CATEGORIES[@]}" | jq -R . | jq -sc .)" '
        all(.[]; type == "object" and (.id | type == "string" and length > 0)
            and (.category | IN($cats[])) and (.label | IN("sensitive", "nonsensitive")))' \
        "$w/split.jsonl" >/dev/null 2>&1 || die 4 "$split split malformed; run eval-set.sh validate"

    # --- the path's inputs: the gate's (here) or the direct path's ------------
    evalh_prepare "$w"
    model="$EVALH_MODEL"; mode="$EVALH_MODE"; member="$EVALH_MEMBER"

    # --- the record's inputs: all present before any case is scored --------------
    model_sha="$(fleet_conf FLEET_CLASSIFIER_SHA256 | tr 'A-F' 'a-f')"
    [[ "$model_sha" =~ ^[0-9a-f]{64}$ ]] || model_sha=""
    runtime_build="$(fleet_conf FLEET_RUNTIME_BUILD)"
    [[ "$runtime_build" =~ ^(v[0-9]+\.[0-9]+\.[0-9]+|b[0-9]+)$ ]] || runtime_build=""
    runtime_bin="$(fleet_conf FLEET_RUNTIME_BINARY)"
    local runtime_sha=""
    [[ "$runtime_bin" == /* && -f "$runtime_bin" && -r "$runtime_bin" ]] && runtime_sha="$(evalh_sha "$runtime_bin")"
    ceiling="$(conf LANE2_EVAL_FALSE_BLOCK_CEILING)"
    if [[ -n "$ceiling" ]] && ! { [[ "$ceiling" =~ ^[0-9]+(\.[0-9]+)?$ ]] \
            && awk -v c="$ceiling" 'BEGIN { exit !(c >= 0 && c <= 100) }'; }; then
        die 4 "LANE2_EVAL_FALSE_BLOCK_CEILING must be a percentage between 0 and 100"
    fi
    bound="$(conf LANE2_EVAL_MISS_BOUND 10)"

    local stamp base rec missing
    stamp="$(date -u +%Y%m%dT%H%M%SZ)-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
    base="$(jq -nc --arg time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg split "$split" \
        --arg model "$model" --arg model_sha "$model_sha" --arg prompt_sha "$EVALH_PROMPT_SHA" \
        --arg settings_sha "$EVALH_SETTINGS_SHA" --arg eff_sha "$EVALH_EFF_SHA" \
        --arg digest "$digest" --arg build "$runtime_build" --arg bin_sha "$runtime_sha" \
        --arg mode "$mode" --arg member "$member" --argjson floor_ok "$( (( EVALH_FLOOR_OK )) && echo true || echo false)" \
        --arg path "$EVALH_PATH_TEXT" --arg pv "$EVALH_PV" \
        --argjson host "$(evalh_host_json)" '
        {kind: "eval-run", format: 1, time: $time, split: $split, path: $path,
         policy_version: (if $pv == "" then null else $pv end),
         model: $model, model_sha256: $model_sha, prompt_sha256: $prompt_sha,
         settings_sha256: $settings_sha, effective_settings_sha256: $eff_sha,
         fixture_digest: $digest, runtime: {build: $build, binary_sha256: $bin_sha},
         cache_mode: $mode, fleet_member: $member, term_list_usable: $floor_ok} + $host')"
    missing="$(evalh_missing "$base")"
    [[ -z "$missing" ]] || die 4 "record incomplete: $missing; nothing scored"

    # --- held-out runs are logged before scoring: a run is an exposure -----------
    if [[ "$split" == heldout ]]; then
        evalset_lock "$store"
        ( umask 077
          jq -nc --arg time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg digest "$digest" --arg run "$stamp" \
              '{time: $time, digest: $digest, run: $run}' >> "$store/heldout-runs.jsonl" )
        chmod 600 "$store/heldout-runs.jsonl"
        exec 9>&-
    fi

    # --- score ---------------------------------------------------------------------
    evalh_score "$w"

    local tsv agg errors
    tsv="$(evalh_aggregate "$w/rows.jsonl")"
    agg="$(evalh_aggregates_json "$tsv" "$ceiling")"

    # --- the record: complete, 0600, in the hub-only store -------------------------
    jq -c --argjson agg "$agg" --slurpfile cases "$w/rows.jsonl" \
        '. + {aggregates: $agg, cases: $cases}' <<<"$base" > "$w/record.json"
    missing="$(evalh_missing "$(cat "$w/record.json")")"
    [[ -z "$missing" ]] || die 4 "record incomplete: $missing"
    rec="$store/record-$stamp.json"
    evalset_lock "$store"
    ( umask 077; cp -- "$w/record.json" "$rec.tmp" && mv -- "$rec.tmp" "$rec" ) || die 4 "could not write the record"
    chmod 600 "$rec"
    exec 9>&-

    # --- stdout: aggregates only ----------------------------------------------------
    echo "== eval run: $split split, $(jq -s length "$w/rows.jsonl") case(s), cache mode $mode =="
    evalh_report "$tsv" "$ceiling"
    echo
    (( EVALH_FLOOR_OK )) || printf '  !!  term list missing, empty, or unreadable: every floor and combined result is an error\n'
    errors="$(jq -s '[.[] | select(.combined == "error" or .["floor-only"] == "error" or .["classifier-only"] == "error")] | length' "$w/rows.jsonl")"
    if (( errors > 0 )); then
        printf '  !!  %s case(s) in the errors bucket; selection (FR-37) needs zero errors\n' "$errors"
    fi
    local up
    up="$(jq -r '.rows.combined.categories.all.miss_rate_upper95 // "n/a"' <<<"$agg")"
    if [[ "$up" != n/a ]] && awk -v u="$up" -v b="$bound" 'BEGIN { exit !(u <= b) }'; then
        ok "combined 95% upper bound ${up}% is within the ${bound}% target"
    else
        [[ "$up" == n/a ]] || up="$up%"
        printf '  !!  combined 95%% upper bound %s is not within the %s%% target\n' "$up" "$bound"
    fi
    up="$(jq -r '.rows.combined.false_block.rate // "n/a"' <<<"$agg")"
    if [[ -z "$ceiling" ]]; then
        printf '  !!  no false-block ceiling set (LANE2_EVAL_FALSE_BLOCK_CEILING)\n'
    elif [[ "$up" != n/a ]] && awk -v r="$up" -v c="$ceiling" 'BEGIN { exit !(r <= c) }'; then
        ok "combined false-block rate ${up}% is within the ${ceiling}% ceiling"
    else
        [[ "$up" == n/a ]] || up="$up%"
        printf '  !!  combined false-block rate %s is not within the %s%% ceiling\n' "$up" "$ceiling"
    fi
    ok "record written (0600, hub only): $rec"
}

evalh_cleanup() {
    local d
    for d in "${EVALH_MANIFEST_DIRS[@]}"; do rm -rf -- "$d"; done
    [[ -n "${EVALH_WORK:-}" ]] && rm -rf -- "$EVALH_WORK"
    return 0
}

cmd_publish() {
    (( $# == 1 )) || die 2 "usage: eval-harness.sh publish <record>"
    local rec="$1" lits
    [[ -f "$rec" && -r "$rec" ]] || die 4 "record unreadable: $rec"
    (( $(wc -c < "$rec") <= EVALH_MAX_RECORD_BYTES )) || die 4 "record over $EVALH_MAX_RECORD_BYTES bytes"
    jq -e 'type == "object" and .kind == "eval-run"' "$rec" >/dev/null 2>&1 || die 4 "not an eval run record"
    # Identifiers to scrub by value: the record's own host fields and this host's.
    lits="$(jq -c --arg hn "$(hw_read "$HW_PROC/sys/kernel/hostname" || true)" \
                  --arg user "$(id -un 2>/dev/null || true)" \
                  --arg home "$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6 || true)" \
        '[.host.hostname?, .host.user?, .host.home?, $hn, $user, $home]
         | map(select(type == "string" and length >= 2)) | unique' "$rec")"
    # An allowlist projection: only checksums, versions, the GPU model class,
    # and aggregates are copied, each checked against its format. Per-case
    # rows, paths, and host fields are never copied. Free text that remains
    # (the GPU model name) is scrubbed of identifiers.
    jq --argjson lits "$lits" --argjson cats "$(printf '%s\n' "${EVALSET_CATEGORIES[@]}" all | jq -R . | jq -sc .)" '
        def hex: if type == "string" and test("^[0-9a-f]{64}$") then . else "redacted" end;
        def ver: if type == "string" then ((capture("^(?<v>[0-9]+\\.[0-9]+(\\.[0-9]+)?)").v) // "redacted") else "redacted" end;
        def lit($l): split($l) | join("[redacted]");
        def scrub:
            reduce $lits[] as $l (.; lit($l) | lit($l | ascii_downcase) | lit($l | ascii_upcase))
            | gsub("/(home|Users)/[^/ ]+"; "/[redacted]")
            | gsub("([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}"; "[mac]")
            | gsub("[0-9]{1,3}(\\.[0-9]{1,3}){3}"; "[ip]")
            | gsub("[0-9A-Fa-f]{0,4}(:[0-9A-Fa-f]{0,4}){2,7}"; "[ip]")
            | [splits(" +") | select((test("[0-9]") and test("[A-Za-z]") and test("^[A-Za-z0-9_-]{8,}$")) | not)]
            | join(" ") | gsub("[^A-Za-z0-9 ()._+\\[\\]-]"; "");
        def n: if type == "number" then . else null end;
        def gpuclass: if type == "string" then (scrub | .[0:96]) else "redacted" end;
        {kind: "eval-run-published", format: 1,
         time: (if (.time | type) == "string" and (.time | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$")) then .time else null end),
         split: (if .split == "tuning" or .split == "heldout" then .split else null end),
         cache_mode: (if .cache_mode == "cache_prompt_false" or .cache_mode == "np1" then .cache_mode else null end),
         model_sha256: (.model_sha256 | hex), prompt_sha256: (.prompt_sha256 | hex),
         settings_sha256: (.settings_sha256 | hex), effective_settings_sha256: (.effective_settings_sha256 | hex),
         fixture_digest: (.fixture_digest | hex),
         runtime: {build: (if (.runtime.build | type) == "string" and (.runtime.build | test("^(v[0-9]+\\.[0-9]+\\.[0-9]+|b[0-9]+)$")) then .runtime.build else "redacted" end),
                   binary_sha256: (.runtime.binary_sha256 | hex)},
         gpu: {model_class: (.gpu.model | gpuclass),
               pci_id: (if (.gpu.pci_id | type) == "string" and (.gpu.pci_id | test("^[0-9a-f]{4}:[0-9a-f]{4}$")) then .gpu.pci_id else "redacted" end)},
         driver: {name: (if (.driver.name | type) == "string" and (.driver.name | test("^[a-z0-9_]{1,32}$")) then .driver.name else "redacted" end),
                  version: (if (.driver.version | type) == "string" and (.driver.version | startswith("in-tree "))
                            then "in-tree " + (.driver.version[8:] | ver) else (.driver.version | ver) end)},
         mesa_version: (.mesa_version | ver), kernel_version: (.kernel_version | ver),
         aggregates: {method: (if (.aggregates.method | type) == "string" and (.aggregates.method | test("^[A-Za-z0-9 %().-]{1,96}$")) then .aggregates.method else null end),
                      false_block_ceiling: (.aggregates.false_block_ceiling | n),
                      rows: (.aggregates.rows as $r
                             | reduce ("floor-only", "classifier-only", "combined") as $row ({};
                                 .[$row] = {categories: (reduce $cats[] as $c ({};
                                               .[$c] = ($r[$row].categories[$c] // {} | {n: (.n | n), misses: (.misses | n), errors: (.errors | n),
                                                        miss_rate: (.miss_rate | n), miss_rate_upper95: (.miss_rate_upper95 | n)}))),
                                            false_block: ($r[$row].false_block // {} | {n: (.n | n), blocks: (.blocks | n), errors: (.errors | n),
                                                        rate: (.rate | n), rate_upper95: (.rate_upper95 | n)})}))}}' "$rec" \
        || die 4 "could not scrub the record"
}

# --- compare: the switch from the direct path (story 2.6) --------------------------

# compare <direct record> <gate record> — per-case results of the Epic 1 direct
# path (eval-direct.sh) against the gate path, same split, pins, and policy.
# Writes a compare record (0600, hub only) and prints the difference count.
# Exit 0 identical, 3 any difference (the switch stays blocked), 4 not comparable.
cmd_compare() {
    (( $# == 2 )) || die 2 "usage: eval-harness.sh compare <direct record> <gate record>"
    local a="$1" b="$2" f k va vb res store stamp rec diffs
    for f in "$a" "$b"; do
        [[ -f "$f" && -r "$f" ]] || die 4 "record unreadable: $f"
        (( $(wc -c < "$f") <= EVALH_MAX_RECORD_BYTES )) || die 4 "record over $EVALH_MAX_RECORD_BYTES bytes: $f"
        jq -e 'type == "object" and .kind == "eval-run" and (.cases | type) == "array"' "$f" >/dev/null 2>&1 \
            || die 4 "not an eval run record: $f"
    done
    jq -e '.path | type == "string" and startswith("direct")' "$a" >/dev/null 2>&1 || die 4 "first record is not a direct-path record"
    jq -e '.path | type == "string" and startswith("gate")' "$b" >/dev/null 2>&1 || die 4 "second record is not a gate record"
    # Same split, cases, pins, settings, and policy (policy_version covers the
    # term list, prompt, model, runtime, and gate code).
    for k in split fixture_digest model_sha256 prompt_sha256 settings_sha256 runtime.build \
             runtime.binary_sha256 cache_mode policy_version; do
        va="$(jq -c --arg k "$k" 'getpath($k | split("."))' "$a")"
        vb="$(jq -c --arg k "$k" 'getpath($k | split("."))' "$b")"
        [[ "$va" == "$vb" && "$va" != null && "$va" != '""' ]] \
            || die 4 "records not comparable: $k differs or is missing"
    done
    res="$(jq -nc --slurpfile a "$a" --slurpfile b "$b" '
        ($a[0].cases | map({key: .id, value: .}) | from_entries) as $A
        | ($b[0].cases | map({key: .id, value: .}) | from_entries) as $B
        | ([$A, $B] | map(keys) | add | unique) as $ids
        | {cases: ($ids | length),
           missing: ([$ids[] | select($A[.] == null or $B[.] == null)] | length),
           by_row: (reduce ("floor-only", "classifier-only", "combined") as $r ({};
               .[$r] = ([$ids[] | select($A[.] != null and $B[.] != null and $A[.][$r] != $B[.][$r])] | length)))}
        | .differences = (.missing + ([.by_row[]] | add))')"
    store="$(evalset_store)"
    stamp="$(date -u +%Y%m%dT%H%M%SZ)-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
    rec="$store/compare-$stamp.json"
    evalset_lock "$store"
    ( umask 077
      jq -c --arg time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg da "${a##*/}" --arg db "${b##*/}" \
            --slurpfile ra "$a" '
          {kind: "eval-compare", format: 1, time: $time, direct_record: $da, gate_record: $db,
           split: $ra[0].split, fixture_digest: $ra[0].fixture_digest,
           policy_version: $ra[0].policy_version} + .' <<<"$res" > "$rec.tmp" && mv -- "$rec.tmp" "$rec" ) \
        || die 4 "could not write the compare record"
    chmod 600 "$rec"
    exec 9>&-
    diffs="$(jq -r .differences <<<"$res")"
    echo "== compare: direct path vs gate, $(jq -r .cases <<<"$res") case(s) =="
    printf '  %-16s %s\n' row differences
    for k in "${EVALH_ROWS[@]}"; do printf '  %-16s %s\n' "$k" "$(jq -r --arg r "$k" '.by_row[$r]' <<<"$res")"; done
    printf '  %-16s %s\n' "only in one" "$(jq -r .missing <<<"$res")"
    if (( diffs == 0 )); then
        ok "identical per-case results for every row; compare record (0600, hub only): $rec"
        return 0
    fi
    fail "$diffs difference(s): the switch from the direct path is blocked; compare record: $rec"
    exit 3
}

# --- latency through the gate (NFR-1, SM-5) ------------------------------------------

EVALH_LAT_TOKENS=(1000 5000 20000)
EVALH_LAT_WORDS=(the build step reads one config file and writes each result to the log
    after every change in a module so that later runs can compare their output with
    an earlier list of plain notes about formatting tests docs and small refactors)

# evalh_latency_text <tokens> — neutral English, about <tokens> tokens (three
# words for every four tokens). Synthetic; never a case or a term.
evalh_latency_text() {
    awk -v n="$(( $1 * 3 / 4 ))" -v words="${EVALH_LAT_WORDS[*]}" 'BEGIN {
        k = split(words, w, " ")
        for (i = 0; i < n; i++) { printf "%s%s", w[i % k + 1], ((i + 1) % 16 == 0 ? "\n" : " ") }
        printf "\n" }'
}

# Test seam: a sourcing test replaces these; nothing in the environment can.
evalh_restart_unit() { systemctl restart "$1"; }
evalh_classifier_ready() { fleet_health classifier; }

# evalh_pct <p> < sorted seconds — nearest-rank percentile.
evalh_pct() { awk -v p="$1" '{ v[NR] = $1 } END { if (NR == 0) { print "-"; exit } r = int(p * NR + 0.999999); if (r < 1) r = 1; if (r > NR) r = NR; printf "%.3f\n", v[r] }'; }

cmd_latency() {
    local runs=20 cold=0 usage="usage: eval-harness.sh latency [--runs N] [--cold]"
    while (( $# )); do
        case "$1" in
            --runs) runs="${2:-}"; shift 2 || die 2 "$usage" ;;
            --cold) cold=1; shift ;;
            *) die 2 "$usage" ;;
        esac
    done
    [[ "$runs" =~ ^[1-9][0-9]{0,2}$ ]] || die 2 "--runs takes 1..999"
    local sock dl shim units u store w tok mode r t0 t1 rc faults res="[]" stamp rec
    sock="$(evalh_gate_conf GATE_HUB_SOCKET)"; sock="${sock:-/run/lane2/gate/hub.sock}"
    dl="$(evalh_gate_conf GATE_DEADLINE)"; dl="${dl:-25}"
    shim="$(evalh_gate_conf GATE_SHIM_TIMEOUT)"; shim="${shim:-28}"
    [[ "$dl" =~ ^[0-9]+$ && "$shim" =~ ^[1-9][0-9]*$ ]] || die 4 "GATE_DEADLINE and GATE_SHIM_TIMEOUT must be whole seconds"
    units="$(conf LANE2_EVAL_COLD_UNITS fleet-classifier.service)"
    for u in $units; do
        [[ "$u" =~ ^[a-z0-9][a-z0-9@._-]*\.service$ ]] || die 4 "LANE2_EVAL_COLD_UNITS: not a service unit name: $u"
    done
    fleet_load_config || die 4 "fleet config missing or unreadable: $FLEET_CONF_FILE"
    store="$(evalset_store)"
    w="$(mktemp -d)" || die 4 "no temp directory"
    EVALH_WORK="$w"; EVALH_MANIFEST_DIRS=()
    trap 'evalh_cleanup' EXIT
    local hdr='{"v":1,"op":"eval","layers":["floor","classifier"]}'
    local -a modes=(warm); (( cold )) && modes+=(cold)

    echo "== gate latency: $runs run(s) per size, ${modes[*]}, through the hub socket =="
    for tok in "${EVALH_LAT_TOKENS[@]}"; do
        evalh_latency_text "$tok" > "$w/in-$tok"
        for mode in "${modes[@]}"; do
            : > "$w/times"; faults=0
            # warm: one request first, not counted, so the model is loaded
            [[ "$mode" == warm ]] && { gate_client "$sock" "$shim" "$hdr" < "$w/in-$tok" >/dev/null 2>&1 || true; }
            for (( r = 1; r <= runs; r++ )); do
                if [[ "$mode" == cold ]]; then
                    for u in $units; do evalh_restart_unit "$u" >/dev/null 2>&1 || die 4 "cold run: cannot restart $u"; done
                    local waited=0
                    until evalh_classifier_ready >/dev/null 2>&1; do
                        (( waited < 600 )) || die 4 "cold run: the classifier did not come back within 600 s"
                        sleep 1; waited=$((waited + 1))
                    done
                fi
                t0="$(date +%s%N)"; rc=0
                gate_client "$sock" "$shim" "$hdr" < "$w/in-$tok" || rc=$?
                t1="$(date +%s%N)"
                awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.3f\n", (b - a) / 1e9 }' >> "$w/times"
                # A fault (timeout, classifier, no answer) is counted; its time still counts.
                if (( rc != 0 )) && ! jq -e '.v == 1 and ((.detail.reason // "") | startswith("hit:"))' \
                        <<<"${GATE_CLIENT_RESPONSE:-null}" >/dev/null 2>&1; then
                    faults=$((faults + 1))
                fi
            done
            sort -n "$w/times" > "$w/sorted"
            res="$(jq -c --argjson tok "$tok" --arg mode "$mode" --argjson runs "$runs" --argjson faults "$faults" \
                --arg p50 "$(evalh_pct 0.50 < "$w/sorted")" --arg p95 "$(evalh_pct 0.95 < "$w/sorted")" \
                --arg max "$(tail -n 1 "$w/sorted")" '
                def num: ((tonumber * 1000 + 0.5) | floor) / 1000;
                . + [{tokens: $tok, mode: $mode, runs: $runs, faults: $faults,
                      p50_s: ($p50 | num), p95_s: ($p95 | num), max_s: ($max | num)}]' <<<"$res")"
        done
    done

    # NFR-1: p50 < 5 s at 1k; p95 < 30 s at 20k. The gate deadline: p95 at 20k
    # over GATE_DEADLINE is a FAIL (the gate would answer fault:timeout).
    local checks
    checks="$(jq -c --argjson dl "$dl" '
        [ (.[] | select(.tokens == 1000) | {check: "nfr1_p50_1k", mode, value_s: .p50_s, limit_s: 5,
                 status: (if .p50_s < 5 and .faults == 0 then "OK" else "FAIL" end)}),
          (.[] | select(.tokens == 20000) | {check: "nfr1_p95_20k", mode, value_s: .p95_s, limit_s: 30,
                 status: (if .p95_s < 30 and .faults == 0 then "OK" else "FAIL" end)}),
          (.[] | select(.tokens == 20000) | {check: "gate_deadline_p95_20k", mode, value_s: .p95_s, limit_s: $dl,
                 status: (if .p95_s <= $dl and .faults == 0 then "OK" else "FAIL" end)}) ]' <<<"$res")"
    stamp="$(date -u +%Y%m%dT%H%M%SZ)-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
    rec="$store/latency-$stamp.json"
    evalset_lock "$store"
    ( umask 077
      jq -nc --arg time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson res "$res" --argjson checks "$checks" \
            --argjson dl "$dl" --arg model "$(fleet_conf FLEET_CLASSIFIER_MODEL)" \
            --arg build "$(fleet_conf FLEET_RUNTIME_BUILD)" '
          {kind: "gate-latency", format: 1, time: $time,
           path: "gate: hub-socket eval op, layers floor and classifier",
           model: $model, runtime_build: $build, gate_deadline_s: $dl,
           method: "nearest-rank percentiles; warm after one uncounted request, cold after a service restart",
           results: $res, checks: $checks}' > "$rec.tmp" && mv -- "$rec.tmp" "$rec" ) \
        || die 4 "could not write the latency record"
    chmod 600 "$rec"
    exec 9>&-

    printf '  %-6s %-5s %5s %8s %8s %8s %7s\n' tokens mode runs p50 p95 max faults
    jq -r '.[] | [.tokens, .mode, .runs, .p50_s, .p95_s, .max_s, .faults] | @tsv' <<<"$res" \
        | while IFS=$'\t' read -r tok mode r a b c f; do
            printf '  %-6s %-5s %5s %7ss %7ss %7ss %7s\n' "$tok" "$mode" "$r" "$a" "$b" "$c" "$f"
        done
    jq -r '.[] | [.status, .check, .mode, .value_s, .limit_s] | @tsv' <<<"$checks" \
        | while IFS=$'\t' read -r st c mode v l; do
            if [[ "$st" == OK ]]; then ok "$c ($mode): ${v} s within ${l} s"; else fail "$c ($mode): ${v} s not within ${l} s (or faults)"; fi
        done
    ok "latency record written (0600, hub only): $rec"
}

evalh_main() {
    local confdir=/etc/lane2 cmd
    if [[ "${1:-}" == --config-dir ]]; then
        confdir="${2:-}"; shift 2 || die 2 "usage: eval-harness.sh [--config-dir DIR] run|publish"
        [[ -n "$confdir" ]] || die 2 "usage: eval-harness.sh [--config-dir DIR] run|publish"
    fi
    EVALH_CONFDIR="$confdir"
    cmd="${1:-}"; shift || true

    if evalset_in_container; then
        fail "run on the hub"
        exit 4
    fi
    command -v jq >/dev/null || die 4 "jq not installed"
    evalset_load_config "$confdir/lane2.conf"
    fleet_use_config "$confdir/fleet.conf"

    case "$cmd" in
        run)     cmd_run "$@" ;;
        publish) cmd_publish "$@" ;;
        compare) cmd_compare "$@" ;;
        latency) cmd_latency "$@" ;;
        *) die 2 "usage: eval-harness.sh [--config-dir DIR] run --split tuning|heldout | publish <record> | compare <direct> <gate> | latency [--runs N] [--cold]" ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    evalh_main "$@"
fi
