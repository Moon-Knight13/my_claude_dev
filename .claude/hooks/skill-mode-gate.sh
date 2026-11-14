#!/usr/bin/env bash
# skill-mode-gate.sh — PreToolUse hook: deny Skill calls outside listed modes.
#
# Reads the skill name from the Skill tool input, finds its definition in
# .claude/skills/<name>/SKILL.md or .claude/commands/<name>.md, extracts the
# modes: frontmatter, and denies if the active mode is not listed.
#
# Skills/commands with no modes: field are allowed in all modes (backwards compat).
# The "mode" command is always allowed (hard override).
#
# Exit protocol (PreToolUse):
#   0 + deny JSON  = blocked
#   0 + no output  = no opinion (allow)
#   2              = block (error / fail-closed)
set -euo pipefail
trap 'exit 2' ERR

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
MODE_FILE="$PROJECT_DIR/.claude/.active-mode"

[[ -f "$MODE_FILE" ]] || exit 0

OVERRIDE_DIR="$PROJECT_DIR/.claude/.mode-overrides"
SESSION_ID="${CLAUDE_CODE_SESSION_ID:-}"
if [[ -n "$SESSION_ID" && -f "$OVERRIDE_DIR/$SESSION_ID" ]]; then
    MODE="$(cat "$OVERRIDE_DIR/$SESSION_ID" 2>/dev/null)"
else
    MODE="$(cat "$MODE_FILE" 2>/dev/null)"
fi
[[ -n "$MODE" ]] || exit 0

input="$(cat)"

skill_name="$(printf '%s' "$input" | python3 -I -c '
import sys, json
try:
    data = json.load(sys.stdin)
    inp = data.get("tool_input", {})
    if isinstance(inp, str):
        import json as j
        inp = j.loads(inp)
    print(inp.get("skill", ""))
except Exception:
    print("")
' 2>/dev/null || true)"

[[ -n "$skill_name" ]] || exit 0

# "mode" command always allowed
[[ "$skill_name" == "mode" ]] && exit 0

# Find skill definition file
SKILL_FILE=""
if [[ -f "$PROJECT_DIR/.claude/skills/$skill_name/SKILL.md" ]]; then
    SKILL_FILE="$PROJECT_DIR/.claude/skills/$skill_name/SKILL.md"
elif [[ -f "$PROJECT_DIR/.claude/commands/$skill_name.md" ]]; then
    SKILL_FILE="$PROJECT_DIR/.claude/commands/$skill_name.md"
fi

# No definition found — allow (external or plugin skill)
[[ -n "$SKILL_FILE" ]] || exit 0

# Extract modes: from YAML frontmatter
modes_line="$(sed -n '/^---$/,/^---$/{/^modes:/p}' "$SKILL_FILE" 2>/dev/null)"

# No modes: field — allowed in all modes
[[ -n "$modes_line" ]] || exit 0

# Check if active mode appears in modes list
if printf '%s' "$modes_line" | grep -qw "$MODE"; then
    exit 0
fi

printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Skill \"%s\" is not available in %s mode. Its modes: %s. Switch mode with /mode to access it."}}\n' \
    "$skill_name" "$MODE" "$(printf '%s' "$modes_line" | sed 's/^modes: *//')"
exit 0
