#!/usr/bin/env bash
# UserPromptSubmit hook: inject active mode's system prompt + filtered skill list.
#
# Reads .claude/.active-mode to determine current mode, then injects the
# corresponding .claude/modes/<mode>/system-prompt.md content into every prompt.
# Also scans .claude/skills/*/SKILL.md for `modes:` frontmatter and emits a
# filtered skill list for the active mode — positive guidance so Claude picks
# the right skills without evaluating all 60+.
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

# No active mode — skip silently
[[ -f "$MODE_FILE" ]] || exit 0

MODE="$(tr -d '[:space:]' < "$MODE_FILE" 2>/dev/null)"
[[ -n "$MODE" ]] || exit 0

PROMPT_FILE="$MODES_DIR/$MODE/system-prompt.md"
[[ -f "$PROMPT_FILE" ]] || exit 0

CONTENT="$(cat "$PROMPT_FILE")"
[[ -n "$CONTENT" ]] || exit 0

# Scan skills for mode-matching frontmatter
MATCHED_SKILLS=""
if [[ -d "$SKILLS_DIR" ]]; then
  for skill_dir in "$SKILLS_DIR"/*/; do
    skill_file="$skill_dir/SKILL.md"
    [[ -f "$skill_file" ]] || continue

    skill_name="$(basename "$skill_dir")"

    # Extract modes: line from YAML frontmatter (between --- markers)
    modes_line="$(sed -n '/^---$/,/^---$/{/^modes:/p}' "$skill_file" 2>/dev/null)"
    [[ -n "$modes_line" ]] || continue

    # Check if current mode appears in the modes list
    if printf '%s' "$modes_line" | grep -qw "$MODE"; then
      if [[ -n "$MATCHED_SKILLS" ]]; then
        MATCHED_SKILLS="$MATCHED_SKILLS, $skill_name"
      else
        MATCHED_SKILLS="$skill_name"
      fi
    fi
  done
fi

# Build skill guidance block
SKILL_BLOCK=""
if [[ -n "$MATCHED_SKILLS" ]]; then
  SKILL_BLOCK="$(printf '\n\n### Skill Filter for %s mode\nPreferred skills: %s.\nDo NOT invoke bmad-* or other unlisted skills unless operator explicitly requests them.' "$MODE" "$MATCHED_SKILLS")"
fi

# Build full context string, then JSON-encode the whole thing
FULL_CONTEXT="$(printf 'MODE ACTIVE: %s. Rules follow.\n\n%s%s' "$MODE" "$CONTENT" "$SKILL_BLOCK")"
JSON_VALUE="$(printf '%s' "$FULL_CONTEXT" | jq -Rs '.')"

printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":%s}}\n' "$JSON_VALUE"
exit 0
