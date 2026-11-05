#!/usr/bin/env bash
# host-setup.sh — provision MCP servers on bare host (outside devcontainer).
#
# Equivalent of post-start.sh for host usage. Creates a shared Python venv,
# installs Python-based MCPs, and regenerates .mcp.json with correct paths.
#
# Prerequisites: python3, python3-venv (e.g. apt install python3.14-venv), git
#
# Usage:
#   bash scripts/host-setup.sh          # full setup
#   bash scripts/host-setup.sh --force  # force reinstall (bypass markers)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ "${DEVCONTAINER:-}" == "true" ]]; then
    echo "Running inside devcontainer — use post-start.sh instead."
    exit 1
fi

# --- Prerequisites ---
missing=()
command -v python3 >/dev/null 2>&1 || missing+=("python3")
command -v git >/dev/null 2>&1 || missing+=("git")
command -v node >/dev/null 2>&1 || missing+=("node (for npx-based MCPs)")

if (( ${#missing[@]} > 0 )); then
    echo "Missing prerequisites: ${missing[*]}"
    exit 1
fi

# Check python3-venv availability
if ! python3 -m venv --help >/dev/null 2>&1; then
    PY_VER=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
    echo "python3-venv not available. Install it:"
    echo "  sudo apt install python${PY_VER}-venv"
    exit 1
fi

# --- Parse args ---
FORCE_FLAG=""
if [[ "${1:-}" == "--force" ]]; then
    FORCE_FLAG="1"
fi

echo "Host setup for $(basename "$PROJECT_DIR")..."

# --- MCP Python servers ---
export TUONI_MCP_FORCE="${FORCE_FLAG:-0}"
echo ""
echo "── Python MCP servers ──"
bash "$SCRIPT_DIR/install-tuoni-mcp.sh"

# --- Regenerate .mcp.json ---
echo ""
echo "── MCP server config ──"
bash "$SCRIPT_DIR/setup-mcp-servers.sh"

# --- NPM-based MCPs (pre-install packages without bin entries) ---
echo ""
echo "── NPM MCP packages ──"
MCP_PKG_DIR="$PROJECT_DIR/.mcp-packages"
if [ ! -d "$MCP_PKG_DIR/node_modules/hacktricks-mcp" ]; then
    echo "Installing hacktricks-mcp..."
    npm install --prefix "$MCP_PKG_DIR" hacktricks-mcp@1.3.0 --silent 2>&1 || echo "WARN: hacktricks-mcp install failed"
else
    echo "hacktricks-mcp already installed."
fi

# --- Summary ---
echo ""
VENV_DIR="$PROJECT_DIR/mcp-servers/.venv"
if [[ -d "$VENV_DIR" ]]; then
    PKG_COUNT=$("$VENV_DIR/bin/pip" list --format=columns 2>/dev/null | tail -n +3 | wc -l)
    echo "Python venv: $VENV_DIR ($PKG_COUNT packages)"
fi

MCP_COUNT=$(python3 -c "import json; print(len(json.load(open('$PROJECT_DIR/.mcp.json'))['mcpServers']))" 2>/dev/null || echo '?')
echo "MCP config: .mcp.json ($MCP_COUNT servers)"
echo ""
echo "Host setup complete. Restart Claude Code to reconnect MCP servers."
