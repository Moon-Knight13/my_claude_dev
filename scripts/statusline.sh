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
# Resolve caveman statusline: env override > auto-detect from plugin cache.
# install-caveman.sh hardcodes a container path; on host the version dir differs.
CAVEMAN_STATUSLINE_CMD="${CAVEMAN_STATUSLINE_CMD:-}"
if [ -z "$CAVEMAN_STATUSLINE_CMD" ] || [ ! -f "$CAVEMAN_STATUSLINE_CMD" ]; then
    for _d in "$HOME"/.claude/plugins/cache/caveman/caveman/*/src/hooks \
              "$HOME"/.claude/plugins/cache/claude-plugins-official/caveman/*/src/hooks; do
        [ -f "$_d/caveman-statusline.sh" ] && { CAVEMAN_STATUSLINE_CMD="$_d/caveman-statusline.sh"; break; }
    done
fi
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

# --- T3 badge ---
T3_OUT=""
if [ "${CLAUDE_CODE_ENTRYPOINT:-}" = "t3-code" ]; then
    T3_OUT=$'\033[38;5;45m[T3]\033[0m'
fi

# Combine: T3 > mode > caveman
OUTPUT=""
for _badge in "$T3_OUT" "$MODE_OUT" "$CAVEMAN_OUT"; do
    [ -n "$_badge" ] || continue
    [ -n "$OUTPUT" ] && OUTPUT="$OUTPUT "
    OUTPUT="$OUTPUT$_badge"
done

[ -n "$OUTPUT" ] && printf '%s' "$OUTPUT"
exit 0
