#!/usr/bin/env bash
# master-dispatch-guard.sh — user-level PreToolUse hook: enforce T3 thread dispatch.
# Deployed to ~/.claude/hooks/ by deploy-hq.sh.
# Denies Agent tool calls in master sessions — work goes via T3 threads.
set -euo pipefail
trap 'exit 2' ERR

# Double-fire prevention: if project-level hook exists, let it handle this.
HOOK_NAME="$(basename "${BASH_SOURCE[0]}")"
if [[ -n "${CLAUDE_PROJECT_DIR:-}" && \
      -x "$CLAUDE_PROJECT_DIR/.claude/hooks/$HOOK_NAME" ]]; then
    exit 0
fi

# Check for active mode — gate only fires when a mode is active.
# User-level: check $HOME/.claude/.active-mode
MODE_FILE="${HOME}/.claude/.active-mode"
[[ -f "$MODE_FILE" ]] || exit 0

# T3 child threads have a per-session mode override — never block them.
OVERRIDE_DIR="${HOME}/.claude/.mode-overrides"
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
