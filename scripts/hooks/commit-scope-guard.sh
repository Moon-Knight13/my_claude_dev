#!/usr/bin/env bash
# commit-scope-guard.sh — PostToolUse hook: warn on multiple commits per session.
#
# Deploy threads should produce a single atomic commit. This soft guard
# tracks commits per session and warns (never blocks) on the second+.
#
# Trigger: PostToolUse on Bash tool
# Detection: "git commit" in tool_input.command
# Tracking: /tmp/cc-commit-count/<session-id>
#
# Exit codes:
#   0 — always (PostToolUse cannot block)
set -euo pipefail

HOOK_INPUT="$(cat)"

TOOL_NAME="$(printf '%s' "$HOOK_INPUT" | python3 -I -c '
import sys, json
try: print(json.load(sys.stdin).get("tool_name",""))
except: print("")' 2>/dev/null || true)"

[[ "$TOOL_NAME" == "Bash" ]] || exit 0

COMMAND="$(printf '%s' "$HOOK_INPUT" | python3 -I -c '
import sys, json
try:
    data = json.load(sys.stdin)
    inp = data.get("tool_input", {})
    if isinstance(inp, dict):
        print(inp.get("command", ""))
    elif isinstance(inp, str):
        print(inp)
    else:
        print("")
except: print("")' 2>/dev/null || true)"

# Only track actual git commit commands (not git commit --amend, log, etc. are fine)
[[ "$COMMAND" =~ git[[:space:]]+commit ]] || exit 0

# Session key: prefer CLAUDE_SESSION_ID, fall back to parent PID
SESSION_KEY="${CLAUDE_SESSION_ID:-ppid-$$}"

TRACK_DIR="/tmp/cc-commit-count"
mkdir -p "$TRACK_DIR" 2>/dev/null || true
TRACK_FILE="$TRACK_DIR/$SESSION_KEY"

# Increment count
COUNT=1
if [[ -f "$TRACK_FILE" ]]; then
    PREV="$(cat "$TRACK_FILE" 2>/dev/null || echo 0)"
    COUNT=$(( PREV + 1 ))
fi
printf '%d' "$COUNT" > "$TRACK_FILE"

# First commit: silent
(( COUNT <= 1 )) && exit 0

# Second+: warn
MSG="Multiple commits detected. Deploy threads should produce single atomic commit."
printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","notification":"%s"}}\n' "$MSG"
exit 0
