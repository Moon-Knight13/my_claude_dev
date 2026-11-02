#!/usr/bin/env bash
# Tests for scripts/spoke-firewall.sh — spoke IP firewall allow-list.
#
# Stubs ipset and dig so tests run without root or real firewall.
# No network, no prompts, deterministic.
#
# Usage: bash scripts/tests/test-spoke-firewall.sh
# Exit: 0 pass, non-zero = number of failures.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$(dirname "$HERE")/spoke-firewall.sh"
# shellcheck disable=SC2034  # REPO_ROOT used by sourced scripts
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

fails=0

ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1: $2"; fails=$((fails + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- Stub ipset: records calls to a log file --------------------------------
IPSET_LOG="$TMP/ipset.log"
cat > "$TMP/ipset" <<'STUB'
#!/usr/bin/env bash
echo "ipset $*" >> "${IPSET_LOG}"
exit 0
STUB
chmod +x "$TMP/ipset"

# --- Stub dig: returns a fake IP for known hostnames -------------------------
cat > "$TMP/dig" <<'STUB'
#!/usr/bin/env bash
case "${*}" in
    *"kali.range.local"*)  echo "10.200.1.15" ;;
    *"unresolvable.host"*) ;;  # empty = resolution failure
    *)                     echo "10.0.0.99" ;;
esac
STUB
chmod +x "$TMP/dig"

# shellcheck disable=SC2120
run_fw() {
    # Run spoke-firewall.sh with stubbed PATH and a fake .env
    (
        export PATH="$TMP:$PATH"
        export IPSET_LOG
        export _CLAUDE_ENV_LOADED=1
        "$@" bash "$SCRIPT" 2>&1
    )
}

# --- 1. No spoke vars set — adds 0, exits 0 ---------------------------------
true > "$IPSET_LOG"
out="$(
    SPOKE_DEPLOYBOX_HOST="" \
    SPOKE_KALI_HOST="" \
    RANGE_GIT_HOST="" \
    PROVIDENTIA_HOST="" \
    OUTLINE_HOST="" \
    run_fw
)"
if echo "$out" | grep -q "spoke-firewall: 0 spoke IPs"; then
    ok "no-vars-adds-zero"
else
    bad "no-vars-adds-zero" "expected 0 IPs added: $out"
fi

# --- 2. Valid IP accepted directly -------------------------------------------
true > "$IPSET_LOG"
out="$(
    SPOKE_DEPLOYBOX_HOST="" \
    SPOKE_KALI_HOST="10.200.1.15" \
    RANGE_GIT_HOST="" \
    PROVIDENTIA_HOST="" \
    OUTLINE_HOST="" \
    run_fw
)"
if grep -q "ipset add -exist allowed-domains 10.200.1.15" "$IPSET_LOG"; then
    ok "valid-ip-accepted"
else
    bad "valid-ip-accepted" "ipset not called with 10.200.1.15: $(cat "$IPSET_LOG")"
fi

# --- 3. Hostname triggers DNS resolution ------------------------------------
true > "$IPSET_LOG"
out="$(
    SPOKE_DEPLOYBOX_HOST="" \
    SPOKE_KALI_HOST="kali.range.local" \
    RANGE_GIT_HOST="" \
    PROVIDENTIA_HOST="" \
    OUTLINE_HOST="" \
    run_fw
)"
if grep -q "ipset add -exist allowed-domains 10.200.1.15" "$IPSET_LOG"; then
    ok "hostname-resolved"
else
    bad "hostname-resolved" "dig stub should resolve to 10.200.1.15: $(cat "$IPSET_LOG")"
fi

# --- 4. Unresolvable hostname warns and skips --------------------------------
true > "$IPSET_LOG"
out="$(
    SPOKE_DEPLOYBOX_HOST="" \
    SPOKE_KALI_HOST="unresolvable.host" \
    RANGE_GIT_HOST="" \
    PROVIDENTIA_HOST="" \
    OUTLINE_HOST="" \
    run_fw
)"
if echo "$out" | grep -q "WARNING.*cannot resolve"; then
    ok "unresolvable-warns"
else
    bad "unresolvable-warns" "expected warning: $out"
fi
if ! grep -q "ipset add" "$IPSET_LOG"; then
    ok "unresolvable-skips-ipset"
else
    bad "unresolvable-skips-ipset" "should not call ipset: $(cat "$IPSET_LOG")"
fi

# --- 5. Multiple vars — correct count ---------------------------------------
true > "$IPSET_LOG"
out="$(
    SPOKE_DEPLOYBOX_HOST="10.100.0.40" \
    SPOKE_KALI_HOST="10.200.1.15" \
    RANGE_GIT_HOST="10.100.0.10" \
    PROVIDENTIA_HOST="10.100.0.20" \
    OUTLINE_HOST="10.100.0.21" \
    run_fw
)"
if echo "$out" | grep -q "spoke-firewall: 5 spoke IPs"; then
    ok "five-vars-count"
else
    bad "five-vars-count" "expected 5: $out"
fi

# --- 6. Idempotent — running twice produces same output ----------------------
true > "$IPSET_LOG"
out1="$(SPOKE_KALI_HOST="10.200.1.15" SPOKE_DEPLOYBOX_HOST="" RANGE_GIT_HOST="" PROVIDENTIA_HOST="" OUTLINE_HOST="" run_fw)"
out2="$(SPOKE_KALI_HOST="10.200.1.15" SPOKE_DEPLOYBOX_HOST="" RANGE_GIT_HOST="" PROVIDENTIA_HOST="" OUTLINE_HOST="" run_fw)"
count1=$(echo "$out1" | grep -o 'spoke-firewall:.*')
count2=$(echo "$out2" | grep -o 'spoke-firewall:.*')
if [[ "$count1" == "$count2" ]]; then
    ok "idempotent"
else
    bad "idempotent" "outputs differ: '$count1' vs '$count2'"
fi

# --- 7. Empty var skipped silently (no warning) ------------------------------
true > "$IPSET_LOG"
out="$(
    SPOKE_DEPLOYBOX_HOST="" \
    SPOKE_KALI_HOST="" \
    RANGE_GIT_HOST="" \
    PROVIDENTIA_HOST="" \
    OUTLINE_HOST="" \
    run_fw
)"
if ! echo "$out" | grep -q "WARNING"; then
    ok "empty-vars-no-warning"
else
    bad "empty-vars-no-warning" "should not warn on empty: $out"
fi

echo
echo "--- Results: $((7 - fails))/7 passed ---"
exit "$fails"
