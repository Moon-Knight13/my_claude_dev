#!/usr/bin/env bash
# Install and configure rea-mcp (morluto/rea) for reverse engineering.
# Idempotent — skips steps already done.
#
# REA provides 170+ MCP tools for RE: native binaries (Ghidra/IDA backend),
# .NET, APK, Electron, firmware, pcaps. Static JS analysis needs no backend.
#
# Usage:
#   bash scripts/install-rea-mcp.sh          # install + configure MCP
#   bash scripts/install-rea-mcp.sh --check  # check only, no changes
set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────
REA_VERSION="6.8.0"
REA_PACKAGE="rea-agents@${REA_VERSION}"
MIN_NODE_MAJOR=22

# ── Helpers ───────────────────────────────────────────────────────────────
readonly RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' NC='\033[0m'
pass() { printf "${GREEN}PASS${NC}  %s\n" "$*"; }
warn() { printf "${YELLOW}WARN${NC}  %s\n" "$*"; }
fail() { printf "${RED}FAIL${NC}  %s\n" "$*"; }

check_only=false
[[ "${1:-}" == "--check" ]] && check_only=true

# ── Preflight ─────────────────────────────────────────────────────────────
echo "=== rea-mcp preflight ==="

# Node.js version
if command -v node >/dev/null 2>&1; then
    node_ver=$(node --version | sed 's/^v//')
    node_major=${node_ver%%.*}
    if (( node_major >= MIN_NODE_MAJOR )); then
        pass "Node.js ${node_ver} (>= ${MIN_NODE_MAJOR}.x)"
    else
        fail "Node.js ${node_ver} — need >= ${MIN_NODE_MAJOR}.x"
        exit 1
    fi
else
    fail "Node.js not found"
    exit 1
fi

# npm
if command -v npm >/dev/null 2>&1; then
    pass "npm $(npm --version)"
else
    fail "npm not found"
    exit 1
fi

# RE backends (optional — static JS analysis works without these)
ghidra_found=false
if command -v ghidra >/dev/null 2>&1 || command -v ghidraRun >/dev/null 2>&1; then
    pass "Ghidra found"
    ghidra_found=true
elif [[ -d "/opt/ghidra" ]] || [[ -d "${HOME}/ghidra" ]]; then
    pass "Ghidra directory found"
    ghidra_found=true
else
    warn "Ghidra not found — native binary analysis unavailable"
fi

if command -v r2 >/dev/null 2>&1; then
    pass "radare2 found"
else
    warn "radare2 not found — r2 analysis unavailable"
fi

# Check if rea-agents is already installed
if npm list -g rea-agents >/dev/null 2>&1; then
    installed_ver=$(npm list -g rea-agents --depth=0 2>/dev/null | grep rea-agents | sed 's/.*@//')
    if [[ "$installed_ver" == "$REA_VERSION" ]]; then
        pass "rea-agents@${REA_VERSION} already installed globally"
    else
        warn "rea-agents@${installed_ver} installed, want ${REA_VERSION}"
    fi
else
    warn "rea-agents not installed globally (will use npx)"
fi

if $check_only; then
    echo ""
    echo "Check complete. Run without --check to install."
    exit 0
fi

# ── Install ───────────────────────────────────────────────────────────────
echo ""
echo "=== Installing rea-mcp ==="

# MCP config goes in project settings. npx handles on-demand install so
# no global install required — but it does keep a launcher process per
# MCP connection. For concurrent sessions, global install is better.
SETTINGS_FILE="${CLAUDE_PROJECT_DIR:-.}/.claude/settings.json"

if [[ ! -f "$SETTINGS_FILE" ]]; then
    fail "Settings file not found: ${SETTINGS_FILE}"
    exit 1
fi

# Check if rea-mcp is already configured
if grep -q '"rea-mcp"' "$SETTINGS_FILE" 2>/dev/null; then
    pass "rea-mcp already in ${SETTINGS_FILE}"
else
    echo "Adding rea-mcp to ${SETTINGS_FILE}..."

    # Use node to safely merge JSON (jq may not be available)
    node -e "
const fs = require('fs');
const settings = JSON.parse(fs.readFileSync('$SETTINGS_FILE', 'utf8'));
if (!settings.mcpServers) settings.mcpServers = {};
settings.mcpServers['rea-mcp'] = {
    command: 'npx',
    args: ['-y', '${REA_PACKAGE}', 'mcp']
};
fs.writeFileSync('$SETTINGS_FILE', JSON.stringify(settings, null, 2) + '\n');
"
    pass "rea-mcp added to ${SETTINGS_FILE}"
fi

echo ""
echo "=== rea-mcp install complete ==="
echo ""
echo "Restart Claude Code to load new MCP tools."
if ! $ghidra_found; then
    echo "Note: install Ghidra for native binary analysis."
    echo "  Static JS/Electron/APK analysis works without it."
fi
