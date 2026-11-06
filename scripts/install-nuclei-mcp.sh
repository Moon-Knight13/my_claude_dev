#!/usr/bin/env bash
# Install and configure nuclei-mcp (addcontent/nuclei-mcp) for structured vuln scanning.
# Idempotent — skips steps already done.
#
# nuclei-mcp wraps the Nuclei scanner as an MCP server, exposing template-filtered
# scanning with structured JSON findings. Go-based; requires go toolchain.
#
# Usage:
#   bash scripts/install-nuclei-mcp.sh          # install + configure MCP
#   bash scripts/install-nuclei-mcp.sh --check  # check only, no changes
set -euo pipefail

# shellcheck source=scripts/lib/subsystems.sh disable=SC1090,SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/subsystems.sh"

if ! subsystem_enabled nuclei; then
  subsystem_skip_notice nuclei "Nuclei MCP install"
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

NUCLEI_MCP_REPO="addcontent/nuclei-mcp"
NUCLEI_MCP_VERSION="${NUCLEI_MCP_VERSION:-v0.1.0}"
MARKER_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
MARKER_FILE="$MARKER_DIR/.template-nuclei-mcp-ref"
mkdir -p "$MARKER_DIR"

# ── Helpers ───────────────────────────────────────────────────────────────
readonly RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' NC='\033[0m'
pass() { printf "${GREEN}PASS${NC}  %s\n" "$*"; }
warn() { printf "${YELLOW}WARN${NC}  %s\n" "$*"; }
fail() { printf "${RED}FAIL${NC}  %s\n" "$*"; }

check_only=false
[[ "${1:-}" == "--check" ]] && check_only=true

# ── Preflight ─────────────────────────────────────────────────────────────
echo "=== nuclei-mcp preflight ==="

# Go toolchain
if command -v go >/dev/null 2>&1; then
    go_ver=$(go version | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?')
    pass "Go ${go_ver}"
else
    fail "Go not found — required for nuclei-mcp"
    exit 1
fi

# Nuclei binary (optional — nuclei-mcp auto-downloads if missing)
if command -v nuclei >/dev/null 2>&1; then
    nuclei_ver=$(nuclei -version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")
    pass "Nuclei ${nuclei_ver}"
else
    warn "Nuclei not found — nuclei-mcp will attempt auto-download"
fi

# Check if already installed at target version
GOBIN="${GOBIN:-$(go env GOPATH)/bin}"
if [[ -x "$GOBIN/nuclei-mcp" ]]; then
    if [[ "${NUCLEI_MCP_FORCE:-0}" != "1" ]] \
      && [[ -f "$MARKER_FILE" ]] && grep -q "^${NUCLEI_MCP_VERSION}$" "$MARKER_FILE"; then
        pass "nuclei-mcp already installed at ${NUCLEI_MCP_VERSION}"
        if $check_only; then
            echo ""
            echo "Check complete."
        fi
        exit 0
    else
        warn "nuclei-mcp binary exists but version marker mismatch — will reinstall"
    fi
else
    warn "nuclei-mcp not installed"
fi

if $check_only; then
    echo ""
    echo "Check complete. Run without --check to install."
    exit 0
fi

# ── Install ───────────────────────────────────────────────────────────────
echo ""
echo "=== Installing nuclei-mcp ==="

NUCLEI_MCP_GIT_URL="https://github.com/${NUCLEI_MCP_REPO}.git"
BUILD_DIR=$(mktemp -d)
trap 'rm -rf "$BUILD_DIR"' EXIT

echo "Cloning ${NUCLEI_MCP_REPO}@${NUCLEI_MCP_VERSION} into ${BUILD_DIR}..."
if ! git clone --depth 1 --branch "$NUCLEI_MCP_VERSION" "$NUCLEI_MCP_GIT_URL" "$BUILD_DIR" 2>&1; then
    fail "nuclei-mcp clone failed"
    exit 1
fi

echo "Resolving dependencies..."
(cd "$BUILD_DIR" && go get github.com/bytedance/sonic@latest 2>&1 && go mod tidy 2>&1) || true

echo "Building nuclei-mcp..."
if ! (cd "$BUILD_DIR" && go build -o "$GOBIN/nuclei-mcp" ./cmd/nuclei-mcp/) 2>&1; then
    fail "nuclei-mcp build failed"
    exit 1
fi

# Verify binary
if [[ -x "$GOBIN/nuclei-mcp" ]]; then
    pass "nuclei-mcp binary at $GOBIN/nuclei-mcp"
else
    fail "nuclei-mcp binary not found after install"
    exit 1
fi

# ── MCP config ────────────────────────────────────────────────────────────
MCP_FILE="$PROJECT_DIR/.mcp.json"

if [[ ! -f "$MCP_FILE" ]]; then
    fail ".mcp.json not found at ${MCP_FILE}"
    exit 1
fi

if grep -q '"nuclei-mcp"' "$MCP_FILE" 2>/dev/null; then
    pass "nuclei-mcp already in .mcp.json"
else
    echo "Adding nuclei-mcp to .mcp.json..."
    python3 -I -c "
import json, os
mcp_file = '$MCP_FILE'
wrapper = '$PROJECT_DIR/scripts/mcp-wrapper.sh'
gobin = '$GOBIN'
with open(mcp_file) as f:
    cfg = json.load(f)
cfg['mcpServers']['nuclei-mcp'] = {
    'command': wrapper,
    'args': [os.path.join(gobin, 'nuclei-mcp')],
    'env': {
        'NUCLEI_MCP_SERVER_PORT': '0',
    }
}
with open(mcp_file, 'w') as f:
    json.dump(cfg, f, indent=2)
    f.write('\n')
"
    pass "nuclei-mcp added to .mcp.json"
fi

# ── Marker ────────────────────────────────────────────────────────────────
echo "$NUCLEI_MCP_VERSION" > "$MARKER_FILE"

echo ""
echo "=== nuclei-mcp install complete (${NUCLEI_MCP_REPO}@${NUCLEI_MCP_VERSION}) ==="
echo ""
echo "Restart Claude Code to load new MCP tools."
echo "Tools: nuclei_scan, basic_scan, list_templates, get_template, add_template"
if ! command -v nuclei >/dev/null 2>&1; then
    echo "Note: install nuclei for scanning. nuclei-mcp will attempt auto-download."
    echo "  Manual: go install -v github.com/projectdiscovery/nuclei/v3/cmd/nuclei@latest"
fi
