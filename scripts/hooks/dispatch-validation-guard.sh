#!/usr/bin/env bash
# dispatch-validation-guard.sh — PreToolUse hook: enforce master dispatch discipline.
#
# Rules:
#   1. Block delegate_task from master — use t3_thread_launch instead
#   2. Warn on workspace strategy mismatch (research+worktree, impl+root)
#   3. Warn when ScheduleWakeup not called after dispatch
#
# Gate: .claude/.active-mode exists (mode active).
# Bypass: T3 child threads (mode-override file exists for session).
#
# Exit protocol:
#   0 + deny JSON  = blocked
#   0 + no output  = no opinion (allow)
#   2              = block (error / fail-closed)
set -euo pipefail
trap 'exit 2' ERR

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
MODE_FILE="$PROJECT_DIR/.claude/.active-mode"

# No active mode = gate inactive
[[ -f "$MODE_FILE" ]] || exit 0

# T3 child threads bypass all rules
OVERRIDE_DIR="$PROJECT_DIR/.claude/.mode-overrides"
SESSION_ID="${CLAUDE_CODE_SESSION_ID:-}"
if [[ -n "$SESSION_ID" && -f "$OVERRIDE_DIR/$SESSION_ID" ]]; then
    exit 0
fi

# Read and parse tool call from stdin
input="$(cat)"
parsed="$(printf '%s' "$input" | python3 -I -c '
import sys, json
try:
    data = json.load(sys.stdin)
except Exception:
    json.dump({"tool": ""}, sys.stdout)
    sys.exit(0)

tool_name = data.get("tool_name", "")
tool_input = data.get("tool_input", {})
if isinstance(tool_input, str):
    try:
        tool_input = json.loads(tool_input)
    except Exception:
        tool_input = {}

result = {"tool": tool_name}

if tool_name == "mcp__t3-code__t3_thread_launch":
    ws = tool_input.get("workspaceStrategy", {})
    result["ws_type"] = ws.get("type", "") if isinstance(ws, dict) else ""
    msg = tool_input.get("message", "") or tool_input.get("prompt", "") or ""
    result["prompt"] = msg[:500]

json.dump(result, sys.stdout)
' 2>/dev/null || echo '{"tool":""}')"

tool_name="$(printf '%s' "$parsed" | python3 -I -c \
    'import sys,json; print(json.load(sys.stdin).get("tool",""))' 2>/dev/null || true)"

PENDING_FILE="/tmp/claude-dispatch-pending-${SESSION_ID:-unknown}"

# --- Rule 3: Check pending dispatch ---
# Warn if dispatch pending and this call is not ScheduleWakeup, another
# dispatch, or a meta tool (ToolSearch, Skill, task tracking).
if [[ -f "$PENDING_FILE" ]]; then
    case "$tool_name" in
        ScheduleWakeup)
            rm -f "$PENDING_FILE"
            exit 0
            ;;
        mcp__t3-code__t3_thread_launch|mcp__t3-code__delegate_task \
        |ToolSearch|Skill|TaskCreate|TaskUpdate|TaskGet|TaskList)
            ;;
        *)
            echo "dispatch-validation-guard: ScheduleWakeup required after thread dispatch — call it before continuing other work." >&2
            ;;
    esac
fi

# --- Rule 1: Block delegate_task from master ---
if [[ "$tool_name" == "mcp__t3-code__delegate_task" ]]; then
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Master dispatch discipline: use t3_thread_launch for thread dispatch, not delegate_task. delegate_task is for child threads only."}}\n'
    exit 0
fi

# --- Rule 2 + pending marker: t3_thread_launch ---
if [[ "$tool_name" == "mcp__t3-code__t3_thread_launch" ]]; then
    # Set pending marker for Rule 3
    printf '%s\n' "$(date +%s)" > "$PENDING_FILE"

    ws_type="$(printf '%s' "$parsed" | python3 -I -c \
        'import sys,json; print(json.load(sys.stdin).get("ws_type",""))' 2>/dev/null || true)"
    prompt_text="$(printf '%s' "$parsed" | python3 -I -c \
        'import sys,json; print(json.load(sys.stdin).get("prompt",""))' 2>/dev/null || true)"

    # Classify task from prompt keywords
    task_class="$(printf '%s' "$prompt_text" | python3 -I -c '
import sys
text = sys.stdin.read().lower()
research = ["research", "investigate", "check", "query", "read-only",
            "review", "audit", "diagnose", "analyze", "scan"]
impl = ["implement", "build", "create", "write", "edit", "fix",
        "refactor", "deploy", "modify", "develop"]
r = sum(1 for w in research if w in text)
i = sum(1 for w in impl if w in text)
print("research" if r > i else "impl" if i > r else "unknown")
' 2>/dev/null || echo "unknown")"

    if [[ "$task_class" == "research" && "$ws_type" == "worktree" ]]; then
        echo "dispatch-validation-guard: Research task dispatched with worktree strategy. Research tasks should use root strategy for MCP access." >&2
    elif [[ "$task_class" == "impl" && "$ws_type" != "worktree" ]]; then
        echo "dispatch-validation-guard: Implementation task dispatched without worktree strategy. Implementation tasks should use worktree for isolation." >&2
    fi

    exit 0
fi

exit 0
