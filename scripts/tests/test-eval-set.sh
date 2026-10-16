#!/usr/bin/env bash
# `cond && ok … || bad …` is safe in this file: ok and bad always return 0.
# shellcheck disable=SC2015
# test-eval-set.sh — the operator-owned eval set and its held-out freeze
# (SP1a story 1.1, #97; FR-35, FR-38, FR-50, NFR-5).
# tier: ci — synthetic fixtures only; the drafting model is a PATH curl stub.
#
# Pins: every validation rule; Clopper-Pearson sizing at 0/1/2 misses for <= 10%
# and <= 5% (and the addendum A3 table); freeze / re-freeze; drafting-model
# refusal; encrypted-only export; "run on the hub"; and that no real eval case,
# term, or term derivative is tracked in this public repo.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ES="$ROOT/scripts/hub/eval-set.sh"
PASS=0; FAIL=0
ok()   { echo "  OK  $1"; ((PASS++)) || true; }
bad()  { echo " FAIL $1"; ((FAIL++)) || true; }
check(){ if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (no '$3' in output)"; printf '%s\n' "$2" | sed 's/^/      | /' ;; esac; }
hasnt(){ case "$2" in *"$3"*) bad "$1 ('$3' leaked into output)" ;; *) ok "$1" ;; esac; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
CONF="$TMP/conf"; STATE="$TMP/state"; STORE="$STATE/eval"
mkdir -p "$CONF" "$STATE"

# Run the tool as on the hub. This suite runs in a dev container too, so the
# container check is stubbed here; the real check is tested on its own below.
es() {
    bash -c 'source "$1"; shift; evalset_in_container() { return 1; }; evalset_main "$@"' \
        _ "$ES" --config-dir "$CONF" "$@"
}
run() { OUT="$(es "$@" 2>&1)"; RC=$?; }

writeconf() { # writeconf [extra lines...]
    { echo "LANE2_STATE_ROOT=$STATE"; printf '%s\n' "$@"; } > "$CONF/lane2.conf"
}

# --- synthetic set generator -------------------------------------------------
# gen <file> <split> <category> <label> <hard_negative> <count> [provenance]
# Every case's text carries the marker ZZCASETEXT so output can be checked for it.
gen() {
    local f="$1" split="$2" cat="$3" label="$4" hn="$5" n="$6" prov="${7:-operator}"
    jq -nc --arg s "$split" --arg c "$cat" --arg l "$label" --argjson hn "$hn" \
           --arg p "$prov" --argjson n "$n" '
        range(1; $n + 1) as $i
        | {id: "\($s)-\($c)-\($l)-\($hn)-\($i)-x", category: $c, label: $l, hard_negative: $hn,
           split: $s, provenance: $p, labelled_by: "operator", synthetic: true}
        + if $c == "multi-block"
          then {blocks: ["ZZCASETEXT part one", "ZZCASETEXT part two"]}
          else {prompt: "ZZCASETEXT synthetic case"} end' >> "$f"
}

# A valid set. Per split, sensitive: plain 9, obfuscated 6, buried 3+2,
# multi-block 4, inference 6 (mix 30/20/17/13/20 of 30), adversarial 2 -> 32
# held-out sensitive (>= 29 for <= 10% at 0 misses). Non-sensitive: 60 tuning
# (24 hard negatives) + 40 held-out (16) = 100, 40% hard negatives.
mkset() {
    rm -rf "$STORE"; mkdir -m 700 "$STORE"
    local s f
    for s in tuning heldout; do
        f="$STORE/$s.jsonl"; : > "$f"
        gen "$f" "$s" plain sensitive false 9
        gen "$f" "$s" obfuscated sensitive false 6
        gen "$f" "$s" buried-5k sensitive false 3
        gen "$f" "$s" buried-20k sensitive false 2
        gen "$f" "$s" multi-block sensitive false 4
        gen "$f" "$s" inference sensitive false 6
        gen "$f" "$s" adversarial sensitive false 2
    done
    gen "$STORE/tuning.jsonl"  tuning  plain nonsensitive true  24
    gen "$STORE/tuning.jsonl"  tuning  plain nonsensitive false 36
    gen "$STORE/heldout.jsonl" heldout plain nonsensitive true  16
    gen "$STORE/heldout.jsonl" heldout plain nonsensitive false 24
    chmod 600 "$STORE"/*.jsonl
}
drop() { # drop <file> <jq-select> <n> — remove the first n cases matching
    local f="$STORE/$1"
    jq -c --arg n "$3" -s '
        reduce .[] as $c ({out: [], left: ($n | tonumber)};
          if .left > 0 and ($c | '"$2"') then .left -= 1 else .out += [$c] end) | .out[]' \
        "$f" > "$f.new" && mv "$f.new" "$f" && chmod 600 "$f"
}
edit() { # edit <file> <jq-filter applied to every case>
    local f="$STORE/$1"
    jq -c "$2" "$f" > "$f.new" && mv "$f.new" "$f" && chmod 600 "$f"
}

# =============================================================================
echo "== Clopper-Pearson sizing =="
# shellcheck source=/dev/null
cp_req() { bash -c 'source "$1"; evalset_cp_required "$2" "$3"' _ "$ES" "$1" "$2"; }
check "<=10%, 0 misses -> 29" "$(cp_req 10 0)" 29
check "<=10%, 1 miss  -> 46"  "$(cp_req 10 1)" 46
check "<=10%, 2 misses -> 61" "$(cp_req 10 2)" 61
check "<=5%, 0 misses -> 59"  "$(cp_req 5 0)" 59
check "<=5%, 1 miss  -> 93"   "$(cp_req 5 1)" 93
check "<=5%, 2 misses -> 124" "$(cp_req 5 2)" 124
check "<=2%  row (addendum A3)" "$(cp_req 2 0) $(cp_req 2 1) $(cp_req 2 2)" "149 236 313"
check "<=1%  row (addendum A3)" "$(cp_req 1 0) $(cp_req 1 1) $(cp_req 1 2)" "299 473 628"

# =============================================================================
echo "== validate: a valid set passes =="
writeconf; mkset
run validate
check "valid set exits 0" "$RC" 0
has "reports the held-out sizing" "$OUT" "required 29, have 32"
hasnt "never prints case text" "$OUT" ZZCASETEXT
hasnt "no FAIL lines" "$OUT" " FAIL "

echo "== validate: >= 100 non-sensitive =="
mkset; drop tuning.jsonl '.label == "nonsensitive" and .hard_negative == false' 1
run validate
check "99 non-sensitive exits 3" "$RC" 3
has "names the count" "$OUT" " FAIL non-sensitive cases >= 100: 99"
hasnt "never prints case text" "$OUT" ZZCASETEXT

echo "== validate: >= 40% hard negatives =="
mkset; edit tuning.jsonl 'if .label == "nonsensitive" and .hard_negative and (.id | test("-1-")) then .hard_negative = false else . end'
run validate
check "39% hard negatives exits 3" "$RC" 3
has "names the counts" "$OUT" " FAIL hard negatives >= 40% of non-sensitive: 39 of 100"

echo "== validate: every category in each split =="
mkset; drop heldout.jsonl '.category == "adversarial"' 2
run validate
check "no adversarial held-out case exits 3" "$RC" 3
has "names the gap" "$OUT" "missing adversarial/heldout"

echo "== validate: sensitive mix within 5 points =="
mkset; drop tuning.jsonl '.category == "plain" and .label == "sensitive"' 8
run validate
check "plain share too low exits 3" "$RC" 3
has "mix rule fails" "$OUT" " FAIL sensitive mix within 5 points"

echo "== validate: held-out sizing follows the configured bound =="
mkset; writeconf LANE2_EVAL_HELDOUT_MISSES=1
run validate
check "1 allowed miss needs 46: exits 3" "$RC" 3
has "names required and actual" "$OUT" "required 46, have 32"
writeconf LANE2_EVAL_MISS_BOUND=5
run validate
check "tightened bound (5%) raises the requirement: exits 3" "$RC" 3
has "names the 5% requirement" "$OUT" "required 59, have 32"
writeconf LANE2_EVAL_MISS_BOUND=0
run validate
check "a nonsense bound is a fault" "$RC" 4
writeconf

echo "== validate: provenance and labelling =="
mkset; edit heldout.jsonl 'if (.id | test("-1-")) and .category == "plain" then .provenance = ("local:drafter@" + ("a" * 64)) else . end'
run validate
check "held-out case drafted by a local model exits 3" "$RC" 3
has "held-out must be operator-written" "$OUT" " FAIL held-out cases operator-written"

mkset; edit tuning.jsonl 'if (.id | test("-1-")) and .category == "plain" then .provenance = ("local:drafter@" + ("a" * 64)) else . end'
run validate
check "operator-labelled local draft in tuning is accepted" "$RC" 0

mkset; edit tuning.jsonl 'if (.id | test("-1-")) and .category == "plain" then .provenance = "claude" else . end'
run validate
check "a cloud-model provenance exits 3" "$RC" 3
has "names the provenance rule" "$OUT" " FAIL provenance is operator or local"

mkset; edit tuning.jsonl 'if (.id | test("-1-")) and .category == "plain" then .provenance = "" else . end'
run validate
check "an empty provenance exits 3" "$RC" 3

mkset; edit tuning.jsonl 'if (.id | test("-1-")) and .category == "inference" then del(.labelled_by) else . end'
run validate
check "a case with no labeller exits 3" "$RC" 3
has "names the labelling rule" "$OUT" " FAIL every case operator-labelled"

mkset; edit tuning.jsonl 'if (.id | test("-1-")) and .category == "inference" then .label = null else . end'
run validate
check "an unlabelled case exits 3" "$RC" 3

echo "== validate: case format =="
mkset; edit tuning.jsonl 'if .category == "multi-block" and (.id | test("-1-")) then .blocks = ["only one"] else . end'
run validate
check "a multi-block case with one block exits 3" "$RC" 3
has "names the format rule" "$OUT" " FAIL case format"
mkset; edit tuning.jsonl 'if .label == "sensitive" and (.id | test("-1-")) and .category == "plain" then .hard_negative = true else . end'
run validate
check "a sensitive hard negative is malformed" "$RC" 3
mkset; edit heldout.jsonl 'if (.id | test("-1-")) and .category == "plain" then .split = "tuning" else . end'
run validate
check "a case whose split field disagrees with its file exits 3" "$RC" 3
mkset; DUP="$(head -1 "$STORE/tuning.jsonl")"; printf '%s\n' "$DUP" >> "$STORE/tuning.jsonl"
run validate
check "duplicate ids exit 3" "$RC" 3
has "names the id rule" "$OUT" " FAIL case ids unique: 1"

echo "== store modes =="
mkset; chmod 755 "$STORE"
run validate
check "a loose store directory is a fault" "$RC" 4
has "says why" "$OUT" "mode 0700"
chmod 700 "$STORE"; chmod 644 "$STORE/heldout.jsonl"
run validate
check "a loose store file is a fault" "$RC" 4

# =============================================================================
echo "== freeze and frozen-check =="
mkset
run frozen-check
check "no freeze record: frozen-check exits 3" "$RC" 3
run freeze
check "initial freeze exits 0" "$RC" 0
hasnt "freeze never prints case text" "$OUT" ZZCASETEXT
check "freeze record is 0600" "$(stat -c %a "$STORE/freeze.jsonl")" 600
check "store directory is 0700" "$(stat -c %a "$STORE")" 700
REC="$(tail -1 "$STORE/freeze.jsonl")"
check "record: reason initial" "$(jq -r .reason <<<"$REC")" initial
check "record: case count" "$(jq -r .cases <<<"$REC")" 72
WANT="$(jq -cS . "$STORE/heldout.jsonl" | LC_ALL=C sort | sha256sum | cut -d' ' -f1)"
check "record: digest of the canonicalised held-out file" "$(jq -r .digest <<<"$REC")" "$WANT"
jq -r .time <<<"$REC" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' && ok "record: time" || bad "record: time"

run frozen-check
check "unchanged held-out: frozen-check exits 0" "$RC" 0
# Reordering lines does not change the canonical digest.
tac "$STORE/heldout.jsonl" > "$STORE/h.new" && mv "$STORE/h.new" "$STORE/heldout.jsonl" && chmod 600 "$STORE/heldout.jsonl"
run frozen-check
check "line order does not matter" "$RC" 0

run freeze
check "second initial freeze refused" "$RC" 3
check "refusal adds no record" "$(wc -l < "$STORE/freeze.jsonl")" 1
run freeze --reason leaked
check "leaked re-freeze of an unchanged split refused" "$RC" 3

edit heldout.jsonl 'if (.id | test("-1-")) and .category == "plain" then .prompt = "ZZCASETEXT replacement" else . end'
run frozen-check
check "changed held-out: frozen-check exits 3" "$RC" 3
has "says it changed" "$OUT" "changed since it was frozen"
run freeze --reason leaked
check "leaked re-freeze of a replaced split exits 0" "$RC" 0
check "new record beside the old one" "$(wc -l < "$STORE/freeze.jsonl")" 2
check "new record points at the old digest" "$(tail -1 "$STORE/freeze.jsonl" | jq -r .previous)" "$WANT"
run frozen-check
check "frozen-check follows the latest record" "$RC" 0
run freeze --reason whim
check "unknown reason is a usage error" "$RC" 2

mkset
drop heldout.jsonl '.label == "sensitive" and .category == "plain"' 6
run freeze
check "an undersized held-out split is not frozen" "$RC" 3
[[ ! -e "$STORE/freeze.jsonl" ]] && ok "no record written" || bad "record written for an invalid split"
mkset
run freeze --reason leaked
check "leaked with no prior freeze refused" "$RC" 3

# =============================================================================
echo "== draft =="
STUBDIR="$TMP/bin"; mkdir -p "$STUBDIR"
CALLS="$TMP/curl-calls"
cat > "$STUBDIR/curl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CALLS"
cat > "$TMP/curl-body"
printf '{"choices":[{"message":{"content":"ZZDRAFTTEXT drafted case"}}]}'
EOF
chmod +x "$STUBDIR/curl"
SHA_D="$(printf 'd%.0s' {1..64})"; SHA_C="$(printf 'c%.0s' {1..64})"
draft() { OUT="$(PATH="$STUBDIR:$PATH" es draft "$@" <<<"ZZREQUEST write one" 2>&1)"; RC=$?; }

mkset; rm -f "$CALLS"
writeconf "LANE2_EVAL_DRAFT_MODEL=drafter" "LANE2_EVAL_DRAFT_SHA256=$SHA_D" \
          "LANE2_EVAL_DRAFT_ENDPOINT=http://127.0.0.1:8090" \
          "LANE2_EVAL_CANDIDATE=classifier-a $SHA_C" "LANE2_EVAL_CANDIDATE=drafter $SHA_C"
draft
(( RC >= 4 )) && ok "drafting model id matches a candidate: refused (exit $RC)" || bad "id match not refused (exit $RC)"
[[ ! -e "$CALLS" ]] && ok "no model call made" || bad "model called despite refusal"

writeconf "LANE2_EVAL_DRAFT_MODEL=drafter" "LANE2_EVAL_DRAFT_SHA256=$SHA_D" \
          "LANE2_EVAL_DRAFT_ENDPOINT=http://127.0.0.1:8090" \
          "LANE2_EVAL_CANDIDATE=classifier-a $SHA_C" "LANE2_EVAL_CANDIDATE=renamed-copy ${SHA_D^^}"
draft
(( RC >= 4 )) && ok "drafting model checksum matches a candidate: refused" || bad "checksum match not refused (exit $RC)"
[[ ! -e "$CALLS" ]] && ok "no model call made" || bad "model called despite refusal"

for ep in "http://192.0.2.10:8090" "https://127.0.0.1:8090" "http://user@127.0.0.1:8090" "http://127.0.0.1.example.test:8090"; do
    writeconf "LANE2_EVAL_DRAFT_MODEL=drafter" "LANE2_EVAL_DRAFT_SHA256=$SHA_D" \
              "LANE2_EVAL_DRAFT_ENDPOINT=$ep" "LANE2_EVAL_CANDIDATE=classifier-a $SHA_C"
    draft
    (( RC >= 4 )) && ok "non-loopback endpoint refused: $ep" || bad "endpoint accepted: $ep (exit $RC)"
done
[[ ! -e "$CALLS" ]] && ok "no model call made" || bad "model called despite refusal"

writeconf "LANE2_EVAL_DRAFT_MODEL=drafter" "LANE2_EVAL_DRAFT_SHA256=$SHA_D" \
          "LANE2_EVAL_DRAFT_ENDPOINT=http://127.0.0.1:8090"
draft
(( RC >= 4 )) && ok "no candidates configured: refused" || bad "drafted with no candidate list (exit $RC)"

writeconf "LANE2_EVAL_DRAFT_MODEL=drafter" "LANE2_EVAL_DRAFT_SHA256=$SHA_D" \
          "LANE2_EVAL_DRAFT_ENDPOINT=http://127.0.0.1:8090" "LANE2_EVAL_CANDIDATE=classifier-a $SHA_C"
HELD_BEFORE="$(sha256sum < "$STORE/heldout.jsonl")"; TUNE_BEFORE="$(sha256sum < "$STORE/tuning.jsonl")"
draft --category obfuscated
check "a valid draft request exits 0" "$RC" 0
hasnt "draft text not printed" "$OUT" ZZDRAFTTEXT
D="$(tail -1 "$STORE/drafts.jsonl" 2>/dev/null)"
check "draft provenance local:<id>@<sha256>" "$(jq -r .provenance <<<"$D")" "local:drafter@$SHA_D"
check "draft is unlabelled" "$(jq -r '.label, .labelled_by, .split' <<<"$D" | tr '\n' ' ')" "null null null "
check "draft keeps the requested category" "$(jq -r .category <<<"$D")" obfuscated
check "drafts file is 0600" "$(stat -c %a "$STORE/drafts.jsonl")" 600
check "held-out split untouched" "$(sha256sum < "$STORE/heldout.jsonl")" "$HELD_BEFORE"
check "tuning split untouched" "$(sha256sum < "$STORE/tuning.jsonl")" "$TUNE_BEFORE"
has "model called with proxies off" "$(cat "$CALLS")" "--noproxy *"
hasnt "request text never on argv" "$(cat "$CALLS")" ZZREQUEST
has "request text sent in the body" "$(cat "$TMP/curl-body")" ZZREQUEST
draft --category nonsense
check "unknown category is a usage error" "$RC" 2

# =============================================================================
echo "== export =="
writeconf
run export --out "$TMP/plain.tar" --plaintext
check "plaintext export refused" "$RC" 3
[[ ! -e "$TMP/plain.tar" ]] && ok "nothing written" || bad "plaintext file written"
run export --out "$TMP/x.gpg"
(( RC >= 4 )) && ok "no recipient configured: refused" || bad "exported without a recipient (exit $RC)"

if command -v gpg >/dev/null; then
    export GNUPGHOME="$TMP/gnupg"; mkdir -m 700 "$GNUPGHOME"
    gpg --batch --quiet --passphrase '' --quick-gen-key 'eval test <eval@example.invalid>' future-default default never 2>/dev/null
    FPR="$(gpg --batch --with-colons --list-keys 2>/dev/null | awk -F: '/^fpr:/ { print $10; exit }')"
    writeconf "LANE2_EVAL_EXPORT_RECIPIENT=$FPR"
    run export --out "$TMP/eval.gpg"
    check "encrypted export exits 0" "$RC" 0
    if grep -q ZZCASETEXT "$TMP/eval.gpg" 2>/dev/null; then bad "export contains plaintext"; else ok "export is not plaintext"; fi
    has "export decrypts to the store files" \
        "$(gpg --batch --quiet --decrypt "$TMP/eval.gpg" 2>/dev/null | tar -tf - 2>/dev/null | tr '\n' ' ')" "heldout.jsonl"
    run export --out "$TMP/eval.gpg"
    check "existing output is not overwritten" "$RC" 2
    unset GNUPGHOME
else
    bad "gpg not installed; encrypted export untested"
fi

# =============================================================================
echo "== every command refuses inside a container =="
for c in validate freeze frozen-check draft export; do
    OUT="$(DEVCONTAINER=true bash "$ES" --config-dir "$CONF" "$c" 2>&1 </dev/null)"; RC=$?
    (( RC >= 4 )) && [[ "$OUT" == *" FAIL run on the hub"* ]] \
        && ok "$c: run on the hub" || bad "$c ran in a container (exit $RC: $OUT)"
done

# =============================================================================
echo "== tracked-file hygiene =="
# Only the format reference with synthetic examples may be tracked. Real cases,
# split files, freeze records, drafts, and term lists live on the hub only.
FIXTURE="scripts/tests/fixtures/sensitivity-eval.jsonl"
TRACKED="$(git -C "$ROOT" ls-files)"
if [[ -z "$TRACKED" ]]; then
    bad "cannot list tracked files"
else
    STRAY="$(grep -E '(^|/)(heldout|tuning|freeze|drafts)[^/]*\.jsonl$|(^|/)eval-store/' <<<"$TRACKED" || true)"
    check "no split, freeze, or draft file tracked" "$STRAY" ""
    TERMS="$(grep -iE '(^|/)[^/]*term-?list[^/]*$' <<<"$TRACKED" | grep -vE '\.example\.txt$' || true)"
    check "only example term lists tracked" "$TERMS" ""
    CASEFILES=""
    while IFS= read -r f; do
        [[ "$f" == "$FIXTURE" ]] && continue
        [[ -f "$ROOT/$f" ]] || continue
        jq -e -s 'any(.[]; type == "object" and has("label") and (has("split") or has("provenance")))' \
            "$ROOT/$f" >/dev/null 2>&1 && CASEFILES+="$f "
    done < <(grep -E '\.jsonl?$' <<<"$TRACKED")
    check "no other tracked file holds eval cases" "$CASEFILES" ""
    check "every fixture case is synthetic" \
        "$(jq -s 'map(select(.synthetic != true)) | length' "$ROOT/$FIXTURE")" 0
    # The fixture is a format reference: every case must be well formed. Its
    # split field must match the file it would live in, so check each split.
    for s in tuning heldout; do
        jq -c --arg s "$s" 'select(.split == $s)' "$ROOT/$FIXTURE" > "$TMP/fx-$s.jsonl"
    done
    FX="$(bash -c 'source "$1"; evalset_stats "$2" "$3"' _ "$ES" "$TMP/fx-tuning.jsonl" "$TMP/fx-heldout.jsonl")"
    check "fixture cases are well formed" "$(jq -r '.bad_format + .dup_ids + .bad_provenance + .unlabelled + .heldout_not_operator' <<<"$FX")" 0
    check "fixture covers every category" "$(jq -s 'map(.category) | unique | length' "$ROOT/$FIXTURE")" 7
fi

echo
echo "eval-set: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
