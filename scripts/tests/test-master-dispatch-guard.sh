#!/usr/bin/env bash
# test-master-dispatch-guard.sh — verify master-dispatch-guard.sh
#
# Runs the hook with crafted tool-call JSON and asserts the verdict.
# No live Claude session needed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$PROJECT_DIR/.claude/hooks/master-dispatch-guard.sh"
MODE_FILE="$PROJECT_DIR/.claude/.active-mode"
OVERRIDE_DIR="$PROJECT_DIR/.claude/.mode-overrides"
TMPINPUT="$(mktemp)"
FAKE_SESSION="test-session-$$"
trap 'rm -f "$TMPINPUT"; rm -f "$OVERRIDE_DIR/$FAKE_SESSION"' EXIT

pass=0
fail=0

run_test() {
    local label="$1" input="$2" expect="$3" session_id="${4:-}"
    printf '%s' "$input" > "$TMPINPUT"
    local out
    out="$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" CLAUDE_CODE_SESSION_ID="$session_id" \
        timeout 5 bash "$HOOK" < "$TMPINPUT" 2>/dev/null)" || true
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

echo "=== Master dispatch guard tests ==="
echo ""

# --- Mode active (gate on) ---
echo "--- With active mode ---"
echo "platform-ops" > "$MODE_FILE"

run_test "Plain Agent call (no subagent_type) = deny" \
    '{"tool_name":"Agent","tool_input":{"prompt":"do work","description":"test"}}' \
    "deny"

run_test "Agent with subagent_type: claude = deny" \
    '{"tool_name":"Agent","tool_input":{"subagent_type":"claude","prompt":"do work","description":"test"}}' \
    "deny"

run_test "Agent with subagent_type: general-purpose = deny" \
    '{"tool_name":"Agent","tool_input":{"subagent_type":"general-purpose","prompt":"do work","description":"test"}}' \
    "deny"

run_test "Agent with subagent_type: Explore = deny" \
    '{"tool_name":"Agent","tool_input":{"subagent_type":"Explore","prompt":"find code","description":"search"}}' \
    "deny"

run_test "Agent with subagent_type: fork = allow" \
    '{"tool_name":"Agent","tool_input":{"subagent_type":"fork","prompt":"research this","description":"fork"}}' \
    "allow"

run_test "Agent with subagent_type: caveman:cavecrew-builder = allow" \
    '{"tool_name":"Agent","tool_input":{"subagent_type":"caveman:cavecrew-builder","prompt":"edit file","description":"build"}}' \
    "allow"

run_test "Agent with subagent_type: caveman:cavecrew-investigator = allow" \
    '{"tool_name":"Agent","tool_input":{"subagent_type":"caveman:cavecrew-investigator","prompt":"find code","description":"investigate"}}' \
    "allow"

run_test "Agent with subagent_type: caveman:cavecrew-reviewer = allow" \
    '{"tool_name":"Agent","tool_input":{"subagent_type":"caveman:cavecrew-reviewer","prompt":"review diff","description":"review"}}' \
    "allow"

run_test "Agent with subagent_type: caveman:cavecrew-unknown = allow" \
    '{"tool_name":"Agent","tool_input":{"subagent_type":"caveman:cavecrew-unknown","prompt":"work","description":"test"}}' \
    "allow"

run_test "Agent with empty subagent_type = deny" \
    '{"tool_name":"Agent","tool_input":{"subagent_type":"","prompt":"do work","description":"test"}}' \
    "deny"

echo ""

# --- No active mode (gate off) ---
echo "--- Without active mode ---"
rm -f "$MODE_FILE"

run_test "Plain Agent call without mode = allow" \
    '{"tool_name":"Agent","tool_input":{"prompt":"do work","description":"test"}}' \
    "allow"

run_test "Agent with subagent_type: claude without mode = allow" \
    '{"tool_name":"Agent","tool_input":{"subagent_type":"claude","prompt":"do work","description":"test"}}' \
    "allow"

echo ""

# --- Child thread (mode-override exists) ---
echo "--- Child thread (mode-override file) ---"
echo "platform-ops" > "$MODE_FILE"
mkdir -p "$OVERRIDE_DIR"
echo "red-team" > "$OVERRIDE_DIR/$FAKE_SESSION"

run_test "Plain Agent call from child thread = allow" \
    '{"tool_name":"Agent","tool_input":{"subagent_type":"claude","prompt":"do work","description":"test"}}' \
    "allow" "$FAKE_SESSION"

run_test "Agent with no subagent_type from child thread = allow" \
    '{"tool_name":"Agent","tool_input":{"prompt":"do work","description":"test"}}' \
    "allow" "$FAKE_SESSION"

rm -f "$OVERRIDE_DIR/$FAKE_SESSION"

echo ""

# Restore mode file for production use
echo "platform-ops" > "$MODE_FILE"

echo "=== Results: $pass passed, $fail failed ==="
[[ "$fail" -eq 0 ]] && exit 0 || exit 1
