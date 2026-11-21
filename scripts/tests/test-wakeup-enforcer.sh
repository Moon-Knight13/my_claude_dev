#!/usr/bin/env bash
# test-wakeup-enforcer.sh — verify dispatch-wakeup-enforcer PostToolUse hook.
set -euo pipefail
PASS=0; FAIL=0
ok()   { echo "  PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_DIR/scripts/deploy/hooks/dispatch-wakeup-enforcer.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "=== Dispatch-wakeup-enforcer tests ==="

[[ -f "$HOOK" ]] || { echo "FAIL: hook not found at $HOOK"; exit 1; }

# Test 1: fires after delegate_task when mode active
mkdir -p "$TMP/.claude"
echo "base" > "$TMP/.claude/.active-mode"
result="$(HOME="$TMP" CLAUDE_PROJECT_DIR="" CLAUDE_CODE_SESSION_ID="" \
    bash -c "printf '{\"tool_name\":\"mcp__t3-code__delegate_task\",\"tool_input\":{}}' | bash '$HOOK'" 2>/dev/null)" || true
if echo "$result" | grep -qi "ScheduleWakeup\|schedule"; then
    ok "nudge after delegate_task"
else
    fail "no nudge after delegate_task: $result"
fi

# Test 2: fires after t3_thread_launch
result="$(HOME="$TMP" CLAUDE_PROJECT_DIR="" CLAUDE_CODE_SESSION_ID="" \
    bash -c "printf '{\"tool_name\":\"mcp__t3-code__t3_thread_launch\",\"tool_input\":{}}' | bash '$HOOK'" 2>/dev/null)" || true
if echo "$result" | grep -qi "ScheduleWakeup\|schedule"; then
    ok "nudge after t3_thread_launch"
else
    fail "no nudge after t3_thread_launch: $result"
fi

# Test 3: fires after create_threads
result="$(HOME="$TMP" CLAUDE_PROJECT_DIR="" CLAUDE_CODE_SESSION_ID="" \
    bash -c "printf '{\"tool_name\":\"mcp__t3-code__create_threads\",\"tool_input\":{}}' | bash '$HOOK'" 2>/dev/null)" || true
if echo "$result" | grep -qi "ScheduleWakeup\|schedule"; then
    ok "nudge after create_threads"
else
    fail "no nudge after create_threads: $result"
fi

# Test 4: silent for non-dispatch tools
result="$(HOME="$TMP" CLAUDE_PROJECT_DIR="" CLAUDE_CODE_SESSION_ID="" \
    bash -c "printf '{\"tool_name\":\"Bash\",\"tool_input\":{}}' | bash '$HOOK'" 2>/dev/null)" || true
if [[ -z "$result" ]]; then
    ok "silent for non-dispatch tool"
else
    fail "fires for Bash: $result"
fi

# Test 5: silent in child thread (has mode override)
mkdir -p "$TMP/.claude/.mode-overrides"
echo "red-team" > "$TMP/.claude/.mode-overrides/test-session-123"
result="$(HOME="$TMP" CLAUDE_PROJECT_DIR="" CLAUDE_CODE_SESSION_ID="test-session-123" \
    bash -c "printf '{\"tool_name\":\"mcp__t3-code__delegate_task\",\"tool_input\":{}}' | bash '$HOOK'" 2>/dev/null)" || true
if [[ -z "$result" ]]; then
    ok "silent in child thread"
else
    fail "fires in child thread: $result"
fi

# Test 6: double-fire prevention
mkdir -p "$TMP/project/.claude/hooks"
touch "$TMP/project/.claude/hooks/dispatch-wakeup-enforcer.sh"
chmod +x "$TMP/project/.claude/hooks/dispatch-wakeup-enforcer.sh"
result="$(HOME="$TMP" CLAUDE_PROJECT_DIR="$TMP/project" CLAUDE_CODE_SESSION_ID="" \
    bash -c "printf '{\"tool_name\":\"mcp__t3-code__delegate_task\",\"tool_input\":{}}' | bash '$HOOK'" 2>/dev/null)" || true
if [[ -z "$result" ]]; then
    ok "exits early when project-level exists"
else
    fail "fires despite project-level existing: $result"
fi

# Test 7: no hardcoded paths
if grep -q '/home/chris\|/Users/' "$HOOK" 2>/dev/null; then
    fail "contains hardcoded user paths"
else
    ok "no hardcoded paths"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
