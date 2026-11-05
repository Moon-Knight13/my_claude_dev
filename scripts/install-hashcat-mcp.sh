#!/usr/bin/env bash
# install-hashcat-mcp.sh — install Hashcat MCP server in orchestrator.
#
# Hashcat MCP wraps hashcat CLI for automated crack strategy selection.
# MCP server runs locally; hashcat runs on Kali spoke via SSH.
#
# Requires: pip3
#
# Usage:
#   bash scripts/install-hashcat-mcp.sh              # install
#   bash scripts/install-hashcat-mcp.sh --check-only  # verify installed
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/load-env.sh"

HC_MCP_REPO="${HC_MCP_REPO:-MorDavid/Hashcat-MCP}"
HC_MCP_REF="${HC_MCP_REF:-main}"
MARKER_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
MARKER_FILE="$MARKER_DIR/.template-hashcat-mcp-ref"
mkdir -p "$MARKER_DIR"

CHECK_ONLY=false
[[ "${1:-}" == "--check-only" ]] && CHECK_ONLY=true

if [[ "$CHECK_ONLY" == true ]]; then
    if python3 -I -c "import hashcat_mcp" 2>/dev/null; then
        echo "OK: Hashcat MCP installed"
        [[ -f "$MARKER_FILE" ]] && echo "  Ref: $(cat "$MARKER_FILE")"
    else
        echo "MISSING: Hashcat MCP not installed"
        exit 1
    fi

    echo ""
    echo "Hashcat on Kali check:"
    if [[ -n "${SPOKE_KALI_HOST:-}" ]]; then
        if ssh -o ConnectTimeout=5 -o BatchMode=yes kali "command -v hashcat" >/dev/null 2>&1; then
            echo "  OK: hashcat found on Kali"
            gpu_info=$(ssh -o ConnectTimeout=5 kali "hashcat -I 2>/dev/null | head -5 || echo 'no GPU info'" 2>/dev/null)
            echo "  GPU: $gpu_info"
        else
            echo "  WARN: hashcat not found on Kali"
        fi
    else
        echo "  WARN: SPOKE_KALI_HOST not set"
    fi
    exit 0
fi

if [[ "${HC_MCP_FORCE:-0}" != "1" ]] \
  && [[ -f "$MARKER_FILE" ]] && grep -q "^${HC_MCP_REF}$" "$MARKER_FILE"; then
    echo "Hashcat MCP already installed at ref ${HC_MCP_REF}."
    exit 0
fi

PIP_CMD="pip3"
command -v pip3 >/dev/null 2>&1 || PIP_CMD="pip"

if ! command -v "$PIP_CMD" >/dev/null 2>&1; then
    echo "WARN: pip not found; skipping Hashcat MCP install."
    exit 0
fi

echo "Installing Hashcat MCP from ${HC_MCP_REPO}@${HC_MCP_REF}..."
if $PIP_CMD install --break-system-packages --force-reinstall \
    "git+https://github.com/${HC_MCP_REPO}.git@${HC_MCP_REF}" 2>&1; then
    echo "$HC_MCP_REF" > "$MARKER_FILE"
    echo "Hashcat MCP installed successfully."
else
    echo "WARN: Hashcat MCP install failed."
    exit 1
fi

echo ""
echo "NOTE: Hashcat MCP connects to hashcat on Kali spoke via SSH."
echo "  Ensure hashcat is in Tier 1 stock tools (check-kali-tools.sh verifies)."
