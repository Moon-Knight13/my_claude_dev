#!/usr/bin/env bash
# setup-mcp-servers.sh — generate .mcp.json for Claude Code MCP server registration.
#
# Claude Code reads MCP servers from .mcp.json (not .claude/settings.json).
# This script writes .mcp.json with all project MCP servers. Env vars for
# range-connected servers flow through mcp-wrapper.sh (sources load-env.sh).
#
# Idempotent: overwrites .mcp.json each run. .mcp.json is gitignored.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=scripts/lib/load-env.sh
source "$SCRIPT_DIR/lib/load-env.sh"

MCP_FILE="$PROJECT_DIR/.mcp.json"

# Ghidra paths (set by rea-mcp installer if present)
GHIDRA_DIR="${GHIDRA_INSTALL_DIR:-/home/node/.local/share/ghidra/ghidra_12.1.4_PUBLIC}"
GHIDRA_JAVA="${JAVA_HOME:-/home/node/.local/share/ghidra/jdk-21.0.7+6}"

# Base servers (always registered)
cat > "$MCP_FILE" << ENDOFMCP
{
  "mcpServers": {
    "obsidian-mcp": {
      "command": "npx",
      "args": ["-y", "obsidian-mcp@2.0.1", "serve", "--vault", "my_notes=/home/node/vault"]
    },
    "rea-mcp": {
      "command": "npx",
      "args": ["-y", "rea-agents@6.8.0", "mcp"],
      "env": {
        "GHIDRA_INSTALL_DIR": "${GHIDRA_DIR}",
        "JAVA_HOME": "${GHIDRA_JAVA}"
      }
    },
    "hacktricks-mcp": {
      "command": "npx",
      "args": ["-y", "hacktricks-mcp@1.3.0"]
    },
    "mitre-mcp": {
      "command": "npx",
      "args": ["-y", "mitre-attack-mcp@1.0.1"]
    },
    "lolbins-mcp": {
      "command": "npx",
      "args": ["-y", "living-off-the-land-lolbins-mcp-server@0.1.0"]
    },
    "local-ollama": {
      "command": "npx",
      "args": ["-y", "ollama-mcp-server"],
      "env": {
        "OLLAMA_HOST": "http://host.docker.internal:11434",
        "OLLAMA_MODEL": "${LOCAL_MODEL_MODEL:-qwen2.5-coder:7b}"
      }
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
}
ENDOFMCP

echo "Generated $MCP_FILE with $(python3 -I -c "import json; print(len(json.load(open('$MCP_FILE'))['mcpServers']))" 2>/dev/null || echo '?') MCP servers"
