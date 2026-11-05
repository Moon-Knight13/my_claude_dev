#!/usr/bin/env bash
# install-bloodhound-mcp.sh — install BloodHound MCP server in orchestrator.
#
# BloodHound MCP wraps Neo4j/BloodHound CE API for natural-language AD
# path queries. The MCP server runs locally in the devcontainer; BloodHound CE
# + Neo4j run on Kali spoke (operator-deployed Docker containers).
#
# Requires: pip3, SPOKE_KALI_HOST in .env (for Neo4j endpoint)
#
# Usage:
#   bash scripts/install-bloodhound-mcp.sh              # install
#   bash scripts/install-bloodhound-mcp.sh --check-only  # verify installed
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/load-env.sh"

BH_MCP_REPO="${BH_MCP_REPO:-MorDavid/BloodHound-MCP-AI}"
BH_MCP_REF="${BH_MCP_REF:-main}"
MARKER_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
MARKER_FILE="$MARKER_DIR/.template-bloodhound-mcp-ref"
mkdir -p "$MARKER_DIR"

CHECK_ONLY=false
[[ "${1:-}" == "--check-only" ]] && CHECK_ONLY=true

# ── Check-only mode ──────────────────────────────────────────────────────
if [[ "$CHECK_ONLY" == true ]]; then
    if python3 -I -c "import bloodhound_mcp" 2>/dev/null; then
        echo "OK: BloodHound MCP installed"
        if [[ -f "$MARKER_FILE" ]]; then
            echo "  Ref: $(cat "$MARKER_FILE")"
        fi
    else
        echo "MISSING: BloodHound MCP not installed"
        echo "  Run: bash scripts/install-bloodhound-mcp.sh"
        exit 1
    fi

    echo ""
    echo "Neo4j endpoint check:"
    NEO4J_HOST="${SPOKE_KALI_HOST:-unset}"
    NEO4J_PORT="${BH_NEO4J_PORT:-7687}"
    if [[ "$NEO4J_HOST" != "unset" ]]; then
        if timeout 3 bash -c "echo >/dev/tcp/$NEO4J_HOST/$NEO4J_PORT" 2>/dev/null; then
            echo "  OK: Neo4j reachable at $NEO4J_HOST:$NEO4J_PORT"
        else
            echo "  WARN: Neo4j not reachable at $NEO4J_HOST:$NEO4J_PORT"
            echo "  BloodHound CE + Neo4j must be deployed on Kali spoke"
        fi
    else
        echo "  WARN: SPOKE_KALI_HOST not set"
    fi
    exit 0
fi

# ── Skip if already installed at same ref ────────────────────────────────
if [[ "${BH_MCP_FORCE:-0}" != "1" ]] \
  && [[ -f "$MARKER_FILE" ]] && grep -q "^${BH_MCP_REF}$" "$MARKER_FILE"; then
    echo "BloodHound MCP already installed at ref ${BH_MCP_REF}."
    exit 0
fi

# ── Install ──────────────────────────────────────────────────────────────
PIP_CMD="pip3"
command -v pip3 >/dev/null 2>&1 || PIP_CMD="pip"

if ! command -v "$PIP_CMD" >/dev/null 2>&1; then
    echo "WARN: pip not found; skipping BloodHound MCP install."
    exit 0
fi

echo "Installing BloodHound MCP from ${BH_MCP_REPO}@${BH_MCP_REF}..."
if $PIP_CMD install --break-system-packages --force-reinstall \
    "git+https://github.com/${BH_MCP_REPO}.git@${BH_MCP_REF}" 2>&1; then
    echo "$BH_MCP_REF" > "$MARKER_FILE"
    echo "BloodHound MCP installed successfully."
else
    echo "WARN: BloodHound MCP install failed."
    exit 1
fi

echo ""
echo "NOTE: BloodHound CE + Neo4j must be running on Kali spoke."
echo "  Deploy: docker-compose up -d (on Kali)"
echo "  Set env vars: BH_NEO4J_URI, BH_NEO4J_USER, BH_NEO4J_PASSWORD"
