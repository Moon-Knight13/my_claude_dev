#!/usr/bin/env bash
# test-user-level-hooks.sh — verify which env vars user-level hooks receive
# Part of HQ Phase 0: establishes baseline for user-level hook deployment.
set -euo pipefail
PASS=0; FAIL=0
ok()   { echo "  PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

_run_without_project_dir() {
    local hook="$1"
    env -u CLAUDE_PROJECT_DIR bash -c "echo '{}' | bash '$hook' 2>/dev/null; echo EXIT:\$?"
}

echo "=== User-level hook environment tests ==="

# Test: hooks must not crash without CLAUDE_PROJECT_DIR
for hook in master-dispatch-guard.sh pretooluse-ctp.sh tuoni-secret-guard.sh; do
    HOOK_PATH="$PROJECT_DIR/.claude/hooks/$hook"
    [[ -f "$HOOK_PATH" ]] || { fail "$hook not found"; continue; }
    result="$(_run_without_project_dir "$HOOK_PATH")"
    if echo "$result" | grep -q "EXIT:0\|EXIT:2"; then
        ok "$hook survives without CLAUDE_PROJECT_DIR"
    else
        fail "$hook crashes without CLAUDE_PROJECT_DIR: $result"
    fi
done

# Test: pretooluse-ctp.sh resolves guard-stack at user level
_test_ctp_guardstack_resolution() {
    local hook="$PROJECT_DIR/.claude/hooks/pretooluse-ctp.sh"
    [[ -f "$hook" ]] || { fail "pretooluse-ctp.sh not found"; return; }
    result="$(env -u CLAUDE_PROJECT_DIR bash -c "echo '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls\"}}' | bash '$hook' 2>&1; echo EXIT:\$?")"
    exit_code="$(echo "$result" | grep -o 'EXIT:[0-9]*' | cut -d: -f2)"
    if [[ "$exit_code" == "0" || "$exit_code" == "2" ]]; then
        ok "pretooluse-ctp.sh guard-stack resolves or degrades gracefully"
    else
        fail "pretooluse-ctp.sh crashes on guard-stack resolution: exit $exit_code"
    fi
}
_test_ctp_guardstack_resolution

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
