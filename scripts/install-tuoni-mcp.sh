#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib/subsystems.sh disable=SC1090,SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/subsystems.sh"

if ! subsystem_enabled tuoni; then
  subsystem_skip_notice tuoni "Tuoni MCP install"
  exit 0
fi

TUONI_MCP_REPO="${TUONI_MCP_REPO:-shell-dot/tuoni-mcp}"
TUONI_MCP_REF="${TUONI_MCP_REF:-main}"
MARKER_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
MARKER_FILE="$MARKER_DIR/.template-tuoni-mcp-ref"
mkdir -p "$MARKER_DIR"

# TUONI_MCP_FORCE=1 bypasses the ref marker (operator knob for reinstalls).
if [[ "${TUONI_MCP_FORCE:-0}" != "1" ]] \
  && [[ -f "$MARKER_FILE" ]] && grep -q "^${TUONI_MCP_REF}$" "$MARKER_FILE"; then
  echo "Tuoni MCP already installed at ref ${TUONI_MCP_REF}."
  exit 0
fi

if ! command -v pip >/dev/null 2>&1 && ! command -v pip3 >/dev/null 2>&1; then
  echo "WARN: pip not found; skipping Tuoni MCP install."
  exit 0
fi

PIP_CMD="pip"
command -v pip3 >/dev/null 2>&1 && PIP_CMD="pip3"

echo "Installing official Tuoni MCP from ${TUONI_MCP_REPO}@${TUONI_MCP_REF}..."
if ! $PIP_CMD install --break-system-packages --force-reinstall \
    "git+https://github.com/${TUONI_MCP_REPO}.git@${TUONI_MCP_REF}" 2>&1; then
  echo "WARN: Tuoni MCP install failed; continuing without it."
  exit 0
fi

# Verify install
if ! python3 -c "from tuoni_mcp.config import Settings; print('OK')" 2>/dev/null; then
  echo "WARN: Tuoni MCP installed but import check failed."
  exit 0
fi

echo "$TUONI_MCP_REF" > "$MARKER_FILE"
echo "Tuoni MCP install complete (${TUONI_MCP_REPO}@${TUONI_MCP_REF})."
