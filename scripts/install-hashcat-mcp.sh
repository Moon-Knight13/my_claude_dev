#!/usr/bin/env bash
# Install and configure hashcat-mcp (MorDavid/Hashcat-MCP) for automated
# hash cracking orchestration.
# Idempotent — skips steps already done.
#
# The MCP wraps hashcat CLI on Kali and exposes tools for hash identification,
# auto_attack_strategy, session management, and credential analysis.
# Feeds cred-harvest skill post-dump phase.
#
# Usage:
#   bash scripts/install-hashcat-mcp.sh          # install + configure MCP
#   bash scripts/install-hashcat-mcp.sh --check  # check only, no changes
set -euo pipefail

# shellcheck source=scripts/lib/subsystems.sh disable=SC1090,SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/subsystems.sh"

if ! subsystem_enabled hashcat; then
  subsystem_skip_notice hashcat "Hashcat MCP install"
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

HASHCAT_MCP_REPO="${HASHCAT_MCP_REPO:-MorDavid/Hashcat-MCP}"
HASHCAT_MCP_REF="${HASHCAT_MCP_REF:-main}"
MARKER_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
MARKER_FILE="$MARKER_DIR/.template-hashcat-mcp-ref"
mkdir -p "$MARKER_DIR"

# ── Helpers ──────────────────────────────────────────────────────────────
readonly RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' NC='\033[0m'
pass() { printf "${GREEN}PASS${NC}  %s\n" "$*"; }
warn() { printf "${YELLOW}WARN${NC}  %s\n" "$*"; }
fail() { printf "${RED}FAIL${NC}  %s\n" "$*"; }

check_only=false
[[ "${1:-}" == "--check" ]] && check_only=true

# ── Preflight ────────────────────────────────────────────────────────────
echo "=== hashcat-mcp preflight ==="

# Python
if command -v python3 >/dev/null 2>&1; then
    py_ver=$(python3 --version 2>&1 | sed 's/Python //')
    pass "Python ${py_ver}"
else
    fail "python3 not found"
    exit 1
fi

# pip availability (checked later via venv)
VENV_DIR="$PROJECT_DIR/mcp-servers/.venv"
if [[ -d "$VENV_DIR" ]]; then
    pass "Shared MCP venv exists at $VENV_DIR"
else
    warn "Shared MCP venv not found — will create"
fi

# hashcat binary (only meaningful on Kali spoke — optional here)
if command -v hashcat >/dev/null 2>&1; then
    hc_ver=$(hashcat --version 2>/dev/null || echo "unknown")
    pass "hashcat ${hc_ver} found locally"
else
    warn "hashcat not found locally — expected on Kali spoke only"
fi

# Ref marker (idempotency)
if [[ "${HASHCAT_MCP_FORCE:-0}" != "1" ]] \
  && [[ -f "$MARKER_FILE" ]] && grep -q "^${HASHCAT_MCP_REF}$" "$MARKER_FILE"; then
    pass "Hashcat MCP already installed at ref ${HASHCAT_MCP_REF}"
    if $check_only; then
        echo ""
        echo "Check complete (already installed)."
    fi
    exit 0
fi

if $check_only; then
    echo ""
    echo "Check complete. Run without --check to install."
    exit 0
fi

# ── Install ──────────────────────────────────────────────────────────────
echo ""
echo "=== Installing hashcat-mcp ==="

# Ensure shared venv exists
if [[ ! -d "$VENV_DIR" ]]; then
    echo "Creating shared MCP venv at $VENV_DIR..."
    python3 -m venv "$VENV_DIR"
fi

PIP_CMD="$VENV_DIR/bin/pip"
PYTHON_CMD="$VENV_DIR/bin/python3"

if [[ "${DEVCONTAINER:-}" == "true" ]]; then
    if ! command -v pip >/dev/null 2>&1 && ! command -v pip3 >/dev/null 2>&1; then
        echo "WARN: pip not found; skipping Hashcat MCP install."
        exit 0
    fi
    PIP_CMD="pip3"
    command -v pip >/dev/null 2>&1 && PIP_CMD="pip"
    PIP_ARGS="--break-system-packages --force-reinstall"
    PYTHON_CMD="python3"
else
    PIP_ARGS="--force-reinstall"
fi

echo "Installing Hashcat MCP from ${HASHCAT_MCP_REPO}@${HASHCAT_MCP_REF}..."
# shellcheck disable=SC2086
if ! $PIP_CMD install $PIP_ARGS \
    "git+https://github.com/${HASHCAT_MCP_REPO}.git@${HASHCAT_MCP_REF}" 2>&1; then
    # Fallback: clone and install from source (repo may not have setup.py/pyproject.toml)
    echo "pip install failed — trying clone + requirements install..."
    CLONE_DIR=$(mktemp -d)
    trap 'rm -rf "$CLONE_DIR"' EXIT
    if git clone --depth 1 --branch "$HASHCAT_MCP_REF" \
        "https://github.com/${HASHCAT_MCP_REPO}.git" "$CLONE_DIR" 2>&1; then

        if [[ -f "$CLONE_DIR/requirements.txt" ]]; then
            # shellcheck disable=SC2086
            $PIP_CMD install $PIP_ARGS -r "$CLONE_DIR/requirements.txt" 2>&1 || true
        fi

        # Install server file + modes CSV into venv share dir
        SHARE_DIR="$VENV_DIR/share/hashcat-mcp"
        mkdir -p "$SHARE_DIR"
        cp "$CLONE_DIR/hashcat_mcp_server.py" "$SHARE_DIR/"
        [[ -f "$CLONE_DIR/hashcat_modes.csv" ]] && cp "$CLONE_DIR/hashcat_modes.csv" "$SHARE_DIR/"
        pass "Hashcat MCP installed from source to $SHARE_DIR"
    else
        echo "WARN: Hashcat MCP clone failed; continuing without it."
        exit 0
    fi
fi

# Verify fastmcp import (the core dependency)
if ! $PYTHON_CMD -c "from mcp.server.fastmcp import FastMCP; print('OK')" 2>/dev/null; then
    echo "WARN: fastmcp not importable after install."
    exit 0
fi

echo "$HASHCAT_MCP_REF" > "$MARKER_FILE"
echo ""
echo "=== hashcat-mcp install complete (${HASHCAT_MCP_REPO}@${HASHCAT_MCP_REF}) ==="
echo ""
echo "Configure HASHCAT_PATH in .env on the Kali spoke where hashcat runs."
echo "Restart Claude Code to load new MCP tools."
