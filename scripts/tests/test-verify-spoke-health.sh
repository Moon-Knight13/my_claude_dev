#!/usr/bin/env bash
# Tests for scripts/verify-spoke-health.sh and scripts/verify-pre-deploy.sh.
# Uses SSH shim — no real connectivity needed.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
VERIFY="$REPO_ROOT/scripts/verify-spoke-health.sh"
PREDEPLOY="$REPO_ROOT/scripts/verify-pre-deploy.sh"

pass=0
fail=0
ok()  { echo "PASS $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1: $2"; fail=$((fail + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── Shims ────────────────────────────────────────────────────────────────────
SHIMS="$TMP/shims"
mkdir -p "$SHIMS"

# SSH shim — simulates healthy spoke
cat > "$SHIMS/ssh" <<'SHIM'
#!/usr/bin/env bash
# Join all args to match against remote command
all="$*"

case "$all" in
    *"echo"*"ok"*) echo "ok"; exit 0 ;;
    *"docker ps"*)
        echo "tuoni-server"
        echo "tuoni-client"
        echo "tuoni-client-nginx"
        echo "tuoni-docs"
        echo "bloodhound-bloodhound-1"
        echo "bloodhound-app-db-1"
        echo "bloodhound-graph-db-1"
        exit 0 ;;
    *"curl"*"8443"*)
        echo "401"; exit 0 ;;
    *"curl"*"8080"*)
        echo "401"; exit 0 ;;
    *"/dev/tcp/"*"7687"*)
        exit 0 ;;
    *"docker info"*)
        exit 0 ;;
    *) exit 0 ;;
esac
SHIM
chmod +x "$SHIMS/ssh"

# python3 shim for pre-deploy JSON parsing
cat > "$SHIMS/python3" <<'SHIM'
#!/usr/bin/env bash
exec /usr/bin/python3 "$@"
SHIM
chmod +x "$SHIMS/python3"

# date shim to give nanoseconds
cat > "$SHIMS/date" <<'SHIM'
#!/usr/bin/env bash
if [[ "${1:-}" == "+%s%N" ]]; then
    echo "1700000000000000000"
else
    exec /usr/bin/date "$@"
fi
SHIM
chmod +x "$SHIMS/date"

export PATH="$SHIMS:$PATH"

# Unset spoke env vars so script uses SSH config aliases
unset SPOKE_KALI_HOST SPOKE_KALI_USER SPOKE_KALI_SSH_PORT
unset SPOKE_DEPLOYBOX_HOST SPOKE_DEPLOYBOX_USER SPOKE_DEPLOYBOX_PORT

# ── Test: usage error (no args) ─────────────────────────────────────────────
out="$(bash "$VERIFY" 2>&1)" && rc=0 || rc=$?
[[ $rc -eq 3 ]] && ok "no-args exits 3" || bad "no-args exits 3" "got $rc"

# ── Test: unknown spoke ──────────────────────────────────────────────────────
out="$(bash "$VERIFY" bogus 2>&1)" && rc=0 || rc=$?
[[ $rc -eq 3 ]] && ok "unknown spoke exits 3" || bad "unknown spoke exits 3" "got $rc"

# ── Test: kali healthy (shim) ────────────────────────────────────────────────
out="$(bash "$VERIFY" kali 2>&1)" && rc=0 || rc=$?
[[ $rc -eq 0 ]] && ok "kali healthy exit 0" || bad "kali healthy exit 0" "got $rc"
echo "$out" | grep -q "HEALTHY" && ok "kali shows HEALTHY" || bad "kali shows HEALTHY" "$out"

# ── Test: kali JSON output ───────────────────────────────────────────────────
json="$(bash "$VERIFY" kali --json 2>/dev/null)" && rc=0 || rc=$?
echo "$json" | python3 -I -c "import sys,json; d=json.load(sys.stdin); assert d['status']=='healthy'" 2>/dev/null \
    && ok "kali JSON valid+healthy" || bad "kali JSON valid+healthy" "$json"

# ── Test: JSON contains all check names ──────────────────────────────────────
for check in ssh containers tuoni-api bloodhound-api neo4j-bolt; do
    echo "$json" | grep -q "\"$check\"" \
        && ok "kali JSON has $check" || bad "kali JSON has $check" "missing"
done

# ── Test: deploybox healthy (shim) ───────────────────────────────────────────
out="$(bash "$VERIFY" deploybox 2>&1)" && rc=0 || rc=$?
[[ $rc -eq 0 ]] && ok "deploybox healthy exit 0" || bad "deploybox healthy exit 0" "got $rc"

# ── Test: --quiet suppresses non-JSON ────────────────────────────────────────
out="$(bash "$VERIFY" kali --quiet --json 2>&1)" && rc=0 || rc=$?
# Should have JSON but no "Verifying spoke:" line
echo "$out" | grep -q "Verifying spoke" \
    && bad "--quiet suppresses banner" "banner present" || ok "--quiet suppresses banner"

# ── Test: pre-deploy gate (healthy spoke) ────────────────────────────────────
out="$(bash "$PREDEPLOY" kali 2>&1)" && rc=0 || rc=$?
[[ $rc -eq 0 ]] && ok "pre-deploy kali passes" || bad "pre-deploy kali passes" "got $rc"

# ── Test: pre-deploy no-args ─────────────────────────────────────────────────
out="$(bash "$PREDEPLOY" 2>&1)" && rc=0 || rc=$?
[[ $rc -eq 3 ]] && ok "pre-deploy no-args exits 3" || bad "pre-deploy no-args exits 3" "got $rc"

# ── SSH-fail shim (simulate unreachable) ─────────────────────────────────────
cat > "$SHIMS/ssh" <<'SHIM'
#!/usr/bin/env bash
echo "ssh: connect to host kali port 22: Connection timed out" >&2
exit 255
SHIM
chmod +x "$SHIMS/ssh"

out="$(bash "$VERIFY" kali --json 2>/dev/null)" && rc=0 || rc=$?
[[ $rc -eq 2 ]] && ok "unreachable kali exits 2" || bad "unreachable kali exits 2" "got $rc"
echo "$out" | python3 -I -c "import sys,json; d=json.load(sys.stdin); assert d['status']=='down'" 2>/dev/null \
    && ok "unreachable kali JSON status=down" || bad "unreachable kali JSON status=down" "$out"

# ── Pre-deploy blocks on down spoke ──────────────────────────────────────────
out="$(bash "$PREDEPLOY" kali 2>&1)" && rc=0 || rc=$?
[[ $rc -ne 0 ]] && ok "pre-deploy blocks on down spoke" || bad "pre-deploy blocks on down spoke" "got $rc"

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "verify-spoke-health tests: $pass passed, $fail failed"
[[ $fail -eq 0 ]] && exit 0 || exit 1
