#!/usr/bin/env bash
# install-nuclei-mcp.sh — install Nuclei MCP server in orchestrator.
#
# Nuclei MCP wraps the Nuclei scanner for template-filtered vuln scanning
# with structured JSON output. MCP server runs locally; nuclei runs on
# Kali spoke.
#
# Requires: Go (for building from source) OR npm
#
# Usage:
#   bash scripts/install-nuclei-mcp.sh              # install
#   bash scripts/install-nuclei-mcp.sh --check-only  # verify installed
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/load-env.sh"

NUCLEI_MCP_REPO="${NUCLEI_MCP_REPO:-mark3labs/nuclei-mcp}"
NUCLEI_MCP_REF="${NUCLEI_MCP_REF:-main}"
MARKER_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
MARKER_FILE="$MARKER_DIR/.template-nuclei-mcp-ref"
INSTALL_DIR="${NUCLEI_MCP_DIR:-/workspace/.cache/nuclei-mcp}"
mkdir -p "$MARKER_DIR"

CHECK_ONLY=false
[[ "${1:-}" == "--check-only" ]] && CHECK_ONLY=true

if [[ "$CHECK_ONLY" == true ]]; then
    if [[ -x "$INSTALL_DIR/nuclei-mcp" ]] || command -v nuclei-mcp >/dev/null 2>&1; then
        echo "OK: Nuclei MCP installed"
        [[ -f "$MARKER_FILE" ]] && echo "  Ref: $(cat "$MARKER_FILE")"
    else
        echo "MISSING: Nuclei MCP not installed"
        exit 1
    fi

    echo ""
    echo "Nuclei on Kali check:"
    if [[ -n "${SPOKE_KALI_HOST:-}" ]]; then
        if ssh -o ConnectTimeout=5 -o BatchMode=yes kali "command -v nuclei" >/dev/null 2>&1; then
            nuclei_ver=$(ssh -o ConnectTimeout=5 kali "nuclei -version 2>&1 | head -1" 2>/dev/null)
            echo "  OK: $nuclei_ver"
            template_count=$(ssh -o ConnectTimeout=5 kali "ls -d /root/nuclei-templates/*/ 2>/dev/null | wc -l" 2>/dev/null)
            echo "  Templates: $template_count categories"
        else
            echo "  WARN: nuclei not found on Kali"
        fi
    else
        echo "  WARN: SPOKE_KALI_HOST not set"
    fi
    exit 0
fi

if [[ "${NUCLEI_MCP_FORCE:-0}" != "1" ]] \
  && [[ -f "$MARKER_FILE" ]] && grep -q "^${NUCLEI_MCP_REF}$" "$MARKER_FILE"; then
    echo "Nuclei MCP already installed at ref ${NUCLEI_MCP_REF}."
    exit 0
fi

echo "Installing Nuclei MCP from ${NUCLEI_MCP_REPO}@${NUCLEI_MCP_REF}..."

mkdir -p "$INSTALL_DIR"

if command -v go >/dev/null 2>&1; then
    echo "Building from source (Go)..."
    if git clone --depth 1 --branch "$NUCLEI_MCP_REF" \
        "https://github.com/${NUCLEI_MCP_REPO}.git" "$INSTALL_DIR/src" 2>&1; then
        cd "$INSTALL_DIR/src"
        if go build -o "$INSTALL_DIR/nuclei-mcp" . 2>&1; then
            echo "$NUCLEI_MCP_REF" > "$MARKER_FILE"
            echo "Nuclei MCP built successfully: $INSTALL_DIR/nuclei-mcp"
        else
            echo "WARN: Go build failed."
            exit 1
        fi
    else
        echo "WARN: Clone failed."
        exit 1
    fi
else
    echo "WARN: Go not available. Nuclei MCP needs Go to build from source."
    echo "  Install Go: apt install -y golang-go"
    echo "  Or pre-build binary and place at: $INSTALL_DIR/nuclei-mcp"
    exit 1
fi

echo ""
echo "NOTE: Nuclei must be installed on Kali spoke with templates."
echo "  Install: apt install nuclei && nuclei -update-templates"
