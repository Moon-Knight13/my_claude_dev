#!/usr/bin/env bash
# scripts/host/t3-validate.sh — Phase B validation gates
# Run on HOST after T3 is installed and started.
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()   { echo -e "${GREEN}PASS${NC} $1"; }
warn() { echo -e "${YELLOW}SKIP${NC} $1"; }
fail() { echo -e "${RED}FAIL${NC} $1"; }

PASS=0; FAIL=0; SKIP=0

gate() {
  local name="$1"; shift
  if "$@" &>/dev/null 2>&1; then
    ok "$name"; ((PASS++))
  else
    fail "$name"; ((FAIL++))
  fi
}

gate_optional() {
  local name="$1"; shift
  if "$@" &>/dev/null 2>&1; then
    ok "$name"; ((PASS++))
  else
    warn "$name (optional)"; ((SKIP++))
  fi
}

echo "=== T3 Code Phase B Validation ==="
echo ""

echo "--- Prerequisites ---"
gate "t3 CLI in PATH" command -v t3
gate "claude CLI in PATH" command -v claude
gate_optional "opencode CLI in PATH" command -v opencode
gate "claude authenticated" claude auth status

echo ""
echo "--- Config ---"
gate "~/.claude exists" test -d "$HOME/.claude"
gate ".claude/modes/ exists" test -d "$HOME/.claude/projects/-workspace/.claude" || test -d "$PWD/.claude/modes"

echo ""
echo "--- Network ---"
gate_optional "Tailscale running" tailscale status
gate_optional "ProtonVPN connected" command -v protonvpn-cli

echo ""
echo "--- T3 Server ---"
T3_DEFAULT_PORT="${T3_PORT:-3773}"
if curl -sf "http://127.0.0.1:$T3_DEFAULT_PORT" &>/dev/null; then
  ok "T3 server responding on :$T3_DEFAULT_PORT"; ((PASS++))
else
  # T3 might use a different port
  T3_PORT=$(ss -tlnp 2>/dev/null | grep t3 | head -1 | grep -oP ':\K\d+' || echo "")
  if [[ -n "$T3_PORT" ]]; then
    ok "T3 server responding on :$T3_PORT"; ((PASS++))
  else
    fail "T3 server not detected — run 't3' first"; ((FAIL++))
  fi
fi

echo ""
echo "--- Summary ---"
echo -e "PASS: ${GREEN}$PASS${NC}  FAIL: ${RED}$FAIL${NC}  SKIP: ${YELLOW}$SKIP${NC}"

if [[ $FAIL -eq 0 ]]; then
  echo ""
  echo "All gates passed. Ready for provider switch testing."
else
  echo ""
  echo "Fix failures before proceeding."
fi
