#!/usr/bin/env bash
# UserPromptSubmit hook: inject active mode's system prompt + filtered skill list.
#
# Reads .claude/.active-mode to determine current mode, then injects the
# corresponding .claude/modes/<mode>/system-prompt.md content into every prompt.
# Also scans .claude/skills/*/SKILL.md and .claude/commands/*.md for `modes:`
# frontmatter and emits a filtered skill/command list for the active mode —
# positive guidance so Claude picks the right skills without evaluating all 60+.
# Hard enforcement is in .claude/hooks/skill-mode-gate.sh (PreToolUse on Skill).
#
# Mode switching: the /mode skill writes .claude/.active-mode. This hook picks
# it up on the next prompt. No restart needed for mode rules — only for MCP
# server changes (those are startup-only).
#
# Exit codes (Claude Code UserPromptSubmit protocol):
#   0 — allow (with optional additionalContext on stdout)
set -euo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-.}"
MODE_FILE="$PROJECT_DIR/.claude/.active-mode"
MODES_DIR="$PROJECT_DIR/.claude/modes"
SKILLS_DIR="$PROJECT_DIR/.claude/skills"
COMMANDS_DIR="$PROJECT_DIR/.claude/commands"

# No active mode — skip silently
[[ -f "$MODE_FILE" ]] || exit 0

MODE="$(tr -d '[:space:]' < "$MODE_FILE" 2>/dev/null)"
[[ -n "$MODE" ]] || exit 0

PROMPT_FILE="$MODES_DIR/$MODE/system-prompt.md"
[[ -f "$PROMPT_FILE" ]] || exit 0

CONTENT="$(cat "$PROMPT_FILE")"
[[ -n "$CONTENT" ]] || exit 0

# Scan skills and commands for mode-matching frontmatter
MATCHED_SKILLS=""
MATCHED_COMMANDS=""

# Helper: append to a comma-separated list ($1=varname, $2=value)
_append() {
  local current="${!1}"
  if [[ -n "$current" ]]; then
    printf -v "$1" '%s, %s' "$current" "$2"
  else
    printf -v "$1" '%s' "$2"
  fi
}

# Scan .claude/skills/*/SKILL.md
if [[ -d "$SKILLS_DIR" ]]; then
  for skill_dir in "$SKILLS_DIR"/*/; do
    skill_file="$skill_dir/SKILL.md"
    [[ -f "$skill_file" ]] || continue

    skill_name="$(basename "$skill_dir")"
    modes_line="$(sed -n '/^---$/,/^---$/{/^modes:/p}' "$skill_file" 2>/dev/null)"
    [[ -n "$modes_line" ]] || continue

    if printf '%s' "$modes_line" | grep -qw "$MODE"; then
      _append MATCHED_SKILLS "$skill_name"
    fi
  done
fi

# Scan .claude/commands/*.md
if [[ -d "$COMMANDS_DIR" ]]; then
  for cmd_file in "$COMMANDS_DIR"/*.md; do
    [[ -f "$cmd_file" ]] || continue

    cmd_name="$(basename "$cmd_file" .md)"
    modes_line="$(sed -n '/^---$/,/^---$/{/^modes:/p}' "$cmd_file" 2>/dev/null)"

    # Commands without modes: field are allowed in all modes
    if [[ -z "$modes_line" ]]; then
      _append MATCHED_COMMANDS "$cmd_name"
      continue
    fi

    if printf '%s' "$modes_line" | grep -qw "$MODE"; then
      _append MATCHED_COMMANDS "$cmd_name"
    fi
  done
fi

# Build skill guidance block
SKILL_BLOCK=""
FILTER_LINES=""
if [[ -n "$MATCHED_SKILLS" ]]; then
  FILTER_LINES="Skills: $MATCHED_SKILLS."
fi
if [[ -n "$MATCHED_COMMANDS" ]]; then
  [[ -n "$FILTER_LINES" ]] && FILTER_LINES="$FILTER_LINES\n"
  FILTER_LINES="${FILTER_LINES}Commands: $MATCHED_COMMANDS."
fi
if [[ -n "$FILTER_LINES" ]]; then
  SKILL_BLOCK="$(printf '\n\n### Skill Filter for %s mode\n%b\nSkills/commands outside this list are blocked by skill-mode-gate hook.' "$MODE" "$FILTER_LINES")"
fi

# Build full context string, then JSON-encode the whole thing
FULL_CONTEXT="$(printf 'MODE ACTIVE: %s. Rules follow.\n\n%s%s' "$MODE" "$CONTENT" "$SKILL_BLOCK")"
JSON_VALUE="$(printf '%s' "$FULL_CONTEXT" | jq -Rs '.')"

printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":%s}}\n' "$JSON_VALUE"
exit 0
