#!/usr/bin/env bash
# test-remote-thread-guard.sh — verify remote-thread-approval-guard.sh
#
# Runs the hook with crafted tool-call JSON and asserts the verdict.
# No live Claude session needed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$PROJECT_DIR/.claude/hooks/remote-thread-approval-guard.sh"
FLAG_FILE="$PROJECT_DIR/.claude/.remote-approval-required"
TMPINPUT="$(mktemp)"
trap 'rm -f "$TMPINPUT"' EXIT

pass=0
fail=0

run_test() {
    local label="$1" input="$2" expect="$3"
    printf '%s' "$input" > "$TMPINPUT"
    local out
    out="$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" timeout 5 bash "$HOOK" < "$TMPINPUT" 2>/dev/null)" || true
    if [[ "$expect" == "deny" ]]; then
        if printf '%s' "$out" | grep -q '"permissionDecision":"deny"'; then
            echo "  PASS: $label"
            pass=$((pass + 1))
        else
            echo "  FAIL: $label — expected deny, got: ${out:-(empty)}"
            fail=$((fail + 1))
        fi
    else
        if [[ -z "$out" ]]; then
            echo "  PASS: $label"
            pass=$((pass + 1))
        else
            echo "  FAIL: $label — expected allow, got: $out"
            fail=$((fail + 1))
        fi
    fi
}

echo "=== Remote thread approval guard tests ==="
echo ""

# --- Flag file active ---
echo "--- With flag file active ---"
touch "$FLAG_FILE"

run_test "t3_thread_launch without runtimeMode" \
    '{"tool_name":"mcp__t3-code__t3_thread_launch","tool_input":{"title":"test"}}' \
    "deny"

run_test "t3_thread_launch with full-access" \
    '{"tool_name":"mcp__t3-code__t3_thread_launch","tool_input":{"title":"test","runtimeMode":"full-access"}}' \
    "deny"

run_test "t3_thread_launch with auto" \
    '{"tool_name":"mcp__t3-code__t3_thread_launch","tool_input":{"title":"test","runtimeMode":"auto"}}' \
    "deny"

run_test "t3_thread_launch with auto-accept-edits" \
    '{"tool_name":"mcp__t3-code__t3_thread_launch","tool_input":{"title":"test","runtimeMode":"auto-accept-edits"}}' \
    "deny"

run_test "t3_thread_launch with approval-required" \
    '{"tool_name":"mcp__t3-code__t3_thread_launch","tool_input":{"title":"test","runtimeMode":"approval-required"}}' \
    "allow"

run_test "delegate_task without runtimeMode" \
    '{"tool_name":"mcp__t3-code__delegate_task","tool_input":{"task":"do work"}}' \
    "deny"

run_test "delegate_task with full-access" \
    '{"tool_name":"mcp__t3-code__delegate_task","tool_input":{"task":"do work","runtimeMode":"full-access"}}' \
    "deny"

run_test "delegate_task with approval-required" \
    '{"tool_name":"mcp__t3-code__delegate_task","tool_input":{"task":"do work","runtimeMode":"approval-required"}}' \
    "allow"

run_test "create_threads with mixed modes" \
    '{"tool_name":"mcp__t3-code__create_threads","tool_input":{"threads":[{"title":"a","runtimeMode":"full-access"},{"title":"b","runtimeMode":"approval-required"}]}}' \
    "deny"

run_test "create_threads all approval-required" \
    '{"tool_name":"mcp__t3-code__create_threads","tool_input":{"threads":[{"title":"a","runtimeMode":"approval-required"},{"title":"b","runtimeMode":"approval-required"}]}}' \
    "allow"

run_test "non-gated tool (Bash)" \
    '{"tool_name":"Bash","tool_input":{"command":"ls"}}' \
    "allow"

run_test "non-gated tool (Read)" \
    '{"tool_name":"Read","tool_input":{"file_path":"README.md"}}' \
    "allow"

echo ""

# --- Flag file removed ---
echo "--- Without flag file (no remote signals, attended session) ---"
rm -f "$FLAG_FILE"

run_test "t3_thread_launch without flag (local attended)" \
    '{"tool_name":"mcp__t3-code__t3_thread_launch","tool_input":{"title":"test","runtimeMode":"full-access"}}' \
    "allow"

run_test "delegate_task without flag (local attended)" \
    '{"tool_name":"mcp__t3-code__delegate_task","tool_input":{"task":"do work","runtimeMode":"auto"}}' \
    "allow"

echo ""

# --- Cross-environment signal (environmentId present) ---
echo "--- Cross-environment (environmentId present, no flag file) ---"

run_test "delegate_task with environmentId in target" \
    '{"tool_name":"mcp__t3-code__delegate_task","tool_input":{"task":"do work","target":{"environmentId":"abc-123"}}}' \
    "deny"

run_test "t3_thread_launch with environmentId" \
    '{"tool_name":"mcp__t3-code__t3_thread_launch","tool_input":{"title":"test","environmentId":"abc-123"}}' \
    "deny"

run_test "delegate_task with environmentId AND approval-required" \
    '{"tool_name":"mcp__t3-code__delegate_task","tool_input":{"task":"do work","runtimeMode":"approval-required","target":{"environmentId":"abc-123"}}}' \
    "allow"

run_test "t3_thread_launch with environmentId AND approval-required" \
    '{"tool_name":"mcp__t3-code__t3_thread_launch","tool_input":{"title":"test","runtimeMode":"approval-required","environmentId":"abc-123"}}' \
    "allow"

echo ""

# Restore flag file for production use
touch "$FLAG_FILE"

echo "=== Results: $pass passed, $fail failed ==="
[[ "$fail" -eq 0 ]] && exit 0 || exit 1
