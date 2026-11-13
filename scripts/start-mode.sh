#!/usr/bin/env bash
# start-mode.sh — launch Claude Code in a specific operational mode.
#
# Each mode gets its own system prompt, settings overlay, and MCP server config
# via CLI flags. No shared files are overwritten, so parallel sessions in
# different modes are safe.
#
# Usage:
#   start-mode.sh <mode> [claude-args...]
#   start-mode.sh --list
#
# Examples:
#   start-mode.sh red-team                     # interactive red-team session
#   start-mode.sh red-dev --bg -p "research CVE-2024-1234"  # background red-dev
#   start-mode.sh green-dev -w                 # green-dev in a worktree
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MODES_DIR="$PROJECT_DIR/.claude/modes"

# --- List modes ---
if [[ "${1:-}" == "--list" || "${1:-}" == "-l" ]]; then
    echo "Available modes:"
    for dir in "$MODES_DIR"/*/; do
        name="$(basename "$dir")"
        [[ "$name" == "base" || "$name" == "offensive-base" ]] && continue
        desc=""
        if [[ -f "$dir/settings.json" ]]; then
            desc=$(jq -r '._description // empty' "$dir/settings.json" 2>/dev/null)
        fi
        printf "  %-14s %s\n" "$name" "$desc"
    done
    exit 0
fi

# --- Validate mode ---
MODE="${1:?Usage: start-mode.sh <mode> [claude-args...]  (--list to see modes)}"
shift

MODE_DIR="$MODES_DIR/$MODE"
if [[ ! -d "$MODE_DIR" ]]; then
    echo "Error: unknown mode '$MODE'" >&2
    echo "Run: start-mode.sh --list" >&2
    exit 1
fi

SYSTEM_PROMPT="$MODE_DIR/system-prompt.md"
if [[ ! -f "$SYSTEM_PROMPT" ]]; then
    echo "Error: $SYSTEM_PROMPT missing" >&2
    exit 1
fi

MODE_SETTINGS="$MODE_DIR/settings.json"
if [[ ! -f "$MODE_SETTINGS" ]]; then
    echo "Error: $MODE_SETTINGS missing" >&2
    exit 1
fi

# --- Generate per-mode MCP config ---
bash "$SCRIPT_DIR/setup-mcp-servers.sh" "$MODE"
MCP_FILE="$PROJECT_DIR/.mcp-${MODE}.json"

if [[ ! -f "$MCP_FILE" ]]; then
    echo "Error: MCP config generation failed" >&2
    exit 1
fi

# --- Write active mode marker (for statusline and scripts) ---
echo "$MODE" > "$PROJECT_DIR/.claude/.active-mode"

# --- Report ---
echo ""
echo "  Mode:  $MODE"
jq -r '.mcpServers | keys | "  MCP:   " + join(", ")' "$MCP_FILE"
desc=$(jq -r '._description // empty' "$MODE_SETTINGS" 2>/dev/null)
if [[ -n "$desc" ]]; then
    echo "  About: $desc"
fi
echo ""

# --- Build effective system prompt (offensive-base concatenation) ---
OFFENSIVE_BASE="$MODES_DIR/offensive-base/shared-rules.md"
HAS_BASE=$(jq -r '._offensive_base // false' "$MODE_SETTINGS" 2>/dev/null)

if [[ "$HAS_BASE" == "true" && -f "$OFFENSIVE_BASE" ]]; then
    EFFECTIVE_PROMPT=$(mktemp "${TMPDIR:-/tmp}/claude-mode-prompt.XXXXXX")
    trap 'rm -f "$EFFECTIVE_PROMPT"' EXIT
    cat "$OFFENSIVE_BASE" "$SYSTEM_PROMPT" > "$EFFECTIVE_PROMPT"
else
    EFFECTIVE_PROMPT="$SYSTEM_PROMPT"
fi

# --- Launch Claude Code ---
# --append-system-prompt-file: injects mode rules into system prompt
# --settings: overlays mode metadata on top of project settings
# --mcp-config + --strict-mcp-config: uses only this mode's MCP servers
# --name: labels the session in `claude agents` list
exec claude \
    --append-system-prompt-file "$EFFECTIVE_PROMPT" \
    --settings "$MODE_SETTINGS" \
    --mcp-config "$MCP_FILE" \
    --strict-mcp-config \
    --name "$MODE" \
    "$@"
