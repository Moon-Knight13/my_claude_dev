#!/usr/bin/env bash
# setup-mcp-servers.sh — generate .mcp.json for Claude Code MCP server registration.
#
# Claude Code reads MCP servers from .mcp.json (not .claude/settings.json).
# This script writes .mcp.json from a central server catalog, filtered by the
# active mode's server list. ALL servers are launched through mcp-wrapper.sh so
# .env vars flow consistently — no stale baked-in values.
#
# Usage:
#   setup-mcp-servers.sh              # all servers → .mcp.json
#   setup-mcp-servers.sh red-team     # red-team servers → .mcp-red-team.json
#   setup-mcp-servers.sh --list       # print catalog server names
#
# When a mode is specified, output goes to .mcp-<mode>.json (parallel-safe).
# When no mode is specified (or "all"), output goes to .mcp.json.
#
# Idempotent: overwrites target file each run. All .mcp*.json are gitignored.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MCP_FILE=""  # set below based on mode
MCP_PKG_DIR="$PROJECT_DIR/.mcp-packages"

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
  },
  "cve-mcp": {
    "command": "/workspace/scripts/mcp-wrapper.sh",
    "args": ["npx", "-y", "cve-mcp@0.2.0"]
  },
  "bloodhound-mcp": {
    "command": "/workspace/scripts/mcp-wrapper.sh",
    "args": ["python3", "-m", "bloodhound_mcp"],
    "env": {
      "BH_NEO4J_URI": "bolt://${SPOKE_KALI_HOST:-localhost}:7687",
      "BH_NEO4J_USER": "${BH_NEO4J_USER:-neo4j}",
      "BH_NEO4J_PASSWORD": "${BH_NEO4J_PASSWORD:-}"
    }
  },
  "hashcat-mcp": {
    "command": "/workspace/scripts/mcp-wrapper.sh",
    "args": ["python3", "-m", "hashcat_mcp"],
    "env": {
      "HASHCAT_HOST": "${SPOKE_KALI_HOST:-localhost}",
      "HASHCAT_SSH_USER": "${SPOKE_KALI_USER:-rt}"
    }
  },
  "nuclei-mcp": {
    "command": "/workspace/scripts/mcp-wrapper.sh",
    "args": ["/workspace/.cache/nuclei-mcp/nuclei-mcp"],
    "env": {
      "NUCLEI_HOST": "${SPOKE_KALI_HOST:-localhost}",
      "NUCLEI_SSH_USER": "${SPOKE_KALI_USER:-rt}"
    }
  }
}
CATALOG_JSON

# --- Mode manifests ---
# Each mode lists which catalog servers it needs. Servers not in the catalog
# are silently skipped (forward-compatible with planned servers like eip-mcp).
# "all" is a special pseudo-mode that includes every server.
declare -A MODE_SERVERS
MODE_SERVERS[all]="obsidian-mcp rea-mcp hacktricks-mcp mitre-mcp lolbins-mcp cve-mcp local-ollama range-intel outline-readonly tuoni-mcp bloodhound-mcp hashcat-mcp nuclei-mcp"
MODE_SERVERS[platform-ops]="local-ollama"
MODE_SERVERS[red-team]="tuoni-mcp range-intel outline-readonly obsidian-mcp hacktricks-mcp mitre-mcp lolbins-mcp cve-mcp bloodhound-mcp hashcat-mcp nuclei-mcp"
MODE_SERVERS[red-dev]="tuoni-mcp rea-mcp hacktricks-mcp mitre-mcp obsidian-mcp lolbins-mcp cve-mcp"
MODE_SERVERS[green-dev]="range-intel outline-readonly"
MODE_SERVERS[purple]="tuoni-mcp range-intel outline-readonly obsidian-mcp hacktricks-mcp mitre-mcp lolbins-mcp cve-mcp bloodhound-mcp hashcat-mcp nuclei-mcp"

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

# Per-mode output file (parallel-safe); "all" goes to .mcp.json
if [[ "$MODE" == "all" ]]; then
    MCP_FILE="$PROJECT_DIR/.mcp.json"
else
    MCP_FILE="$PROJECT_DIR/.mcp-${MODE}.json"
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
