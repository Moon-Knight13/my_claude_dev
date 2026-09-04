#!/usr/bin/env bash
# test-sanitiser.sh — deterministic contract tests for sanitise.sh. The rewrite
# QUALITY is measured live by eval-sanitiser.sh; here we mock the model and prove
# the contract: transform-or-fail, never-egress, fail cleanly with no stdout.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok()   { echo "  OK  $1"; ((PASS++)) || true; }
bad()  { echo " FAIL $1"; ((FAIL++)) || true; }
check(){ if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }

SAN="$ROOT/scripts/orchestrator/sanitise.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
MOCKBIN="$TMP/bin"; mkdir -p "$MOCKBIN"
cat > "$MOCKBIN/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CURL_LOG"
[[ "${MOCK_FAIL:-0}" == 1 ]] && exit 22
jq -n --arg r "${MOCK_RESP:-}" '{response:$r}'
EOF
chmod +x "$MOCKBIN/curl"
export CURL_LOG="$TMP/curl.log"

# run <stdin-prompt> — sanitise with the mock and a LOCAL endpoint; prints stdout,
# and we capture the exit code separately via run_rc.
run()    { : > "$CURL_LOG"; printf '%s' "$1" | PATH="$MOCKBIN:$PATH" ORCH_SANITISER_ENDPOINT="http://127.0.0.1:11434" ORCH_SANITISER_PROMPT_FILE="$TMP/none.md" bash "$SAN"; }
run_rc() { : > "$CURL_LOG"; printf '%s' "$1" | PATH="$MOCKBIN:$PATH" ORCH_SANITISER_ENDPOINT="${2:-http://127.0.0.1:11434}" ORCH_SANITISER_PROMPT_FILE="$TMP/none.md" bash "$SAN" >/dev/null 2>&1; echo "$?"; }

echo "== transform =="
check "returns rewritten text"        "$(MOCK_RESP='Refactor function for PERSON_1.' run 'refactor for Jane')" 'Refactor function for PERSON_1.'
check "success exit 0"                "$(MOCK_RESP='clean task' run_rc 'x')" 0
# a qwen3 thinking remnant is stripped from the rewrite
check "think remnant stripped"       "$(MOCK_RESP=$'<think>de-identify this</think>\nRewritten task for HOST_1' run 'x')" 'Rewritten task for HOST_1'
# a lone closing </think> with stray reasoning text before it must be dropped
check "lone </think> + junk dropped"  "$(MOCK_RESP=$'张伟\n \\boxed{}\n</think>\n\nRewritten for PERSON_1' run 'x')" 'Rewritten for PERSON_1'

echo "== fail cleanly (no stdout, non-zero) =="
check "empty stdin -> exit 1"        "$(run_rc '')" 1
check "model failure -> non-zero"    "$(MOCK_FAIL=1 run_rc 'x')" 3
check "empty rewrite -> exit 4"      "$(MOCK_RESP='' run_rc 'x')" 4
check "whitespace rewrite -> exit 4" "$(MOCK_RESP='   ' run_rc 'x')" 4
check "model failure emits no stdout" "$(MOCK_FAIL=1 run 'x')" ''

echo "== never egresses =="
check "non-local endpoint -> exit 2" "$(run_rc 'x' 'https://api.anthropic.com')" 2
# and it made no call
: > "$CURL_LOG"; printf 'x' | PATH="$MOCKBIN:$PATH" ORCH_SANITISER_ENDPOINT="https://api.anthropic.com" ORCH_SANITISER_PROMPT_FILE="$TMP/none.md" bash "$SAN" >/dev/null 2>&1
check "non-local endpoint makes no call" "$([[ -s "$CURL_LOG" ]] && echo called || echo none)" none
# a local endpoint IS used
: > "$CURL_LOG"; MOCK_RESP='ok' printf 'x' >/dev/null; MOCK_RESP='ok' PATH="$MOCKBIN:$PATH" ORCH_SANITISER_ENDPOINT="http://127.0.0.1:11434" ORCH_SANITISER_PROMPT_FILE="$TMP/none.md" bash "$SAN" <<<'x' >/dev/null
check "local endpoint is used" "$(grep -c '127.0.0.1:11434/api/generate' "$CURL_LOG")" 1

echo
echo "sanitiser: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
