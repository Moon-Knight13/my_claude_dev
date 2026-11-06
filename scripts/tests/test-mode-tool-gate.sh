#!/usr/bin/env bash
# test-mode-tool-gate.sh — verify mode-tool-gate.sh hook enforcement
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$PROJECT_DIR/.claude/hooks/mode-tool-gate.sh"

PASS=0; FAIL=0

ok()   { echo "  PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

# Ensure hook exists and is executable
[[ -x "$HOOK" ]] || { echo "FAIL: hook not executable"; exit 1; }

# Helper: simulate a PreToolUse hook call
_call_hook() {
    local mode="$1" tool_name="$2"
    local mode_file="$PROJECT_DIR/.claude/.active-mode"

    # Set mode
    echo "$mode" > "$mode_file"

    # Simulate hook input
    local result
    result="$(printf '{"tool_name":"%s","tool_input":{}}' "$tool_name" | \
        CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$HOOK" 2>/dev/null)" || true
    echo "$result"
}

_is_denied() {
    echo "$1" | grep -q '"permissionDecision":"deny"'
}

_is_allowed() {
    # No output = no opinion = allowed
    [[ -z "$1" ]] || ! echo "$1" | grep -q '"permissionDecision":"deny"'
}

# Save and restore .active-mode
ORIG_MODE=""
[[ -f "$PROJECT_DIR/.claude/.active-mode" ]] && ORIG_MODE="$(cat "$PROJECT_DIR/.claude/.active-mode")"
trap '
    if [[ -n "$ORIG_MODE" ]]; then
        echo "$ORIG_MODE" > "$PROJECT_DIR/.claude/.active-mode"
    else
        rm -f "$PROJECT_DIR/.claude/.active-mode"
    fi
' EXIT

echo "=== Mode Tool Gate Tests ==="
echo ""

echo "--- platform-ops mode denies offensive MCPs ---"
result="$(_call_hook platform-ops mcp__tuoni-mcp__tuoni_send_command)"
if _is_denied "$result"; then
    ok "platform-ops denies mcp__tuoni-mcp__tuoni_send_command"
else
    fail "platform-ops should deny mcp__tuoni-mcp__tuoni_send_command"
fi

result="$(_call_hook platform-ops mcp__hacktricks-mcp__search)"
if _is_denied "$result"; then
    ok "platform-ops denies mcp__hacktricks-mcp__search"
else
    fail "platform-ops should deny mcp__hacktricks-mcp__search"
fi

result="$(_call_hook platform-ops mcp__range-intel__query_hosts)"
if _is_denied "$result"; then
    ok "platform-ops denies mcp__range-intel__query_hosts"
else
    fail "platform-ops should deny mcp__range-intel__query_hosts"
fi

echo ""
echo "--- platform-ops allows non-MCP tools ---"
result="$(_call_hook platform-ops Bash)"
if _is_allowed "$result"; then
    ok "platform-ops allows Bash (non-MCP)"
else
    fail "platform-ops should allow Bash"
fi

result="$(_call_hook platform-ops Read)"
if _is_allowed "$result"; then
    ok "platform-ops allows Read (non-MCP)"
else
    fail "platform-ops should allow Read"
fi

echo ""
echo "--- red-team mode allows offensive MCPs ---"
result="$(_call_hook red-team mcp__tuoni-mcp__tuoni_send_command)"
if _is_allowed "$result"; then
    ok "red-team allows mcp__tuoni-mcp__tuoni_send_command"
else
    fail "red-team should allow mcp__tuoni-mcp__tuoni_send_command"
fi

result="$(_call_hook red-team mcp__hacktricks-mcp__search)"
if _is_allowed "$result"; then
    ok "red-team allows mcp__hacktricks-mcp__search"
else
    fail "red-team should allow mcp__hacktricks-mcp__search"
fi

result="$(_call_hook red-team mcp__range-intel__query_hosts)"
if _is_allowed "$result"; then
    ok "red-team allows mcp__range-intel__query_hosts"
else
    fail "red-team should allow mcp__range-intel__query_hosts"
fi

echo ""
echo "--- red-team denies local-ollama ---"
result="$(_call_hook red-team mcp__local-ollama__chat)"
if _is_denied "$result"; then
    ok "red-team denies mcp__local-ollama__chat"
else
    fail "red-team should deny mcp__local-ollama__chat"
fi

echo ""
echo "--- green-dev denies offensive MCPs ---"
result="$(_call_hook green-dev mcp__tuoni-mcp__tuoni_send_command)"
if _is_denied "$result"; then
    ok "green-dev denies mcp__tuoni-mcp__tuoni_send_command"
else
    fail "green-dev should deny mcp__tuoni-mcp__tuoni_send_command"
fi

result="$(_call_hook green-dev mcp__hacktricks-mcp__search)"
if _is_denied "$result"; then
    ok "green-dev denies mcp__hacktricks-mcp__search"
else
    fail "green-dev should deny mcp__hacktricks-mcp__search"
fi

echo ""
echo "--- green-dev allows range-intel ---"
result="$(_call_hook green-dev mcp__range-intel__query_hosts)"
if _is_allowed "$result"; then
    ok "green-dev allows mcp__range-intel__query_hosts"
else
    fail "green-dev should allow mcp__range-intel__query_hosts"
fi

echo ""
echo "--- no active mode = no enforcement ---"
rm -f "$PROJECT_DIR/.claude/.active-mode"
result="$(printf '{"tool_name":"mcp__tuoni-mcp__tuoni_send_command","tool_input":{}}' | \
    CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$HOOK" 2>/dev/null || true)"
if _is_allowed "$result"; then
    ok "no active mode allows all tools"
else
    fail "no active mode should allow all tools"
fi

echo ""
echo "--- deny message includes mode name ---"
result="$(_call_hook platform-ops mcp__tuoni-mcp__tuoni_send_command)"
if echo "$result" | grep -q "platform-ops"; then
    ok "deny message includes mode name"
else
    fail "deny message should include mode name"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
