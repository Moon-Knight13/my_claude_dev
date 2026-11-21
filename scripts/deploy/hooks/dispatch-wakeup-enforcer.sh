#!/usr/bin/env bash
# dispatch-wakeup-enforcer.sh — user-level PostToolUse hook.
# Deployed to ~/.claude/hooks/ by deploy-hq.sh.
# Nudges master sessions to use ScheduleWakeup after dispatching threads.
# Notification only — does not deny anything.
set -euo pipefail
trap 'exit 2' ERR

# Double-fire prevention: if project-level hook exists, let it handle this.
HOOK_NAME="$(basename "${BASH_SOURCE[0]}")"
if [[ -n "${CLAUDE_PROJECT_DIR:-}" && \
      -x "$CLAUDE_PROJECT_DIR/.claude/hooks/$HOOK_NAME" ]]; then
    exit 0
fi

# Only fire for dispatch tools
input="$(cat)"
tool_name="$(printf '%s' "$input" | python3 -I -c '
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get("tool_name", ""))
except Exception:
    print("")
' 2>/dev/null || true)"

case "$tool_name" in
    mcp__t3-code__delegate_task|mcp__t3-code__t3_thread_launch|mcp__t3-code__create_threads)
        ;;
    *)
        exit 0
        ;;
esac

# Only fire in master sessions (mode active, no mode-override for this session)
MODE_FILE="${HOME}/.claude/.active-mode"
[[ -f "$MODE_FILE" ]] || exit 0

OVERRIDE_DIR="${HOME}/.claude/.mode-overrides"
SESSION_ID="${CLAUDE_CODE_SESSION_ID:-}"
if [[ -n "$SESSION_ID" && -f "$OVERRIDE_DIR/$SESSION_ID" ]]; then
    exit 0
fi

# Emit notification (not deny)
printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","notification":"Thread dispatched. Use ScheduleWakeup to monitor completion. Do not wait for user prompt."}}\n'
exit 0
