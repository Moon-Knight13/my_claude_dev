#!/usr/bin/env bash
# UserPromptSubmit hook: inject active mode's system prompt as additionalContext.
#
# Reads .claude/.active-mode to determine current mode, then injects the
# corresponding .claude/modes/<mode>/system-prompt.md content into every prompt.
# This lets the operator switch modes conversationally (/mode red-dev) without
# restarting the session.
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

# No active mode — skip silently
[[ -f "$MODE_FILE" ]] || exit 0

MODE="$(cat "$MODE_FILE" 2>/dev/null | tr -d '[:space:]')"
[[ -n "$MODE" ]] || exit 0

PROMPT_FILE="$MODES_DIR/$MODE/system-prompt.md"
[[ -f "$PROMPT_FILE" ]] || exit 0

CONTENT="$(cat "$PROMPT_FILE")"
[[ -n "$CONTENT" ]] || exit 0

# Build full context string, then JSON-encode the whole thing
FULL_CONTEXT="$(printf 'MODE ACTIVE: %s. Rules follow.\n\n%s' "$MODE" "$CONTENT")"
JSON_VALUE="$(printf '%s' "$FULL_CONTEXT" | jq -Rs '.')"

printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":%s}}\n' "$JSON_VALUE"
exit 0
