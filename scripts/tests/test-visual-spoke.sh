#!/usr/bin/env bash
# Tests for visual-spoke.sh — argument parsing, info, status (no real tunnel).
# Usage: bash scripts/tests/test-visual-spoke.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/visual-spoke.sh"

fails=0
ok()   { echo "PASS $1"; }
bad()  { echo "FAIL $1: $2"; fails=$((fails + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Use temp home so pidfile doesn't conflict with real state
export HOME="$TMP"

# --- 1. No args shows usage ------------------------------------------------
output=$(bash "$SCRIPT" 2>&1 || true)
if echo "$output" | grep -q 'Usage:'; then
    ok no-args-usage
else
    bad no-args-usage "expected usage message"
fi

# --- 2. Invalid command shows usage ----------------------------------------
output=$(bash "$SCRIPT" invalid 2>&1 || true)
if echo "$output" | grep -q 'Usage:'; then
    ok invalid-cmd-usage
else
    bad invalid-cmd-usage "expected usage message"
fi

# --- 3. Status reports DOWN when no tunnel running -------------------------
output=$(bash "$SCRIPT" status 2>&1 || true)
if echo "$output" | grep -q 'DOWN\|No tunnel'; then
    ok status-down-no-tunnel
else
    bad status-down-no-tunnel "expected DOWN status"
fi

# --- 4. Info prints connection instructions --------------------------------
output=$(SPOKE_KALI_SOCKS_PORT=9999 bash "$SCRIPT" info 2>&1)
if echo "$output" | grep -q 'SOCKS5 proxy'; then
    ok info-shows-socks
else
    bad info-shows-socks "missing SOCKS5 proxy line"
fi

# --- 5. Info includes RDP instructions ------------------------------------
if echo "$output" | grep -q 'xfreerdp'; then
    ok info-has-rdp
else
    bad info-has-rdp "missing RDP instructions"
fi

# --- 6. Info includes VNC instructions ------------------------------------
if echo "$output" | grep -q 'vncviewer\|VNC'; then
    ok info-has-vnc
else
    bad info-has-vnc "missing VNC instructions"
fi

# --- 7. Info includes browser instructions --------------------------------
if echo "$output" | grep -q 'Firefox\|Chrome\|browser'; then
    ok info-has-browser
else
    bad info-has-browser "missing browser instructions"
fi

# --- 8. Info respects custom SOCKS port -----------------------------------
if echo "$output" | grep -q '9999'; then
    ok info-custom-port
else
    bad info-custom-port "did not use custom SOCKS port 9999"
fi

# --- 9. Test command fails when no tunnel running -------------------------
output=$(bash "$SCRIPT" test 10.0.0.1 2>&1 || true)
if echo "$output" | grep -q 'not running\|tunnel not'; then
    ok test-fails-no-tunnel
else
    bad test-fails-no-tunnel "test should fail without tunnel"
fi

# --- 10. Test command needs target IP -------------------------------------
# Create fake pidfile to simulate running tunnel
echo "99999" > "$TMP/.visual-spoke.pid"
output=$(bash "$SCRIPT" test 2>&1 || true)
if echo "$output" | grep -q 'Usage:\|target-ip'; then
    ok test-needs-target
else
    bad test-needs-target "test should require target IP"
fi
rm -f "$TMP/.visual-spoke.pid"

# --- 11. Down is idempotent when no tunnel --------------------------------
output=$(bash "$SCRIPT" down 2>&1)
if echo "$output" | grep -q 'No tunnel'; then
    ok down-idempotent
else
    bad down-idempotent "down should handle no-tunnel gracefully"
fi

# --- 12. Script is executable --------------------------------------------
if [[ -x "$SCRIPT" ]]; then
    ok script-executable
else
    bad script-executable "script not executable"
fi

# --- 13. Pidfile cleaned on status when stale -----------------------------
echo "99999" > "$TMP/.visual-spoke.pid"
bash "$SCRIPT" status >/dev/null 2>&1 || true
if [[ ! -f "$TMP/.visual-spoke.pid" ]]; then
    ok stale-pidfile-cleaned
else
    bad stale-pidfile-cleaned "stale pidfile not cleaned"
fi

# ── Summary ───────────────────────────────────────────────────────────────
echo ""
if (( fails == 0 )); then
    echo "All tests passed."
else
    echo "${fails} test(s) FAILED."
fi
exit "$fails"
