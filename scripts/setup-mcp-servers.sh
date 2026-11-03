#!/usr/bin/env bash
# setup-mcp-servers.sh — generate .mcp.json for Claude Code MCP server registration.
#
# Claude Code reads MCP servers from .mcp.json (not .claude/settings.json).
# This script writes .mcp.json from a central server catalog, filtered by the
# active mode's server list. ALL servers are launched through mcp-wrapper.sh so
# .env vars flow consistently — no stale baked-in values.
#
# Usage:
#   setup-mcp-servers.sh              # all servers (no mode filter)
#   setup-mcp-servers.sh red-team     # only servers in red-team manifest
#   setup-mcp-servers.sh --list       # print catalog server names
#
# Idempotent: overwrites .mcp.json each run. .mcp.json is gitignored.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MCP_FILE="$PROJECT_DIR/.mcp.json"
MCP_PKG_DIR="$PROJECT_DIR/.mcp-packages"
MODES_DIR="$PROJECT_DIR/.claude/modes"

# Pre-install packages that lack a bin entry (npx can't run them directly)
if [ ! -d "$MCP_PKG_DIR/node_modules/hacktricks-mcp" ]; then
    echo "Installing hacktricks-mcp (no bin entry — needs node direct)..."
    npm install --prefix "$MCP_PKG_DIR" hacktricks-mcp@1.3.0 --silent 2>&1 || true
fi

# --- Server catalog ---
# Every MCP server the hub can run. Modes select a subset by name.
# Defined as a jq-parseable JSON literal.
read -r -d '' CATALOG << 'CATALOG_JSON' || true
{
  "obsidian-mcp": {
    "command": "/workspace/scripts/mcp-wrapper.sh",
    "args": ["npx", "-y", "obsidian-mcp@2.0.1", "serve", "--vault", "my_notes=/home/node/vault"]
  },
  "rea-mcp": {
    "command": "/workspace/scripts/mcp-wrapper.sh",
    "args": ["npx", "-y", "rea-agents@6.8.0", "mcp"]
  },
  "hacktricks-mcp": {
    "command": "/workspace/scripts/mcp-wrapper.sh",
    "args": ["node", "/workspace/.mcp-packages/node_modules/hacktricks-mcp/dist/index.js"]
  },
  "mitre-mcp": {
    "command": "/workspace/scripts/mcp-wrapper.sh",
    "args": ["npx", "-y", "mitre-attack-mcp@1.0.1"]
  },
  "lolbins-mcp": {
    "command": "/workspace/scripts/mcp-wrapper.sh",
    "args": ["npx", "-y", "living-off-the-land-lolbins-mcp-server@0.1.0"]
  },
  "local-ollama": {
    "command": "/workspace/scripts/mcp-wrapper.sh",
    "args": ["npx", "-y", "ollama-mcp-server"]
  },
  "range-intel": {
    "command": "/workspace/scripts/mcp-wrapper.sh",
    "args": ["python3", "-m", "range_intel.server"],
    "cwd": "/workspace/mcp-servers/range-intel",
    "env": {
      "PYTHONPATH": "/workspace/mcp-servers/range-intel/src"
    }
  },
  "outline-readonly": {
    "command": "/workspace/scripts/mcp-wrapper.sh",
    "args": ["node", "/workspace/mcp-servers/outline-readonly/src/server.js"]
  },
  "tuoni-mcp": {
    "command": "/workspace/scripts/mcp-wrapper.sh",
    "args": ["python3", "-m", "tuoni_mcp"],
    "env": {
      "TUONI_VERIFY_TLS": "false",
      "TUONI_MCP_PROFILES": "agent-ops,access,discovery,authoring,administration"
    }
  }
}
CATALOG_JSON

# --- Mode manifests ---
# Each mode lists which catalog servers it needs. Servers not in the catalog
# are silently skipped (forward-compatible with planned servers like eip-mcp).
# "all" is a special pseudo-mode that includes every server.
declare -A MODE_SERVERS
MODE_SERVERS[all]="obsidian-mcp rea-mcp hacktricks-mcp mitre-mcp lolbins-mcp local-ollama range-intel outline-readonly tuoni-mcp"
MODE_SERVERS[platform-ops]="local-ollama"
MODE_SERVERS[red-team]="tuoni-mcp range-intel outline-readonly obsidian-mcp hacktricks-mcp mitre-mcp lolbins-mcp"
MODE_SERVERS[red-dev]="tuoni-mcp rea-mcp hacktricks-mcp mitre-mcp obsidian-mcp lolbins-mcp"
MODE_SERVERS[green-dev]="range-intel outline-readonly"
MODE_SERVERS[purple]="tuoni-mcp range-intel outline-readonly obsidian-mcp hacktricks-mcp mitre-mcp lolbins-mcp"

# --- Argument handling ---
MODE="${1:-all}"

if [[ "$MODE" == "--list" ]]; then
    echo "$CATALOG" | jq -r 'keys[]' | sort
    exit 0
fi

if [[ "$MODE" != "all" && -z "${MODE_SERVERS[$MODE]+x}" ]]; then
    echo "Unknown mode: $MODE" >&2
    echo "Available: ${!MODE_SERVERS[*]}" >&2
    exit 1
fi

SERVER_LIST="${MODE_SERVERS[$MODE]}"

# Build filtered .mcp.json from catalog
FILTER_EXPR=""
for srv in $SERVER_LIST; do
    if [[ -n "$FILTER_EXPR" ]]; then
        FILTER_EXPR="$FILTER_EXPR, "
    fi
    FILTER_EXPR="${FILTER_EXPR}\"$srv\""
done

echo "$CATALOG" | jq --argjson keys "[$FILTER_EXPR]" '
  to_entries | map(select(.key as $k | $keys | index($k))) | from_entries |
  { mcpServers: . }
' > "$MCP_FILE"

COUNT=$(python3 -I -c "import json; print(len(json.load(open('$MCP_FILE'))['mcpServers']))" 2>/dev/null || echo '?')
echo "Generated $MCP_FILE with $COUNT MCP servers (mode: $MODE)"
