#!/usr/bin/env bash
# test-dispatch-guard.sh — verify dispatch-validation-guard.sh
#
# Runs the hook with crafted tool-call JSON and asserts verdict + warnings.
# No live Claude session needed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$PROJECT_DIR/scripts/hooks/dispatch-validation-guard.sh"
MODE_FILE="$PROJECT_DIR/.claude/.active-mode"
OVERRIDE_DIR="$PROJECT_DIR/.claude/.mode-overrides"
TMPINPUT="$(mktemp)"
TMPERR="$(mktemp)"
FAKE_SESSION="test-dispatch-guard-$$"
PENDING_FILE="/tmp/claude-dispatch-pending-$FAKE_SESSION"
trap 'rm -f "$TMPINPUT" "$TMPERR" "$PENDING_FILE"; rm -f "$OVERRIDE_DIR/$FAKE_SESSION"' EXIT

pass=0
fail=0

# run_test LABEL INPUT EXPECT [EXPECT_WARN] [SESSION_ID]
#   EXPECT: "deny" or "allow"
#   EXPECT_WARN: substring to find in stderr, "NOWARN" for empty stderr, "" to skip check
run_test() {
    local label="$1" input="$2" expect="$3" expect_warn="${4:-}" session_id="${5:-$FAKE_SESSION}"
    printf '%s' "$input" > "$TMPINPUT"
    local out
    out="$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" CLAUDE_CODE_SESSION_ID="$session_id" \
        timeout 5 bash "$HOOK" < "$TMPINPUT" 2>"$TMPERR")" || true
    local err
    err="$(cat "$TMPERR" 2>/dev/null || true)"

    local ok=true

    if [[ "$expect" == "deny" ]]; then
        if ! printf '%s' "$out" | grep -q '"permissionDecision":"deny"'; then
            echo "  FAIL: $label — expected deny, got: ${out:-(empty)}"
            ok=false
        fi
    else
        if printf '%s' "$out" | grep -q '"permissionDecision":"deny"'; then
            echo "  FAIL: $label — expected allow, got deny"
            ok=false
        fi
    fi

    if [[ "$expect_warn" == "NOWARN" ]]; then
        if [[ -n "$err" ]]; then
            echo "  FAIL: $label — expected no warning, got: $err"
            ok=false
        fi
    elif [[ -n "$expect_warn" ]]; then
        if ! printf '%s' "$err" | grep -qF "$expect_warn"; then
            echo "  FAIL: $label — expected warning '$expect_warn', stderr: ${err:-(empty)}"
            ok=false
        fi
    fi

    if [[ "$ok" == "true" ]]; then
        echo "  PASS: $label"
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
    fi
}

echo "=== Dispatch validation guard tests ==="
echo ""

# Ensure mode is active for gated tests
echo "platform-ops" > "$MODE_FILE"
rm -f "$PENDING_FILE"

# --- Rule 1: delegate_task blocking ---
echo "--- Rule 1: delegate_task from master ---"

run_test "delegate_task from master = denied" \
    '{"tool_name":"mcp__t3-code__delegate_task","tool_input":{"task":"do work"}}' \
    "deny"

# Child thread bypass
mkdir -p "$OVERRIDE_DIR"
echo "red-team" > "$OVERRIDE_DIR/$FAKE_SESSION"
run_test "delegate_task from child thread = allowed" \
    '{"tool_name":"mcp__t3-code__delegate_task","tool_input":{"task":"do work"}}' \
    "allow"
rm -f "$OVERRIDE_DIR/$FAKE_SESSION"

echo ""

# --- Rule 2: workspace strategy warnings ---
echo "--- Rule 2: workspace strategy ---"
rm -f "$PENDING_FILE"

run_test "t3_thread_launch = allowed (always)" \
    '{"tool_name":"mcp__t3-code__t3_thread_launch","tool_input":{"message":"do work"}}' \
    "allow"

rm -f "$PENDING_FILE"
run_test "research + worktree = warning" \
    '{"tool_name":"mcp__t3-code__t3_thread_launch","tool_input":{"message":"investigate the logs and check connectivity","workspaceStrategy":{"type":"worktree"}}}' \
    "allow" "Research task dispatched with worktree"

rm -f "$PENDING_FILE"
run_test "implementation + root = warning" \
    '{"tool_name":"mcp__t3-code__t3_thread_launch","tool_input":{"message":"implement the new feature and build the component","workspaceStrategy":{"type":"root"}}}' \
    "allow" "Implementation task dispatched without worktree"

rm -f "$PENDING_FILE"
run_test "research + root = correct, no warning" \
    '{"tool_name":"mcp__t3-code__t3_thread_launch","tool_input":{"message":"research the vulnerability and investigate CVE","workspaceStrategy":{"type":"root"}}}' \
    "allow" "NOWARN"

rm -f "$PENDING_FILE"
run_test "implementation + worktree = correct, no warning" \
    '{"tool_name":"mcp__t3-code__t3_thread_launch","tool_input":{"message":"implement the fix and build tests","workspaceStrategy":{"type":"worktree"}}}' \
    "allow" "NOWARN"

echo ""

# --- Rule 3: ScheduleWakeup reminder ---
echo "--- Rule 3: ScheduleWakeup tracking ---"
rm -f "$PENDING_FILE"

# Dispatch to set pending marker
printf '{"tool_name":"mcp__t3-code__t3_thread_launch","tool_input":{"message":"do work"}}' | \
    CLAUDE_PROJECT_DIR="$PROJECT_DIR" CLAUDE_CODE_SESSION_ID="$FAKE_SESSION" \
    timeout 5 bash "$HOOK" >/dev/null 2>/dev/null || true

if [[ -f "$PENDING_FILE" ]]; then
    echo "  PASS: pending marker created after dispatch"
    pass=$((pass + 1))
else
    echo "  FAIL: pending marker not created after dispatch"
    fail=$((fail + 1))
fi

run_test "Bash after dispatch = ScheduleWakeup warning" \
    '{"tool_name":"Bash","tool_input":{"command":"ls"}}' \
    "allow" "ScheduleWakeup required after thread dispatch"

# ScheduleWakeup clears marker
run_test "ScheduleWakeup after dispatch = allowed, no warning" \
    '{"tool_name":"ScheduleWakeup","tool_input":{"delaySeconds":300}}' \
    "allow" "NOWARN"

if [[ ! -f "$PENDING_FILE" ]]; then
    echo "  PASS: pending marker cleared after ScheduleWakeup"
    pass=$((pass + 1))
else
    echo "  FAIL: pending marker still exists after ScheduleWakeup"
    fail=$((fail + 1))
fi

# Meta tools should not trigger Rule 3 warning
rm -f "$PENDING_FILE"
printf '{"tool_name":"mcp__t3-code__t3_thread_launch","tool_input":{"message":"do work"}}' | \
    CLAUDE_PROJECT_DIR="$PROJECT_DIR" CLAUDE_CODE_SESSION_ID="$FAKE_SESSION" \
    timeout 5 bash "$HOOK" >/dev/null 2>/dev/null || true

run_test "ToolSearch after dispatch = no warning (meta tool)" \
    '{"tool_name":"ToolSearch","tool_input":{"query":"select:ScheduleWakeup"}}' \
    "allow" "NOWARN"
rm -f "$PENDING_FILE"

echo ""

# --- No mode = gate inactive ---
echo "--- No mode = gate off ---"
rm -f "$MODE_FILE" "$PENDING_FILE"

run_test "delegate_task without mode = allowed" \
    '{"tool_name":"mcp__t3-code__delegate_task","tool_input":{"task":"do work"}}' \
    "allow"

echo ""

# Restore mode file
echo "platform-ops" > "$MODE_FILE"

echo "=== Results: $pass passed, $fail failed ==="
[[ "$fail" -eq 0 ]] && exit 0 || exit 1
