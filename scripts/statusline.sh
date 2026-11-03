#!/usr/bin/env bash
# statusline.sh — composite status line for Claude Code.
#
# Shows active operational mode alongside any other badges (caveman).
# Reads mode from .claude/.active-mode (written by /mode command).
# Passes stdin through to caveman statusline for session-aware mode detection.
#
# Registered in user-level settings.json by install-statusline.sh or
# setup-mcp-servers.sh. The caveman statusline script path is resolved at
# install time and stored in CAVEMAN_STATUSLINE_CMD below.
set -euo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-/workspace}"
MODE_FILE="$PROJECT_DIR/.claude/.active-mode"

# Buffer stdin so both this script and caveman can read it.
STDIN_BUF=""
if [ ! -t 0 ]; then
    IFS= read -r -d '' -t 1 STDIN_BUF || true
fi

# --- Caveman badge ---
CAVEMAN_STATUSLINE_CMD="${CAVEMAN_STATUSLINE_CMD:-}"
CAVEMAN_OUT=""
if [ -n "$CAVEMAN_STATUSLINE_CMD" ] && [ -f "$CAVEMAN_STATUSLINE_CMD" ]; then
    CAVEMAN_OUT=$(printf '%s' "$STDIN_BUF" | bash "$CAVEMAN_STATUSLINE_CMD" 2>/dev/null) || true
fi

# --- Mode badge ---
MODE_OUT=""
if [ -f "$MODE_FILE" ] && [ ! -L "$MODE_FILE" ]; then
    MODE=$(head -c 32 "$MODE_FILE" 2>/dev/null | tr -d '\n\r' | tr -cd 'a-z0-9-')
    case "$MODE" in
        platform-ops) MODE_OUT=$'\033[38;5;39m[PLATFORM-OPS]\033[0m' ;;
        red-team)     MODE_OUT=$'\033[38;5;196m[RED-TEAM]\033[0m' ;;
        red-dev)      MODE_OUT=$'\033[38;5;208m[RED-DEV]\033[0m' ;;
        green-dev)    MODE_OUT=$'\033[38;5;40m[GREEN-DEV]\033[0m' ;;
        purple)       MODE_OUT=$'\033[38;5;135m[PURPLE]\033[0m' ;;
    esac
fi

# Combine: mode first, then caveman
OUTPUT=""
[ -n "$MODE_OUT" ] && OUTPUT="$MODE_OUT"
if [ -n "$CAVEMAN_OUT" ]; then
    [ -n "$OUTPUT" ] && OUTPUT="$OUTPUT "
    OUTPUT="$OUTPUT$CAVEMAN_OUT"
fi

[ -n "$OUTPUT" ] && printf '%s' "$OUTPUT"
exit 0
