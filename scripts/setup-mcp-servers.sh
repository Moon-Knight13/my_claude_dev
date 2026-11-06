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

# --- Resolve paths ---
# Detect host vs container and set paths accordingly.
WRAPPER="$PROJECT_DIR/scripts/mcp-wrapper.sh"
PKG_DIR="$PROJECT_DIR/.mcp-packages"

# Host vs container: use venv python for Python-based MCPs on host.
VENV_DIR="$PROJECT_DIR/mcp-servers/.venv"
if [[ "${DEVCONTAINER:-}" != "true" ]] && [[ -d "$VENV_DIR/bin" ]]; then
    PYTHON_CMD="$VENV_DIR/bin/python3"
else
    PYTHON_CMD="python3"
fi

# Obsidian vault: container mounts at /home/node/vault, host uses OBSIDIAN_VAULT_PATH from .env
# shellcheck source=scripts/lib/load-env.sh
source "$SCRIPT_DIR/lib/load-env.sh" 2>/dev/null || true
if [[ -d "/home/node/vault" ]]; then
    VAULT_PATH="/home/node/vault"
elif [[ -n "${OBSIDIAN_VAULT_PATH:-}" ]]; then
    # Expand ~ if present
    VAULT_PATH="${OBSIDIAN_VAULT_PATH/#\~/$HOME}"
else
    VAULT_PATH="$HOME/Documents/my_notes"
fi

# --- Networking mode detection ---
# Bridge mode: container on docker bridge, range MCPs via SSE proxy on host.
# Host mode: container shares host network, range MCPs via stdio directly.
# Non-container: running on host, range MCPs via stdio directly.
USE_SSE_PROXY=false
if [[ "${DEVCONTAINER:-}" == "true" && -z "${DOCKER_HOST_NETWORK:-}" ]]; then
    USE_SSE_PROXY=true
fi

SSE_HOST="${MCP_PROXY_HOST:-host.docker.internal}"

# --- Server catalog ---
# Every MCP server the hub can run. Modes select a subset by name.
# Paths use $PROJECT_DIR so the catalog works on both host and container.
# Defined as a jq-parseable JSON literal using variable interpolation.
#
# Range-facing MCPs (range-intel, tuoni-mcp, outline-readonly) have two forms:
#   stdio  — direct spawn (host networking or non-container)
#   SSE    — connect via SSE proxy on host (bridge networking)

if [[ "$USE_SSE_PROXY" == "true" ]]; then
    # Bridge mode: range MCPs connect via SSE proxy running on host
    if [[ -n "${MCP_PROXY_TOKEN:-}" ]]; then
        RANGE_INTEL_JSON="\"range-intel\": { \"url\": \"http://$SSE_HOST:8101/sse\", \"headers\": { \"Authorization\": \"Bearer $MCP_PROXY_TOKEN\" } }"
        TUONI_MCP_JSON="\"tuoni-mcp\": { \"url\": \"http://$SSE_HOST:8102/sse\", \"headers\": { \"Authorization\": \"Bearer $MCP_PROXY_TOKEN\" } }"
        OUTLINE_JSON="\"outline-readonly\": { \"url\": \"http://$SSE_HOST:8103/sse\", \"headers\": { \"Authorization\": \"Bearer $MCP_PROXY_TOKEN\" } }"
    else
        RANGE_INTEL_JSON="\"range-intel\": { \"url\": \"http://$SSE_HOST:8101/sse\" }"
        TUONI_MCP_JSON="\"tuoni-mcp\": { \"url\": \"http://$SSE_HOST:8102/sse\" }"
        OUTLINE_JSON="\"outline-readonly\": { \"url\": \"http://$SSE_HOST:8103/sse\" }"
    fi
    echo "SSE proxy mode: range MCPs via http://$SSE_HOST:{8101-8103}/sse"
else
    RANGE_INTEL_JSON="\"range-intel\": { \"command\": \"$WRAPPER\", \"args\": [\"$PYTHON_CMD\", \"-m\", \"range_intel.server\"], \"cwd\": \"$PROJECT_DIR/mcp-servers/range-intel\", \"env\": { \"PYTHONPATH\": \"$PROJECT_DIR/mcp-servers/range-intel/src\" } }"
    TUONI_MCP_JSON="\"tuoni-mcp\": { \"command\": \"$WRAPPER\", \"args\": [\"$PYTHON_CMD\", \"-m\", \"tuoni_mcp\"], \"env\": { \"TUONI_VERIFY_TLS\": \"false\", \"TUONI_MCP_PROFILES\": \"agent-ops,access,discovery,authoring,administration\" } }"
    OUTLINE_JSON="\"outline-readonly\": { \"command\": \"$WRAPPER\", \"args\": [\"node\", \"$PROJECT_DIR/mcp-servers/outline-readonly/src/server.js\"] }"
fi

read -r -d '' CATALOG << CATALOG_JSON || true
{
  "obsidian-mcp": {
    "command": "$WRAPPER",
    "args": ["npx", "-y", "obsidian-mcp@2.0.1", "serve", "--vault", "my_notes=$VAULT_PATH"]
  },
  "rea-mcp": {
    "command": "$WRAPPER",
    "args": ["npx", "-y", "rea-agents@6.8.0", "mcp"]
  },
  "hacktricks-mcp": {
    "command": "$WRAPPER",
    "args": ["node", "$PKG_DIR/node_modules/hacktricks-mcp/dist/index.js"]
  },
  "mitre-mcp": {
    "command": "$WRAPPER",
    "args": ["npx", "-y", "mitre-attack-mcp@1.0.1"]
  },
  "lolbins-mcp": {
    "command": "$WRAPPER",
    "args": ["npx", "-y", "living-off-the-land-lolbins-mcp-server@0.1.0"]
  },
  "local-ollama": {
    "command": "$WRAPPER",
    "args": ["npx", "-y", "ollama-mcp-server"]
  },
  $RANGE_INTEL_JSON,
  $OUTLINE_JSON,
  $TUONI_MCP_JSON,
  "cve-mcp": {
    "command": "$WRAPPER",
    "args": ["npx", "-y", "cve-mcp@0.2.0"]
  },
  "nuclei-mcp": {
    "command": "$WRAPPER",
    "args": ["nuclei-mcp"],
    "env": {
      "NUCLEI_MCP_SERVER_PORT": "0"
    }
  },
  "bloodhound-mcp": {
    "command": "$WRAPPER",
    "args": ["$PYTHON_CMD", "BloodHound-MCP.py"],
    "cwd": "$PROJECT_DIR/mcp-servers/bloodhound-mcp"
  },
  "hashcat-mcp": {
    "command": "$WRAPPER",
    "args": ["$PYTHON_CMD", "$PROJECT_DIR/mcp-servers/.venv/share/hashcat-mcp/hashcat_mcp_server.py"],
    "env": {
      "HASHCAT_MODES_CSV": "$PROJECT_DIR/mcp-servers/.venv/share/hashcat-mcp/hashcat_modes.csv"
    }
  }
}
CATALOG_JSON

# --- Mode manifests ---
# Each mode lists which catalog servers it needs. Servers not in the catalog
# are silently skipped (forward-compatible with planned servers like eip-mcp).
# "all" is a special pseudo-mode that includes every server.
declare -A MODE_SERVERS
MODE_SERVERS[all]="obsidian-mcp rea-mcp hacktricks-mcp mitre-mcp lolbins-mcp cve-mcp nuclei-mcp local-ollama range-intel outline-readonly tuoni-mcp bloodhound-mcp hashcat-mcp"
MODE_SERVERS[platform-ops]="local-ollama"
MODE_SERVERS[red-team]="tuoni-mcp range-intel outline-readonly obsidian-mcp hacktricks-mcp mitre-mcp lolbins-mcp cve-mcp nuclei-mcp bloodhound-mcp hashcat-mcp"
MODE_SERVERS[red-dev]="tuoni-mcp rea-mcp hacktricks-mcp mitre-mcp obsidian-mcp lolbins-mcp cve-mcp bloodhound-mcp hashcat-mcp"
MODE_SERVERS[green-dev]="range-intel outline-readonly"
MODE_SERVERS[purple]="tuoni-mcp range-intel outline-readonly obsidian-mcp hacktricks-mcp mitre-mcp lolbins-mcp cve-mcp nuclei-mcp bloodhound-mcp hashcat-mcp"

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
