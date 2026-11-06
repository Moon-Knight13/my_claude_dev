#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib/subsystems.sh disable=SC1090,SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/subsystems.sh"

if ! subsystem_enabled tuoni; then
  subsystem_skip_notice tuoni "Tuoni MCP install"
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

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

# Host vs container: use a shared venv on host to avoid polluting system Python.
# Devcontainer uses --break-system-packages (disposable container env).
VENV_DIR="$PROJECT_DIR/mcp-servers/.venv"

if [[ "${DEVCONTAINER:-}" == "true" ]]; then
  if ! command -v pip >/dev/null 2>&1 && ! command -v pip3 >/dev/null 2>&1; then
    echo "WARN: pip not found; skipping Tuoni MCP install."
    exit 0
  fi
  PIP_CMD="pip3"
  command -v pip >/dev/null 2>&1 && PIP_CMD="pip"
  PIP_ARGS="--break-system-packages --force-reinstall"
  PYTHON_CMD="python3"
else
  if ! command -v python3 >/dev/null 2>&1; then
    echo "WARN: python3 not found; skipping Tuoni MCP install."
    exit 0
  fi
  if [[ ! -d "$VENV_DIR" ]]; then
    echo "Creating shared MCP venv at $VENV_DIR..."
    python3 -m venv "$VENV_DIR"
  fi
  PIP_CMD="$VENV_DIR/bin/pip"
  PIP_ARGS="--force-reinstall"
  PYTHON_CMD="$VENV_DIR/bin/python3"

  # Also install range-intel editable into the shared venv
  RANGE_INTEL_DIR="$PROJECT_DIR/mcp-servers/range-intel"
  if [[ -f "$RANGE_INTEL_DIR/pyproject.toml" ]]; then
    echo "Installing range-intel-mcp (editable) into shared venv..."
    $PIP_CMD install -e "$RANGE_INTEL_DIR" 2>&1 || echo "WARN: range-intel install failed"
  fi
fi

echo "Installing official Tuoni MCP from ${TUONI_MCP_REPO}@${TUONI_MCP_REF}..."
# shellcheck disable=SC2086
if ! $PIP_CMD install $PIP_ARGS \
    "git+https://github.com/${TUONI_MCP_REPO}.git@${TUONI_MCP_REF}" 2>&1; then
  echo "WARN: Tuoni MCP install failed; continuing without it."
  exit 0
fi

# Verify install
if ! $PYTHON_CMD -c "from tuoni_mcp.config import Settings; print('OK')" 2>/dev/null; then
  echo "WARN: Tuoni MCP installed but import check failed."
  exit 0
fi

echo "$TUONI_MCP_REF" > "$MARKER_FILE"
echo "Tuoni MCP install complete (${TUONI_MCP_REPO}@${TUONI_MCP_REF})."
