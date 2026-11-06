#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib/subsystems.sh disable=SC1090,SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/subsystems.sh"

if ! subsystem_enabled bloodhound; then
  subsystem_skip_notice bloodhound "BloodHound MCP install"
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

BH_MCP_REPO="${BH_MCP_REPO:-MorDavid/BloodHound-MCP-AI}"
BH_MCP_REF="${BH_MCP_REF:-main}"
BH_MCP_DIR="$PROJECT_DIR/mcp-servers/bloodhound-mcp"
MARKER_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
MARKER_FILE="$MARKER_DIR/.template-bloodhound-mcp-ref"
mkdir -p "$MARKER_DIR"

if [[ "${BH_MCP_FORCE:-0}" != "1" ]] \
  && [[ -f "$MARKER_FILE" ]] && grep -q "^${BH_MCP_REF}$" "$MARKER_FILE"; then
  echo "BloodHound MCP already installed at ref ${BH_MCP_REF}."
  exit 0
fi

VENV_DIR="$PROJECT_DIR/mcp-servers/.venv"

if [[ "${DEVCONTAINER:-}" == "true" ]]; then
  if ! command -v pip >/dev/null 2>&1 && ! command -v pip3 >/dev/null 2>&1; then
    echo "WARN: pip not found; skipping BloodHound MCP install."
    exit 0
  fi
  PIP_CMD="pip3"
  command -v pip >/dev/null 2>&1 && PIP_CMD="pip"
  PIP_ARGS="--break-system-packages"
  PYTHON_CMD="python3"
else
  if ! command -v python3 >/dev/null 2>&1; then
    echo "WARN: python3 not found; skipping BloodHound MCP install."
    exit 0
  fi
  if [[ ! -d "$VENV_DIR" ]]; then
    echo "Creating shared MCP venv at $VENV_DIR..."
    python3 -m venv "$VENV_DIR"
  fi
  PIP_CMD="$VENV_DIR/bin/pip"
  PIP_ARGS=""
  PYTHON_CMD="$VENV_DIR/bin/python3"
fi

# Clone or update repo
if [[ -d "$BH_MCP_DIR/.git" ]]; then
  echo "Updating BloodHound MCP repo..."
  git -C "$BH_MCP_DIR" fetch origin
  git -C "$BH_MCP_DIR" checkout "$BH_MCP_REF"
  git -C "$BH_MCP_DIR" pull origin "$BH_MCP_REF" 2>/dev/null || true
else
  echo "Cloning BloodHound MCP from ${BH_MCP_REPO}@${BH_MCP_REF}..."
  rm -rf "$BH_MCP_DIR"
  git clone --depth 1 --branch "$BH_MCP_REF" \
    "https://github.com/${BH_MCP_REPO}.git" "$BH_MCP_DIR"
fi

# Install dependencies into shared venv
if [[ -f "$BH_MCP_DIR/requirements.txt" ]]; then
  echo "Installing BloodHound MCP dependencies..."
  # shellcheck disable=SC2086
  $PIP_CMD install $PIP_ARGS -r "$BH_MCP_DIR/requirements.txt" 2>&1 || {
    echo "WARN: BloodHound MCP dependency install failed; continuing without it."
    exit 0
  }
fi

# Verify neo4j driver available
if ! $PYTHON_CMD -c "import neo4j; print('neo4j driver OK')" 2>/dev/null; then
  echo "WARN: BloodHound MCP installed but neo4j driver import check failed."
  exit 0
fi

echo "$BH_MCP_REF" > "$MARKER_FILE"
echo "BloodHound MCP install complete (${BH_MCP_REPO}@${BH_MCP_REF})."
echo ""
echo "Required .env vars (set before use):"
echo "  BLOODHOUND_URI=bolt://<neo4j-host>:7687"
echo "  BLOODHOUND_USERNAME=neo4j"
echo "  BLOODHOUND_PASSWORD=<password>"
