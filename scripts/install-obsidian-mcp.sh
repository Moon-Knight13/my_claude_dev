#!/usr/bin/env bash
# Install and configure obsidian-mcp (StevenStavrakis/obsidian-mcp) for
# filesystem-based vault access. No Obsidian REST API needed — reads/writes
# markdown files directly.
#
# Usage:
#   bash scripts/install-obsidian-mcp.sh          # install + configure
#   bash scripts/install-obsidian-mcp.sh --check  # check only
set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────
OBSIDIAN_MCP_VERSION="2.0.1"
OBSIDIAN_MCP_PACKAGE="obsidian-mcp@${OBSIDIAN_MCP_VERSION}"
VAULT_PATH="${OBSIDIAN_VAULT_CONTAINER_PATH:-/home/node/vault}"
MIN_NODE_MAJOR=22

# ── Helpers ───────────────────────────────────────────────────────────────
readonly RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' NC='\033[0m'
pass() { printf "${GREEN}PASS${NC}  %s\n" "$*"; }
warn() { printf "${YELLOW}WARN${NC}  %s\n" "$*"; }
fail() { printf "${RED}FAIL${NC}  %s\n" "$*"; }

check_only=false
[[ "${1:-}" == "--check" ]] && check_only=true

# ── Preflight ─────────────────────────────────────────────────────────────
echo "=== obsidian-mcp preflight ==="

# Node.js
if command -v node >/dev/null 2>&1; then
    node_ver=$(node --version | sed 's/^v//')
    node_major=${node_ver%%.*}
    if (( node_major >= MIN_NODE_MAJOR )); then
        pass "Node.js ${node_ver}"
    else
        fail "Node.js ${node_ver} — need >= ${MIN_NODE_MAJOR}.x"
        exit 1
    fi
else
    fail "Node.js not found"
    exit 1
fi

# Vault mount
if [[ -d "$VAULT_PATH" ]]; then
    pass "Vault mounted at ${VAULT_PATH}"
    if [[ -d "${VAULT_PATH}/.obsidian" ]]; then
        pass "Vault has .obsidian directory"
    else
        warn "No .obsidian directory — creating minimal one"
        if ! $check_only; then
            mkdir -p "${VAULT_PATH}/.obsidian"
        fi
    fi
    # Write test
    if touch "${VAULT_PATH}/.write-test" 2>/dev/null; then
        rm -f "${VAULT_PATH}/.write-test"
        pass "Vault is writable"
    else
        warn "Vault is read-only — LLM Wiki write disabled"
        warn "Remove 'readonly' from devcontainer.json mount for write access"
    fi
else
    warn "Vault not mounted at ${VAULT_PATH}"
    warn "Set OBSIDIAN_VAULT_PATH in .env and rebuild devcontainer"
fi

if $check_only; then
    echo ""
    echo "Check complete."
    exit 0
fi

# ── Wiki Structure ────────────────────────────────────────────────────────
if [[ -d "$VAULT_PATH" ]]; then
    echo ""
    echo "=== Initializing LLM Wiki structure ==="
    bash "$(dirname "${BASH_SOURCE[0]}")/init-wiki-structure.sh" "$VAULT_PATH"
fi

# ── MCP Config ────────────────────────────────────────────────────────────
echo ""
echo "=== Configuring obsidian-mcp ==="

SETTINGS_FILE="${CLAUDE_PROJECT_DIR:-.}/.claude/settings.json"
if [[ ! -f "$SETTINGS_FILE" ]]; then
    fail "Settings file not found: ${SETTINGS_FILE}"
    exit 1
fi

if grep -q '"obsidian-mcp"' "$SETTINGS_FILE" 2>/dev/null; then
    pass "obsidian-mcp already in ${SETTINGS_FILE}"
else
    echo "Adding obsidian-mcp to ${SETTINGS_FILE}..."
    node -e "
const fs = require('fs');
const settings = JSON.parse(fs.readFileSync('$SETTINGS_FILE', 'utf8'));
if (!settings.mcpServers) settings.mcpServers = {};
settings.mcpServers['obsidian-mcp'] = {
    command: 'npx',
    args: ['-y', '${OBSIDIAN_MCP_PACKAGE}', 'serve', '--vault', '${VAULT_PATH}']
};
fs.writeFileSync('$SETTINGS_FILE', JSON.stringify(settings, null, 2) + '\n');
"
    pass "obsidian-mcp added to ${SETTINGS_FILE}"
fi

echo ""
echo "=== obsidian-mcp install complete ==="
echo "Restart Claude Code to load Obsidian tools."
