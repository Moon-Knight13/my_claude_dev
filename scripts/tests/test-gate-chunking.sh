#!/usr/bin/env bash
# `cond && ok … || bad …` is safe in this file: ok and bad always return 0.
# shellcheck disable=SC2015
# test-gate-chunking.sh — content longer than the classifier context is
# classified in chunks, only by the decision core (SP1a story 2.7, #110; FR-4,
# AD-2, AD-20).
# tier: ci — real handler behind a real unix socket; the llama-server mock with
# a small context so long content really does not fit.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok()   { echo "  OK  $1"; ((PASS++)) || true; }
bad()  { echo " FAIL $1"; ((FAIL++)) || true; }
check(){ if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }

# shellcheck source=/dev/null
source "$ROOT/scripts/tests/gate-fixture.sh"
gf_setup
[[ -S "$SOCK" ]] || { echo " FAIL gate socket did not come up"; exit 1; }
# Mock tokens = bytes/4 + 1. n_ctx 512 holds ~1600 bytes of text with the prompt
# and fence; chunks of 1000 characters fit, 4000 do not.
echo 512 > "$MS/nctx"
CH="GATE_CHUNK_CHARS=1000"; OV="GATE_CHUNK_OVERLAP=100"; BU="GATE_CHUNK_BUDGET=8"
gf_conf "$CH" "$OV" "$BU" "GATE_MAX_REQUEST=1048576"
filler() { head -c "$1" /dev/zero | tr '\0' 'w' | sed 's/w\{9\}/& /g'; }   # words of 9+space
bodies() { jq -r 'select(.path == "/v1/chat/completions") | .body | (if type == "string" then fromjson else . end)
                  | .messages[-1].content' "$MS/requests.jsonl"; }

# =============================================================================
echo "== short content: one call, no chunking =="
: > "$MS/requests.jsonl"
gf_ask classifier "a short request"
check "allow" "$RC" 0
check "one classifier call" "$(gf_completions)" 1

echo "== long content: chunked, every chunk classified =="
: > "$MS/requests.jsonl"
TEXT="$(filler 3500)"
gf_ask classifier "$TEXT"
check "long clear content: allow" "$RC" 0
N="$(bash -c 'source "$1"; GATE_CHUNK_CHARS=1000; GATE_CHUNK_OVERLAP=100; gate_chunk_count "$2"' _ "$ROOT/scripts/lib/gate.sh" "${#TEXT}")"
check "expected chunk count for ${#TEXT} characters" "$N" 5
check "one classifier call per chunk" "$(gf_completions)" "$N"
LENS="$(bodies | awk '{ print length }' | sort -n | tail -1)"
(( LENS < 1500 )) && ok "every chunk is within the chunk size (largest body $LENS chars)" || bad "a chunk is too big ($LENS)"

echo "== chunk boundaries =="
: > "$MS/requests.jsonl"
# The marker straddles the first boundary (character 1000): the overlap puts it
# whole in the second chunk.
LONG="$(filler 960)ZZSENSITIVE$(filler 2000)"
gf_ask classifier "$LONG"
check "a sensitive phrase on a chunk boundary is still seen: block" "$REASON" "hit:classifier"
bodies | grep -q ZZSENSITIVE && ok "the phrase reached the classifier whole" || bad "the phrase was cut at a boundary"

echo "== one sensitive chunk blocks the whole request =="
: > "$MS/requests.jsonl"
gf_ask classifier "$(filler 2600)ZZSENSITIVE$(filler 200)"
check "block" "$RC" 3
check "hit:classifier" "$REASON" "hit:classifier"

echo "== one faulted chunk blocks the whole request =="
printf 'ZZSENSITIVE\t{"verdict":"sensitive"}\nZZBROKEN\tMALFORMED\n' > "$MS/rules"
gf_ask classifier "$(filler 2600)ZZBROKEN$(filler 200)"
check "block" "$RC" 3
check "fault:classifier" "$REASON" "fault:classifier"
gf_mode toolong
gf_ask classifier "$(filler 2500)"
check "a chunk that still does not fit: fault:oversize" "$REASON" "fault:oversize"
gf_mode ok

echo "== chunk budget =="
gf_conf "$CH" "$OV" "GATE_CHUNK_BUDGET=3" "GATE_MAX_REQUEST=1048576"
: > "$MS/requests.jsonl"
START=$(date +%s); gf_ask classifier "$(filler 5000)"; END=$(date +%s)
check "more chunks than the budget: fault:timeout" "$REASON" "fault:timeout"
check "no classifier call for a request over the budget (only the fit probe)" "$(gf_completions)" 0
(( END - START < 10 )) && ok "answered well before the caller's deadline ($((END - START)) s)" || bad "took $((END - START)) s"
gf_conf "$CH" "$OV" "$BU"

echo "== GATE_MAX_REQUEST still bounds the request =="
gf_conf "$CH" "$OV" "$BU" "GATE_MAX_REQUEST=4096"
OUT="$( { printf '{"v":1,"op":"eval","layers":["classifier"]}\n'; filler 5000; } | gf_raw raw)"
check "over GATE_MAX_REQUEST: fault:oversize, never chunked" "$(gf_reason_of "$OUT")" "fault:oversize"
gf_conf "$CH" "$OV" "$BU" "GATE_MAX_REQUEST=1048576"

echo "== the floor runs on the whole text, not per chunk =="
gf_ask floor,classifier "$(filler 2000) zzalpha $(filler 1000)"
check "a term deep in long content: hit:floor" "$REASON" "hit:floor"

echo "== only the decision core chunks =="
CALLERS="$(grep -rlE '_gate_classify_chunks|gate_chunk_count' "$ROOT/scripts" --include='*' 2>/dev/null \
    | grep -v '/tests/' | sed "s|$ROOT/||" | sort | tr '\n' ' ')"
check "chunking lives in the gate lib only" "$CALLERS" "scripts/lib/gate.sh "
hasnt_split() { grep -lE '\bsplit -|head -c "\$\(\( *GATE_CHUNK' "$ROOT/scripts/lib/gate-client.sh" "$ROOT/scripts/hub/lane2" 2>/dev/null; }
check "the client never splits" "$(hasnt_split)" ""

echo "== config bounds =="
cfg() { gf_conf "$@"; bash "$GF_HANDLER" --check-config "$CONF" >/dev/null 2>&1; echo $?; }
check "default chunk settings valid" "$(cfg)" 0
check "chunk size 100 refused" "$(cfg GATE_CHUNK_CHARS=100)" 4
check "overlap over a quarter of the chunk refused" "$(cfg GATE_CHUNK_CHARS=1000 GATE_CHUNK_OVERLAP=300)" 4
check "budget 0 refused" "$(cfg GATE_CHUNK_BUDGET=0)" 4
gf_conf

echo
echo "gate-chunking: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
