#!/usr/bin/env bash
# master-dispatch-guard.sh — PreToolUse hook: enforce T3 thread dispatch
# for work delegation in master sessions.
#
# When .claude/.active-mode exists, deny Agent tool calls from the master
# session unless they are forks or cavecrew subagents. Work delegation
# belongs in T3 threads so master context stays clean and worktree
# isolation is enforced.
#
# Gate activates: .claude/.active-mode exists (any mode active).
# Gate deactivates: .active-mode absent (no mode = vanilla session).
#
# Bypass conditions (any one skips the gate):
#   - .active-mode absent (no mode active)
#   - Session has a mode-override file (T3 child thread)
#   - subagent_type is "fork"
#   - subagent_type starts with "caveman:cavecrew-"
#
# Exit protocol (same as research-dispatch-guard.sh):
#   0 + deny JSON  = blocked
#   0 + no output  = no opinion (allow)
#   2              = block (error / fail-closed)
set -euo pipefail
trap 'exit 2' ERR

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
MODE_FILE="$PROJECT_DIR/.claude/.active-mode"

# No active mode = gate inactive, allow everything
[[ -f "$MODE_FILE" ]] || exit 0

# T3 child threads have a per-session mode override — they are dispatched
# workers, so never block them.
OVERRIDE_DIR="$PROJECT_DIR/.claude/.mode-overrides"
SESSION_ID="${CLAUDE_CODE_SESSION_ID:-}"
if [[ -n "$SESSION_ID" && -f "$OVERRIDE_DIR/$SESSION_ID" ]]; then
    exit 0
fi

# Read tool input from stdin JSON
input="$(cat)"
subagent_type="$(printf '%s' "$input" | python3 -I -c '
import sys, json
try:
    data = json.load(sys.stdin)
    tool_input = data.get("tool_input", {})
    print(tool_input.get("subagent_type", ""))
except Exception:
    print("")
' 2>/dev/null || true)"

# Forks stay in the same session context — allow
[[ "$subagent_type" == "fork" ]] && exit 0

# Cavecrew subagents are compressed-output helpers — allow
[[ "$subagent_type" == caveman:cavecrew-* ]] && exit 0

# Everything else: deny
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Master session dispatches work via T3 threads (t3_thread_launch), not Agent subagents. Use t3_thread_launch with workspaceStrategy: worktree for isolated work."}}\n'
exit 0
