#!/usr/bin/env bash
# Install and configure ghidra-mcp (bethington/ghidra-mcp) for Ghidra-backed RE analysis.
# Idempotent — skips steps already done. Requires Ghidra backend (install-ghidra-backend.sh).
#
# ghidra-mcp exposes Ghidra's headless analysis as an MCP server: decompilation,
# function listing, xrefs, class hierarchy, memory mapping, and symbol search.
# Python-based; uses the shared MCP venv.
#
# Usage:
#   bash scripts/install-ghidra-mcp.sh          # install + configure MCP
#   bash scripts/install-ghidra-mcp.sh --check  # check only, no changes
set -euo pipefail

# shellcheck source=scripts/lib/subsystems.sh disable=SC1090,SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/subsystems.sh"

if ! subsystem_enabled ghidra; then
  subsystem_skip_notice ghidra "GhidraMCP install"
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

GHIDRA_MCP_REPO="${GHIDRA_MCP_REPO:-bethington/ghidra-mcp}"
GHIDRA_MCP_REF="${GHIDRA_MCP_REF:-main}"
GHIDRA_MCP_DIR="$PROJECT_DIR/mcp-servers/ghidra-mcp"
MARKER_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
MARKER_FILE="$MARKER_DIR/.template-ghidra-mcp-ref"
mkdir -p "$MARKER_DIR"

# ── Helpers ───────────────────────────────────────────────────────────────
readonly RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' NC='\033[0m'
pass() { printf "${GREEN}PASS${NC}  %s\n" "$*"; }
warn() { printf "${YELLOW}WARN${NC}  %s\n" "$*"; }
fail() { printf "${RED}FAIL${NC}  %s\n" "$*"; }

check_only=false
[[ "${1:-}" == "--check" ]] && check_only=true

# ── Preflight ─────────────────────────────────────────────────────────────
echo "=== ghidra-mcp preflight ==="

# Python
if command -v python3 >/dev/null 2>&1; then
    py_ver=$(python3 --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
    pass "Python ${py_ver}"
else
    fail "python3 not found — required for ghidra-mcp"
    exit 1
fi

# Ghidra backend
if [[ -d "${GHIDRA_INSTALL_DIR:-}" ]] && [[ -f "${GHIDRA_INSTALL_DIR}/support/analyzeHeadless" ]]; then
    pass "Ghidra at ${GHIDRA_INSTALL_DIR}"
else
    warn "Ghidra not found at ${GHIDRA_INSTALL_DIR:-<unset>}"
    warn "Run: bash scripts/install-ghidra-backend.sh"
    if $check_only; then
        echo ""
        echo "Check complete. Ghidra backend required before install."
        exit 1
    fi
fi

# JDK
if [[ -d "${JAVA_HOME:-}" ]] && "${JAVA_HOME}/bin/java" -version >/dev/null 2>&1; then
    pass "JDK at ${JAVA_HOME}"
else
    warn "JDK not found at ${JAVA_HOME:-<unset>} — Ghidra headless will fail"
fi

# Check if already installed at target ref
if [[ "${GHIDRA_MCP_FORCE:-0}" != "1" ]] \
  && [[ -f "$MARKER_FILE" ]] && grep -q "^${GHIDRA_MCP_REF}$" "$MARKER_FILE"; then
    pass "ghidra-mcp already installed at ref ${GHIDRA_MCP_REF}"
    if $check_only; then
        echo ""
        echo "Check complete."
    fi
    exit 0
fi

if $check_only; then
    echo ""
    echo "Check complete. Run without --check to install."
    exit 0
fi

# ── Shared venv ──────────────────────────────────────────────────────────
VENV_DIR="$PROJECT_DIR/mcp-servers/.venv"

if [[ "${DEVCONTAINER:-}" == "true" ]]; then
    if ! command -v pip >/dev/null 2>&1 && ! command -v pip3 >/dev/null 2>&1; then
        fail "pip not found; cannot install ghidra-mcp."
        exit 1
    fi
    PIP_CMD="pip3"
    command -v pip >/dev/null 2>&1 && PIP_CMD="pip"
    PIP_ARGS="--break-system-packages"
    PYTHON_CMD="python3"
else
    if [[ ! -d "$VENV_DIR" ]]; then
        echo "Creating shared MCP venv at $VENV_DIR..."
        python3 -m venv "$VENV_DIR"
    fi
    PIP_CMD="$VENV_DIR/bin/pip"
    PIP_ARGS=""
    PYTHON_CMD="$VENV_DIR/bin/python3"
fi

# ── Clone or update repo ────────────────────────────────────────────────
echo ""
echo "=== Installing ghidra-mcp ==="

if [[ -d "$GHIDRA_MCP_DIR/.git" ]]; then
    echo "Updating ghidra-mcp repo..."
    git -C "$GHIDRA_MCP_DIR" fetch origin
    git -C "$GHIDRA_MCP_DIR" checkout "$GHIDRA_MCP_REF"
    git -C "$GHIDRA_MCP_DIR" pull origin "$GHIDRA_MCP_REF" 2>/dev/null || true
else
    echo "Cloning ghidra-mcp from ${GHIDRA_MCP_REPO}@${GHIDRA_MCP_REF}..."
    rm -rf "$GHIDRA_MCP_DIR"
    git clone --depth 1 --branch "$GHIDRA_MCP_REF" \
        "https://github.com/${GHIDRA_MCP_REPO}.git" "$GHIDRA_MCP_DIR"
fi

test -f "$GHIDRA_MCP_DIR/server.py" || { fail "entry point server.py not found in ${GHIDRA_MCP_DIR}"; exit 1; }

# ── Install dependencies ────────────────────────────────────────────────
if [[ -f "$GHIDRA_MCP_DIR/requirements.txt" ]]; then
    echo "Installing ghidra-mcp dependencies..."
    # shellcheck disable=SC2086
    $PIP_CMD install $PIP_ARGS -r "$GHIDRA_MCP_DIR/requirements.txt" 2>&1 || {
        fail "ghidra-mcp dependency install failed"
        exit 1
    }
elif [[ -f "$GHIDRA_MCP_DIR/pyproject.toml" ]]; then
    echo "Installing ghidra-mcp from pyproject.toml..."
    # shellcheck disable=SC2086
    $PIP_CMD install $PIP_ARGS "$GHIDRA_MCP_DIR" 2>&1 || {
        fail "ghidra-mcp install failed"
        exit 1
    }
fi

# Verify the server module is importable
if $PYTHON_CMD -c "import ghidra_mcp_server; print('ghidra-mcp import OK')" 2>/dev/null; then
    pass "ghidra-mcp module importable"
elif $PYTHON_CMD -c "import ghidra_mcp; print('ghidra-mcp import OK')" 2>/dev/null; then
    pass "ghidra-mcp module importable"
else
    warn "ghidra-mcp module not directly importable — server may use script entry point"
fi

# ── MCP config ───────────────────────────────────────────────────────────
MCP_FILE="$PROJECT_DIR/.mcp.json"

if [[ ! -f "$MCP_FILE" ]]; then
    fail ".mcp.json not found at ${MCP_FILE}"
    exit 1
fi

if grep -q '"ghidra-mcp"' "$MCP_FILE" 2>/dev/null; then
    pass "ghidra-mcp already in .mcp.json"
else
    echo "Adding ghidra-mcp to .mcp.json..."
    python3 -I -c "
import json, os
mcp_file = '$MCP_FILE'
wrapper = '$PROJECT_DIR/scripts/mcp-wrapper.sh'
ghidra_dir = '$GHIDRA_MCP_DIR'
python_cmd = '$PYTHON_CMD'
with open(mcp_file) as f:
    cfg = json.load(f)
cfg['mcpServers']['ghidra-mcp'] = {
    'command': wrapper,
    'args': [python_cmd, os.path.join(ghidra_dir, 'server.py')],
    'cwd': ghidra_dir,
    'env': {
        'GHIDRA_INSTALL_DIR': os.environ.get('GHIDRA_INSTALL_DIR', ''),
        'JAVA_HOME': os.environ.get('JAVA_HOME', ''),
    }
}
with open(mcp_file, 'w') as f:
    json.dump(cfg, f, indent=2)
    f.write('\n')
"
    pass "ghidra-mcp added to .mcp.json"
fi

# ── Marker ───────────────────────────────────────────────────────────────
echo "$GHIDRA_MCP_REF" > "$MARKER_FILE"

echo ""
echo "=== ghidra-mcp install complete (${GHIDRA_MCP_REPO}@${GHIDRA_MCP_REF}) ==="
echo ""
echo "Prerequisites:"
echo "  - Ghidra backend: bash scripts/install-ghidra-backend.sh"
echo "  - GHIDRA_INSTALL_DIR and JAVA_HOME must be set in .env or shell profile"
echo ""
echo "Restart Claude Code to load new MCP tools."
