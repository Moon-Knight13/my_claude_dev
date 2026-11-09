#!/usr/bin/env bash
# research-dispatch-guard.sh — PreToolUse hook: enforce thread dispatch for
# research work during engagements.
#
# When .claude/.research-gate-active exists, deny research MCP tool calls
# from the master session. Research belongs in T3 threads so master context
# stays clean and phase gates are respected.
#
# Gate activates: operator (or engagement-orchestration skill) touches
#   .claude/.research-gate-active — presence alone is the trigger.
# Gate deactivates: delete the flag file. No content is read from it.
#
# Bypass conditions (any one skips the gate):
#   - Flag file absent (no engagement, or operator override)
#   - Tool is not a research MCP (non-research tools always pass)
#   - Session has a mode-override file (T3 child threads get one)
#
# Exit protocol (same as mode-tool-gate.sh):
#   0 + deny JSON  = blocked
#   0 + no output  = no opinion (allow)
#   2              = block (error / fail-closed)
set -euo pipefail
trap 'exit 2' ERR

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
FLAG_FILE="$PROJECT_DIR/.claude/.research-gate-active"

# No flag = gate inactive, allow everything
[[ -f "$FLAG_FILE" ]] || exit 0

# T3 child threads have a per-session mode override — they ARE the dispatched
# research threads, so never block them.
OVERRIDE_DIR="$PROJECT_DIR/.claude/.mode-overrides"
SESSION_ID="${CLAUDE_CODE_SESSION_ID:-}"
if [[ -n "$SESSION_ID" && -f "$OVERRIDE_DIR/$SESSION_ID" ]]; then
    exit 0
fi

# Read tool name from stdin JSON
input="$(cat)"
tool_name="$(printf '%s' "$input" | python3 -I -c '
import sys, json
try:
    print(json.load(sys.stdin).get("tool_name", ""))
except Exception:
    print("")
' 2>/dev/null || true)"

# Only gate MCP tools — built-in tools (Bash/Read/Edit/Write) pass through
[[ "$tool_name" == mcp__* ]] || exit 0

# Research MCP prefixes — tools that fetch external threat intel, CVE data,
# or detailed target reconnaissance. Keep sorted for easy scanning.
RESEARCH_PREFIXES=(
    "mcp__ghidra-mcp__"
    "mcp__gtfobins-mcp__"
    "mcp__hacktricks-mcp__"
    "mcp__mitre-mcp__"
    "mcp__range-intel-mcp__providentia_"
    "mcp__range-intel-mcp__readme_"
    "mcp__velociraptor-mcp__"
    "mcp__wazuh-mcp__"
)

for prefix in "${RESEARCH_PREFIXES[@]}"; do
    if [[ "$tool_name" == "$prefix"* ]]; then
        printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Research gate active: %s blocked in master session. Dispatch a T3 thread for research work (delegate_task or t3_thread_launch). Delete .claude/.research-gate-active to override."}}\n' "$tool_name"
        exit 0
    fi
done

# Not a research tool — no opinion
exit 0
