#!/usr/bin/env bash
# scripts/host/install-t3.sh — T3 Code + provider CLI setup for host
# Run on HOST machine (not in container). Reversible.
#
# Usage: bash scripts/host/install-t3.sh [--with-opencode]
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()   { echo -e "${GREEN}✓${NC} $1"; }
warn() { echo -e "${YELLOW}!${NC} $1"; }
fail() { echo -e "${RED}✗${NC} $1"; }

echo "=== T3 Code Host Setup ==="
echo ""

# T3 Code
if command -v t3 &>/dev/null; then
  ok "T3 Code already installed: $(t3 --version 2>/dev/null || echo 'unknown')"
else
  echo "Installing T3 Code..."
  curl -fsSL https://t3.codes/install.sh | sh
  # Ensure PATH includes ~/.local/bin
  export PATH="$HOME/.local/bin:$PATH"
  if command -v t3 &>/dev/null; then
    ok "T3 Code installed: $(t3 --version 2>/dev/null || echo 'unknown')"
  else
    fail "T3 Code install failed. Check if ~/.local/bin is in PATH"
    echo "  Add to ~/.bashrc or ~/.zshrc: export PATH=\"\$HOME/.local/bin:\$PATH\""
    exit 1
  fi
fi

# Claude Code CLI
if command -v claude &>/dev/null; then
  ok "Claude Code already installed: $(claude --version 2>/dev/null || echo 'unknown')"
else
  echo "Installing Claude Code CLI..."
  npm install -g @anthropic-ai/claude-code
  if command -v claude &>/dev/null; then
    ok "Claude Code installed: $(claude --version 2>/dev/null || echo 'unknown')"
    warn "Run 'claude auth login' if not already authenticated"
  else
    fail "Claude Code install failed"
    exit 1
  fi
fi

# OpenCode (optional)
if [[ "${1:-}" == "--with-opencode" ]]; then
  if command -v opencode &>/dev/null; then
    ok "OpenCode already installed: $(opencode --version 2>/dev/null || echo 'unknown')"
  else
    echo "Installing OpenCode..."
    npm install -g opencode
    if command -v opencode &>/dev/null; then
      ok "OpenCode installed: $(opencode --version 2>/dev/null || echo 'unknown')"
      warn "Run 'opencode auth login' to configure provider"
    else
      fail "OpenCode install failed"
    fi
  fi
fi

echo ""
echo "=== Validation ==="

PASS=0; FAIL=0
check() {
  if command -v "$1" &>/dev/null; then
    ok "$1 found in PATH"
    ((PASS++))
  else
    fail "$1 not found"
    ((FAIL++))
  fi
}

check t3
check claude
[[ "${1:-}" == "--with-opencode" ]] && check opencode

echo ""
echo "PASS: $PASS  FAIL: $FAIL"

if [[ $FAIL -eq 0 ]]; then
  echo ""
  echo "=== Next Steps ==="
  echo "1. Start T3:  t3"
  echo "2. Open browser to T3 web UI"
  echo "3. Settings → Providers → verify Claude Code detected"
  echo "4. Add project: point to my_claude_dev workspace"
  echo "5. Create thread, test basic task"
  echo ""
  echo "Uninstall: t3 uninstall && npm uninstall -g @anthropic-ai/claude-code"
fi
