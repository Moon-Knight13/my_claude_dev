#!/usr/bin/env bash
# `cond && ok … || bad …` is safe in this file: ok and bad always return 0.
# shellcheck disable=SC2015
# test-classifier.sh — deterministic contract tests for classify-sensitivity.sh.
# tier: ci. The live-model behaviour is measured by eval-classifier.sh; here we
# mock the model call and prove the parts that MUST hold regardless of the model:
#   1. strict parse (only a clean "nonsensitive" unlocks the cloud tier)
#   2. fail-closed on every error/garbled/empty case
#   3. never egresses (a non-local endpoint is refused without a call)
#   4. the prompt arrives on stdin, never argv, and reaches no process's argv
#
# Transport leg (SP1a story 1.3, NFR-2): LOCAL_MODEL_API picks the leg, as CI's
# matrix sets it. ollama (default) mocks the model with a PATH curl stub;
# openai runs the real fleet_call against scripts/tests/mock-llama-server.py.
# Both legs also run orch_classify's stdin hand-off and eval-classifier.sh
# --parallel-verify, which needs both transports at once.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok()   { echo "  OK  $1"; ((PASS++)) || true; }
bad()  { echo " FAIL $1"; ((FAIL++)) || true; }
check(){ if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }

CLS="$ROOT/scripts/orchestrator/classify-sensitivity.sh"
EVC="$ROOT/scripts/orchestrator/eval-classifier.sh"
SETTINGS="$ROOT/scripts/hub/fleet/classifier.settings.json"
LEG="${LOCAL_MODEL_API:-ollama}"
TMP="$(mktemp -d)"
PIDS=()
cleanup() { local p; for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; rm -rf "$TMP"; }
trap cleanup EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"
export ORCH_CLASSIFIER_PROMPT_FILE="$TMP/nope-prompt.md"

# --- mocks -------------------------------------------------------------------
# PATH curl stub: an Ollama /api/generate call is answered here from MOCK_RESP
# (or fails with MOCK_FAIL=1) and logged; any other call is passed to the real
# curl, so fleet_call reaches the llama-server mock.
REAL_CURL="$(command -v curl)"
MOCKBIN="$TMP/bin"; mkdir -p "$MOCKBIN"
cat > "$MOCKBIN/curl" <<EOF
#!/usr/bin/env bash
case "\$*" in
    */api/generate*)
        printf '%s\n' "\$*" >> "\$CURL_LOG"
        [[ "\${MOCK_FAIL:-0}" == 1 ]] && exit 22
        jq -n --arg r "\${MOCK_RESP:-}" '{response:\$r}' ;;
    *)  printf '%s\n' "\$*" >> "\$CURL_LOG"
        exec "$REAL_CURL" "\$@" ;;
esac
EOF
chmod +x "$MOCKBIN/curl"
export CURL_LOG="$TMP/curl.log"

MS="$TMP/mock"; mkdir -p "$MS"
MOCK_STATE_DIR="$MS" python3 "$ROOT/scripts/tests/mock-llama-server.py" & PIDS+=($!)
for _ in $(seq 50); do [[ -s "$MS/port" ]] && break; sleep 0.1; done
PORT="$(cat "$MS/port" 2>/dev/null)"
[[ -n "$PORT" ]] || { echo " FAIL llama-server mock did not start"; exit 1; }
FCONF="$TMP/fleet.conf"
SHA_M="$(printf 'e%.0s' {1..64})"
fleetconf() { printf '%s\n' "FLEET_PROBE_TIMEOUT=1" "FLEET_CLASSIFIER_MODEL=clf-test" \
    "FLEET_CLASSIFIER_SHA256=$SHA_M" "FLEET_STATE_DIR=$TMP/state" "$@" > "$FCONF"; }
fleetconf "FLEET_CLASSIFIER_ENDPOINT=http://127.0.0.1:$PORT"
mmode()    { printf '%s' "$1" > "$MS/mode"; }
mcontent() { printf '%s' "$1" > "$MS/content"; }
mreset()   { mmode ok; rm -f "$MS/content"; : > "$MS/requests.jsonl"; }

# reply <verdict-word> — what the mock model says, in the leg's own format.
reply() {
    if [[ "$LEG" == openai ]]; then mcontent "$1"; else export MOCK_RESP="$1"; fi
}
# run — classify stdin under this leg, with a LOCAL endpoint and a fresh log.
run() {
    : > "$CURL_LOG"
    PATH="$MOCKBIN:$PATH" LOCAL_MODEL_API="$LEG" \
    ORCH_CLASSIFIER_ENDPOINT="http://127.0.0.1:11434" ORCH_CLASSIFIER_TIMEOUT=5 \
    bash "$CLS" --fleet-config "$FCONF" "$@"
}
calls() { [[ -s "$CURL_LOG" ]] && echo called || echo none; }

echo "== leg: LOCAL_MODEL_API=$LEG =="
if [[ "$LEG" == ollama ]]; then
    echo "== strict parse (ollama) =="
    check "clean nonsensitive -> nonsensitive" "$(MOCK_RESP='nonsensitive' run <<<'refactor foo')" nonsensitive
    check "clean sensitive -> sensitive"       "$(MOCK_RESP='sensitive'    run <<<'refactor foo')" sensitive
    check "uppercase honoured"                 "$(MOCK_RESP='NONSENSITIVE' run <<<'x')"            nonsensitive
    check "trailing punctuation honoured"      "$(MOCK_RESP='nonsensitive.' run <<<'x')"           nonsensitive
    # qwen3 thinking block must be stripped before the verdict is read
    check "think block stripped (nonsens)"     "$(MOCK_RESP='<think>the task is a generic refactor</think>nonsensitive' run <<<'x')" nonsensitive
    check "think block stripped (sens)"        "$(MOCK_RESP='<think>has an email</think>sensitive' run <<<'x')" sensitive
    # realistic qwen3 multi-line output: reasoning remnant, verdict on the last line
    check "qwen3 multiline verdict (nonsens)"  "$(MOCK_RESP=$' \\boxed{nonsensitive}\n\n</think>\n\nnonsensitive' run <<<'x')" nonsensitive
    check "qwen3 boxed-only last line (sens)"  "$(MOCK_RESP=$'</think>\n\\boxed{sensitive}' run <<<'x')" sensitive
    # reasoning that says "not nonsensitive" above the verdict must NOT unlock cloud
    check "negation in reasoning ignored"      "$(MOCK_RESP=$'this is not nonsensitive\nsensitive' run <<<'x')" sensitive

    echo "== fail closed (ollama) =="
    check "verbose answer -> sensitive"        "$(MOCK_RESP='Sure, this is nonsensitive!' run <<<'x')" sensitive
    check "empty response -> sensitive"        "$(MOCK_RESP='' run <<<'x')"                        sensitive
    check "garbage token -> sensitive"         "$(MOCK_RESP='banana' run <<<'x')"                  sensitive
    check "negation not mis-read -> sensitive" "$(MOCK_RESP='this is not nonsensitive' run <<<'x')" sensitive
    check "curl failure/timeout -> sensitive"  "$(MOCK_FAIL=1 run <<<'x')"                         sensitive
    MOCK_FAIL=1 run --report-faults <<<'x' >/dev/null; check "--report-faults: a fault exits 5" "$?" 5
    MOCK_RESP='sensitive' run --report-faults <<<'x' >/dev/null; check "--report-faults: a real verdict exits 0" "$?" 0

    echo "== never egresses (ollama) =="
    : > "$CURL_LOG"
    v="$(MOCK_RESP='nonsensitive' PATH="$MOCKBIN:$PATH" LOCAL_MODEL_API=ollama \
         ORCH_CLASSIFIER_ENDPOINT="https://api.anthropic.com" bash "$CLS" <<<'benign prompt')"
    check "cloud endpoint refused -> sensitive" "$v" sensitive
    check "cloud endpoint makes no call"        "$(calls)" none
    MOCK_RESP='nonsensitive' run <<<'benign prompt' >/dev/null
    check "local endpoint is used" "$(grep -c '127.0.0.1:11434/api/generate' "$CURL_LOG")" 1
    grep -q 'ZZOLLAMAARGV' "$CURL_LOG" && bad "prompt on curl argv" || ok "prompt not on curl argv"
    MOCK_RESP='nonsensitive' run <<<'ZZOLLAMAARGV prompt' >/dev/null
    grep -q 'ZZOLLAMAARGV' "$CURL_LOG" && bad "prompt on curl argv" || ok "prompt not on curl argv (sent as a file)"
else
    echo "== strict parse (openai / fleet_call) =="
    mreset; reply '{"verdict":"nonsensitive"}'
    check "clean nonsensitive -> nonsensitive" "$(run <<<'refactor foo')" nonsensitive
    check "the call went to the llama-server mock" \
        "$(jq -r 'select(.path == "/v1/chat/completions") | .path' "$MS/requests.jsonl" | head -1)" /v1/chat/completions
    REQ="$(jq -c 'select(.path == "/v1/chat/completions") | .body | fromjson' "$MS/requests.jsonl" | tail -1)"
    check "request carries the pinned settings" \
        "$(jq -c '[.temperature, .seed, .max_tokens, .cache_prompt, .id_slot]' <<<"$REQ")" \
        "$(jq -c '[.params.temperature, .params.seed, .max_tokens, .params.cache_prompt, .params.id_slot]' "$SETTINGS")"
    check "request carries the verdict enum" \
        "$(jq -c '.response_format.json_schema.schema.properties.verdict.enum' <<<"$REQ")" '["sensitive","nonsensitive"]'
    check "system prompt is the shipped default" "$(jq -r '.messages[0].role' <<<"$REQ")" system
    jq -r '.messages[1].content' <<<"$REQ" | grep -q '^refactor foo$' \
        && ok "prompt fenced in the user message" || bad "prompt not fenced verbatim"
    mreset; reply '{"verdict":"sensitive"}'
    check "clean sensitive -> sensitive" "$(run <<<'x')" sensitive

    echo "== fail closed (openai / fleet_call) =="
    for c in '' 'nonsensitive' '{"verdict":"nonsensitive","x":1}' '{"verdict":"maybe"}' '{"verdict":"nonsens'; do
        mreset; reply "$c"
        check "reply '$c' -> sensitive" "$(run <<<'x')" sensitive
        run --report-faults <<<'x' >/dev/null; check "reply '$c': --report-faults exits 5" "$?" 5
    done
    for m in loading noctx toolong oversize malformed truncated; do
        mreset; mmode "$m"
        check "server $m -> sensitive" "$(run <<<'x')" sensitive
    done
    mreset; reply '{"verdict":"nonsensitive"}'
    run --report-faults <<<'x' >/dev/null; check "--report-faults: a real verdict exits 0" "$?" 0

    echo "== never egresses (openai / fleet_call) =="
    fleetconf "FLEET_CLASSIFIER_ENDPOINT=http://192.0.2.10:$PORT"
    mreset; reply '{"verdict":"nonsensitive"}'
    check "non-loopback fleet endpoint -> sensitive" "$(run <<<'benign')" sensitive
    check "non-loopback fleet endpoint makes no call" "$(calls)" none
    fleetconf
    check "missing fleet endpoint -> sensitive" "$(run <<<'benign')" sensitive
    check "missing fleet endpoint makes no call" "$(calls)" none
    : > "$CURL_LOG"
    v="$(PATH="$MOCKBIN:$PATH" LOCAL_MODEL_API=openai ORCH_CLASSIFIER_ENDPOINT="http://127.0.0.1:$PORT" \
         bash "$CLS" <<<'benign')"
    check "env endpoint ignored by the openai leg -> sensitive" "$v" sensitive
    fleetconf "FLEET_CLASSIFIER_ENDPOINT=http://127.0.0.1:$PORT"
    mreset; reply '{"verdict":"nonsensitive"}'
    run <<<'ZZOPENAIARGV prompt' >/dev/null
    grep -q 'ZZOPENAIARGV' "$CURL_LOG" && bad "prompt on curl argv" || ok "prompt not on curl argv"
    grep -q 'ZZOPENAIARGV' "$MS/requests.jsonl" && ok "prompt reached the model in the body" || bad "prompt not sent"
fi

echo "== stdin contract (both legs) =="
reply nonsensitive; [[ "$LEG" == openai ]] && reply '{"verdict":"nonsensitive"}'
: > "$CURL_LOG"
v="$(PATH="$MOCKBIN:$PATH" LOCAL_MODEL_API="$LEG" ORCH_CLASSIFIER_ENDPOINT="http://127.0.0.1:11434" \
     bash "$CLS" 'a prompt on argv' </dev/null)"
check "a prompt on argv is refused -> sensitive" "$v" sensitive
check "a prompt on argv makes no call" "$(calls)" none
check "empty stdin -> sensitive" "$(run </dev/null)" sensitive
check "empty stdin makes no model call" "$(calls)" none
head -c 2000 /dev/zero | tr '\0' 'a' > "$TMP/big"
check "prompt over ORCH_CLASSIFIER_MAX_BYTES -> sensitive" "$(ORCH_CLASSIFIER_MAX_BYTES=1000 run < "$TMP/big")" sensitive
check "oversize prompt makes no call" "$(calls)" none
check "unknown LOCAL_MODEL_API -> sensitive" \
    "$(PATH="$MOCKBIN:$PATH" LOCAL_MODEL_API=bogus bash "$CLS" <<<'x')" sensitive
# A large prompt (> 128 KiB argv limit) works on stdin.
head -c 200000 /dev/zero | tr '\0' 'b' > "$TMP/large"
printf '1000000' > "$MS/nctx"     # the llama-server mock must have room for it
check "200 KB prompt classified via stdin" "$(run < "$TMP/large")" nonsensitive
rm -f "$MS/nctx"

# orch_classify hands the prompt over on stdin, with no argv.
STUB="$TMP/stub.sh"
printf '#!/usr/bin/env bash\nprintf "%%s" "$#" > %q\ncat > %q\necho nonsensitive\n' "$TMP/stub-argc" "$TMP/stub-in" > "$STUB"
chmod +x "$STUB"
v="$(bash -c 'source "$1"; ORCH_CLASSIFIER="$2" orch_classify "ZZORCH prompt text"' _ "$ROOT/scripts/lib/orchestrator-route.sh" "$STUB")"
check "orch_classify: verdict honoured" "$v" nonsensitive
check "orch_classify: classifier gets no argv" "$(cat "$TMP/stub-argc")" 0
check "orch_classify: classifier gets the prompt on stdin" "$(cat "$TMP/stub-in")" "ZZORCH prompt text"

# =============================================================================
echo "== eval-classifier.sh --parallel-verify (both transports) =="
PVFIX="$TMP/pv.jsonl"
for i in 1 2 3; do
    jq -nc --arg i "$i" '{id: "pv-\($i)", label: "nonsensitive", prompt: "ZZPVTEXT case \($i)", note: "ZZPVNOTE"}' >> "$PVFIX"
done
pv() {
    : > "$CURL_LOG"
    OUT="$(PATH="$MOCKBIN:$PATH" ORCH_CLASSIFIER_ENDPOINT="http://127.0.0.1:11434" ORCH_CLASSIFIER_TIMEOUT=5 \
        bash -c 'source "$1"; shift; fleet_in_container() { return 1; }; evalcls_main "$@"' \
        _ "$EVC" --parallel-verify --fleet-config "$FCONF" "$@" 2>&1)"
    RC=$?
}
fleetconf "FLEET_CLASSIFIER_ENDPOINT=http://127.0.0.1:$PORT"
rm -rf "$TMP/state"; mreset
mcontent '{"verdict":"nonsensitive"}'; export MOCK_RESP=nonsensitive
pv "$PVFIX"
check "equal verdicts: exit 0" "$RC" 0
case "$OUT" in *"3 cases, 3 equal, 0 differ, 0 faults"*) ok "stdout shows counts" ;; *) bad "counts missing ($OUT)" ;; esac
case "$OUT" in *ZZPV*) bad "case text or note on stdout" ;; *) ok "no case text or note on stdout" ;; esac
check "both transports called per case (ollama)" "$(grep -c '/api/generate' "$CURL_LOG")" 3
check "both transports called per case (openai)" "$(grep -c '"/v1/chat/completions"' "$MS/requests.jsonl")" 3
ZD="$TMP/state/zero-diff.jsonl"
[[ -f "$ZD" ]] && ok "zero-diff record written" || bad "no zero-diff record"
check "state dir is 0700" "$(stat -c %a "$TMP/state" 2>/dev/null)" 700
check "zero-diff record is 0600" "$(stat -c %a "$ZD" 2>/dev/null)" 600
Z="$(tail -1 "$ZD" 2>/dev/null)"
check "zero-diff: model checksum" "$(jq -r .model_sha256 <<<"$Z")" "$SHA_M"
check "zero-diff: prompt checksum" "$(jq -r .prompt_sha256 <<<"$Z")" \
    "$(sha256sum < "$ROOT/scripts/orchestrator/classifier-prompt.default.md" | cut -d' ' -f1)"
check "zero-diff: settings checksum" "$(jq -r .settings_sha256 <<<"$Z")" "$(sha256sum < "$SETTINGS" | cut -d' ' -f1)"
check "zero-diff: fixture checksum" "$(jq -r .fixtures_sha256 <<<"$Z")" "$(sha256sum < "$PVFIX" | cut -d' ' -f1)"
REC="$TMP/state/parallel-verify/$(jq -r .record <<<"$Z")"
check "zero-diff points at its run record" "$(jq -r .record_sha256 <<<"$Z")" "$(sha256sum < "$REC" | cut -d' ' -f1)"
check "run record: header + one row per case" "$(wc -l < "$REC" | tr -d ' ')" 4
check "run record: per-case equality" "$(tail -n +2 "$REC" | jq -r .equal | sort -u)" true
grep -q ZZPV "$REC" && bad "case text in the run record" || ok "no case text in the run record"

MOCK_RESP=sensitive pv "$PVFIX"
check "a differing verdict: exit 3" "$RC" 3
case "$OUT" in *"3 differ"*) ok "difference reported as a count" ;; *) bad "difference count missing ($OUT)" ;; esac
check "no new zero-diff record on a difference" "$(wc -l < "$ZD" | tr -d ' ')" 1

mmode loading; pv "$PVFIX"; mmode ok
check "faults under one transport: exit 3" "$RC" 3
case "$OUT" in *"3 faults"*) ok "faults counted, not called equal" ;; *) bad "faults not counted ($OUT)" ;; esac
check "no new zero-diff record on faults" "$(wc -l < "$ZD" | tr -d ' ')" 1

fleetconf "FLEET_CLASSIFIER_ENDPOINT=http://127.0.0.1:$PORT" "FLEET_CLASSIFIER_SHA256=not-a-sha"
pv "$PVFIX"; (( RC >= 4 )) && ok "missing model checksum is a fault (exit $RC)" || bad "ran without a model checksum (exit $RC)"
fleetconf "FLEET_CLASSIFIER_ENDPOINT=http://127.0.0.1:$PORT"
OUT="$(container=docker bash "$EVC" --parallel-verify --fleet-config "$FCONF" "$PVFIX" 2>&1)"; RC=$?
(( RC >= 4 )) && [[ "$OUT" == *"run on the hub"* ]] && ok "parallel-verify refuses in a container" \
    || bad "parallel-verify ran in a container (exit $RC)"

echo
echo "classifier ($LEG): $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
