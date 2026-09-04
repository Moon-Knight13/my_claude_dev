#!/usr/bin/env bash
# test-classifier.sh — deterministic contract tests for classify-sensitivity.sh.
# The live-model behaviour is measured by eval-classifier.sh; here we mock the
# model call and prove the parts that MUST hold regardless of the model:
#   1. strict parse (only a clean "nonsensitive" unlocks the cloud tier)
#   2. fail-closed on every error/garbled/empty case
#   3. never egresses (a non-local endpoint is refused without a call)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok()   { echo "  OK  $1"; ((PASS++)) || true; }
bad()  { echo " FAIL $1"; ((FAIL++)) || true; }
check(){ if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }

CLS="$ROOT/scripts/orchestrator/classify-sensitivity.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Mock curl on PATH: logs its args, then either fails (MOCK_FAIL=1) or prints an
# Ollama-shaped JSON with .response = MOCK_RESP. jq stays the real one.
MOCKBIN="$TMP/bin"; mkdir -p "$MOCKBIN"
cat > "$MOCKBIN/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CURL_LOG"
[[ "${MOCK_FAIL:-0}" == 1 ]] && exit 22
jq -n --arg r "${MOCK_RESP:-}" '{response:$r}'
EOF
chmod +x "$MOCKBIN/curl"
# Exported so the mock curl (a subprocess) can see it and log its args.
export CURL_LOG="$TMP/curl.log"

# run <prompt> — invoke the classifier with the mock, a LOCAL endpoint, and a
# fresh curl log. Reads MOCK_RESP/MOCK_FAIL from the environment.
run() {
    : > "$CURL_LOG"
    PATH="$MOCKBIN:$PATH" \
    ORCH_CLASSIFIER_ENDPOINT="http://127.0.0.1:11434" \
    ORCH_CLASSIFIER_TIMEOUT=5 \
    ORCH_CLASSIFIER_PROMPT_FILE="$TMP/nope-prompt.md" \
    bash "$CLS" "$1"
}

echo "== strict parse =="
check "clean nonsensitive -> nonsensitive" "$(MOCK_RESP='nonsensitive' run 'refactor foo')" nonsensitive
check "clean sensitive -> sensitive"       "$(MOCK_RESP='sensitive'    run 'refactor foo')" sensitive
check "uppercase honoured"                 "$(MOCK_RESP='NONSENSITIVE' run 'x')"            nonsensitive
check "trailing punctuation honoured"      "$(MOCK_RESP='nonsensitive.' run 'x')"           nonsensitive
# qwen3 thinking block must be stripped before the verdict is read
check "think block stripped (nonsens)"     "$(MOCK_RESP='<think>the task is a generic refactor</think>nonsensitive' run 'x')" nonsensitive
check "think block stripped (sens)"        "$(MOCK_RESP='<think>has an email</think>sensitive' run 'x')" sensitive

echo "== fail closed =="
check "verbose answer -> sensitive"        "$(MOCK_RESP='Sure, this is nonsensitive!' run 'x')" sensitive
check "empty response -> sensitive"        "$(MOCK_RESP='' run 'x')"                        sensitive
check "garbage token -> sensitive"         "$(MOCK_RESP='banana' run 'x')"                  sensitive
check "negation not mis-read -> sensitive" "$(MOCK_RESP='this is not nonsensitive' run 'x')" sensitive
check "curl failure/timeout -> sensitive"  "$(MOCK_FAIL=1 run 'x')"                         sensitive
check "empty prompt -> sensitive"          "$(MOCK_RESP='nonsensitive' run '')"             sensitive

echo "== never egresses =="
# empty prompt must short-circuit BEFORE any model call
: > "$CURL_LOG"
MOCK_RESP='nonsensitive' PATH="$MOCKBIN:$PATH" ORCH_CLASSIFIER_ENDPOINT="http://127.0.0.1:11434" bash "$CLS" "" >/dev/null
check "empty prompt makes no model call" "$([[ -s "$CURL_LOG" ]] && echo called || echo none)" none
# a non-local endpoint is refused (sensitive) WITHOUT calling out
: > "$CURL_LOG"
v="$(MOCK_RESP='nonsensitive' PATH="$MOCKBIN:$PATH" ORCH_CLASSIFIER_ENDPOINT="https://api.anthropic.com" bash "$CLS" 'benign prompt')"
check "cloud endpoint refused -> sensitive" "$v" sensitive
check "cloud endpoint makes no call"        "$([[ -s "$CURL_LOG" ]] && echo called || echo none)" none
# a local endpoint DOES get called, and the classifier hit that local URL
: > "$CURL_LOG"
MOCK_RESP='nonsensitive' PATH="$MOCKBIN:$PATH" ORCH_CLASSIFIER_ENDPOINT="http://127.0.0.1:11434" bash "$CLS" 'benign prompt' >/dev/null
check "local endpoint is used" "$(grep -c '127.0.0.1:11434/api/generate' "$CURL_LOG")" 1

echo
echo "classifier: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
