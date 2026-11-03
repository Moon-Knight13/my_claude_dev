#!/usr/bin/env bash
# setup-mcp-servers.sh — generate .mcp.json for Claude Code MCP server registration.
#
# Claude Code reads MCP servers from .mcp.json (not .claude/settings.json).
# This script writes .mcp.json with all project MCP servers. ALL servers are
# launched through mcp-wrapper.sh so .env vars flow consistently — no stale
# baked-in values from heredoc expansion.
#
# Idempotent: overwrites .mcp.json each run. .mcp.json is gitignored.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MCP_FILE="$PROJECT_DIR/.mcp.json"

# Quoted heredoc — no shell expansion. All dynamic vars flow through
# mcp-wrapper.sh -> load-env.sh at server start time, not generation time.
cat > "$MCP_FILE" << 'ENDOFMCP'
{
  "mcpServers": {
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
      "args": ["npx", "-y", "hacktricks-mcp@1.3.0"]
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
}
ENDOFMCP

echo "Generated $MCP_FILE with $(python3 -I -c "import json; print(len(json.load(open('$MCP_FILE'))['mcpServers']))" 2>/dev/null || echo '?') MCP servers"
