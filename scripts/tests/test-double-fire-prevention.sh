#!/usr/bin/env bash
# test-double-fire-prevention.sh — verify user-level hooks exit early
# when project-level equivalent exists (double-fire prevention).
set -euo pipefail
PASS=0; FAIL=0
ok()   { echo "  PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEPLOY_HOOKS="$REPO_DIR/scripts/deploy/hooks"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "=== Double-fire prevention tests ==="

# Simulate: project-level hooks exist at CLAUDE_PROJECT_DIR
mkdir -p "$TMP/project/.claude/hooks"
for hook in master-dispatch-guard.sh pretooluse-ctp.sh tuoni-secret-guard.sh; do
    touch "$TMP/project/.claude/hooks/$hook"
    chmod +x "$TMP/project/.claude/hooks/$hook"
done

# Test: each user-level hook should detect project-level and exit early (no output)
_test_double_fire() {
    local hook_name="$1"
    local hook_path="$DEPLOY_HOOKS/$hook_name"
    [[ -f "$hook_path" ]] || { fail "$hook_name not found at $DEPLOY_HOOKS/"; return; }

    result="$(CLAUDE_PROJECT_DIR="$TMP/project" \
        bash -c "echo '{\"tool_name\":\"Agent\",\"tool_input\":{\"subagent_type\":\"general\"}}' | bash '$hook_path'" 2>/dev/null)" || true
    if [[ -z "$result" ]]; then
        ok "$hook_name exits early when project-level exists (no output)"
    else
        fail "$hook_name produces output despite project-level existing: $result"
    fi
}

for hook in master-dispatch-guard.sh pretooluse-ctp.sh tuoni-secret-guard.sh; do
    _test_double_fire "$hook"
done

# Test: hooks should NOT exit early when no project-level exists
_test_fires_without_project() {
    local hook_name="$1"
    local hook_path="$DEPLOY_HOOKS/$hook_name"
    [[ -f "$hook_path" ]] || { fail "$hook_name not found"; return; }

    # With no CLAUDE_PROJECT_DIR, hook should run its logic (not just exit)
    exit_code=0
    env -u CLAUDE_PROJECT_DIR bash -c "echo '{}' | bash '$hook_path' 2>/dev/null; exit \$?" || exit_code=$?
    if [[ "$exit_code" == "0" || "$exit_code" == "2" ]]; then
        ok "$hook_name runs logic when no project-level exists (exit $exit_code)"
    else
        fail "$hook_name crashes without project-level: exit $exit_code"
    fi
}

for hook in master-dispatch-guard.sh pretooluse-ctp.sh tuoni-secret-guard.sh; do
    _test_fires_without_project "$hook"
done

# Test: hooks don't contain hardcoded paths
_test_no_hardcoded_paths() {
    local hook_path="$1"
    if grep -q '/home/chris\|/Users/' "$hook_path" 2>/dev/null; then
        fail "$(basename "$hook_path") contains hardcoded user paths"
    else
        ok "$(basename "$hook_path") has no hardcoded paths"
    fi
}

for hook in "$DEPLOY_HOOKS"/*.sh; do
    [[ -f "$hook" ]] && _test_no_hardcoded_paths "$hook"
done

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
