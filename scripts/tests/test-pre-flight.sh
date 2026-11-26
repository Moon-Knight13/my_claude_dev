#!/usr/bin/env bash
# Tests for scripts/lib/pre-flight.sh — validates JSON output, mode routing,
# check selection, and exit codes. Uses shims so no real network access needed.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
PREFLIGHT="$REPO_ROOT/scripts/lib/pre-flight.sh"

pass=0
fail=0
ok()  { echo "PASS $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1: $2"; fail=$((fail + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── Build sandbox ────────────────────────────────────────────────────────────
SANDBOX="$TMP/sandbox"
mkdir -p "$SANDBOX/.claude/modes/red-team" "$SANDBOX/.claude/modes/green-dev" \
         "$SANDBOX/.claude/modes/ctf" "$SANDBOX/.claude/modes/platform-ops" \
         "$SANDBOX/scripts/lib"

cp "$REPO_ROOT/scripts/lib/load-env.sh" "$SANDBOX/scripts/lib/"
cp "$PREFLIGHT" "$SANDBOX/scripts/lib/pre-flight.sh"

echo '{"_mode":"red-team"}' > "$SANDBOX/.claude/settings.json"
cat > "$SANDBOX/.env" <<'DOT'
SPOKE_KALI_HOST=10.0.0.1
SPOKE_KALI_USER=rt
SPOKE_KALI_SSH_PORT=22
SPOKE_KALI_C2_WEB_PORT=8443
SPOKE_DEPLOYBOX_HOST=10.0.0.2
SPOKE_DEPLOYBOX_USER=gt
RANGE_GATEWAY_HOST=10.0.0.254
RANGE_GIT_HOST=10.0.0.3
RANGE_GIT_SSH_PORT=10022
PROVIDENTIA_HOST=10.0.0.4
TUONI_USERNAME=admin
TUONI_PASSWORD=secret
DOT

# ── Shims — simulate all-pass network ───────────────────────────────────────
SHIMS="$TMP/shims"
mkdir -p "$SHIMS"

cat > "$SHIMS/ping" <<'SHIM'
#!/bin/bash
exit 0
SHIM

cat > "$SHIMS/ssh" <<'SHIM'
#!/bin/bash
for arg in "$@"; do
    [[ "$arg" == git@* ]] && { echo "Welcome to GitLab"; exit 0; }
done
echo "rt"
exit 0
SHIM

cat > "$SHIMS/dig" <<'SHIM'
#!/bin/bash
echo "10.0.0.3"
exit 0
SHIM

cat > "$SHIMS/curl" <<'SHIM'
#!/bin/bash
exit 0
SHIM

cat > "$SHIMS/timeout" <<'SHIM'
#!/bin/bash
# Strip duration arg, pass through. The bash shim handles /dev/tcp intercept.
shift
exec "$@"
SHIM

# bash shim: intercept `bash -c "echo >/dev/tcp/..."` and succeed immediately.
# Real bash for everything else. Must use /bin/bash shebang — env bash
# would resolve back to this shim and loop.
cat > "$SHIMS/bash" <<'SHIM'
#!/bin/bash
for arg in "$@"; do
    if [[ "$arg" == *"/dev/tcp/"* ]]; then
        exit 0
    fi
done
exec /bin/bash "$@"
SHIM

cat > "$SHIMS/ipset" <<'SHIM'
#!/bin/bash
exit 0
SHIM

chmod +x "$SHIMS"/*

run_pf() {
    local mode="${1:-}"
    (cd "$SANDBOX" && PATH="$SHIMS:$PATH" bash scripts/lib/pre-flight.sh "$mode") 2>&1
}

run_pf_rc() {
    local mode="${1:-}"
    local out rc
    out="$(cd "$SANDBOX" && PATH="$SHIMS:$PATH" bash scripts/lib/pre-flight.sh "$mode" 2>&1)"
    rc=$?
    echo "$out"
    return $rc
}

echo "=== pre-flight tests ==="

# --- T1: script exists and is executable ---
if [[ -x "$PREFLIGHT" ]]; then ok "script executable"; else bad "script executable" "not found or not +x"; fi

# --- T2: output is valid JSON ---
out="$(run_pf red-team)"
if echo "$out" | jq . >/dev/null 2>&1; then
    ok "output is valid JSON"
else
    bad "output is valid JSON" "got: ${out:0:100}"
fi

# --- T3: JSON has required top-level keys ---
has_keys=true
for key in mode checks ready; do
    echo "$out" | jq -e ".$key" >/dev/null 2>&1 || has_keys=false
done
if $has_keys; then ok "JSON has mode/checks/ready"; else bad "JSON has mode/checks/ready" "missing keys"; fi

# --- T4: mode field matches argument ---
mode_val="$(echo "$out" | jq -r '.mode')"
if [[ "$mode_val" == "red-team" ]]; then ok "mode field = red-team"; else bad "mode field = red-team" "got: $mode_val"; fi

# --- T5: checks is array with entries ---
check_count="$(echo "$out" | jq '.checks | length')"
if [[ "$check_count" -gt 0 ]]; then ok "checks array non-empty ($check_count)"; else bad "checks array non-empty" "length=0"; fi

# --- T6: each check has name, status, latency_ms ---
valid_checks=true
echo "$out" | jq -c '.checks[]' | while read -r c; do
    for field in name status latency_ms; do
        echo "$c" | jq -e ".$field" >/dev/null 2>&1 || { valid_checks=false; break 2; }
    done
done
$valid_checks && ok "check entries have required fields" || bad "check entries have required fields" "missing name/status/latency_ms"

# --- T7: all-pass returns ready=true and exit 0 ---
if run_pf_rc red-team >/dev/null 2>&1; then
    out_pass="$(run_pf red-team)"
    ready="$(echo "$out_pass" | jq -r '.ready')"
    [[ "$ready" == "true" ]] && ok "all-pass ready=true exit=0" || bad "all-pass ready=true" "ready=$ready"
else
    bad "all-pass exit=0" "non-zero exit"
fi

# --- T8: failure returns ready=false and exit 1 ---
# Replace ssh shim with failure version
cat > "$SHIMS/ssh" <<'SHIM'
#!/bin/bash
exit 1
SHIM
chmod +x "$SHIMS/ssh"
out_fail="$(run_pf_rc red-team)" && exit_ok=false || exit_ok=true
ready_fail="$(echo "$out_fail" | jq -r '.ready')"
if $exit_ok && [[ "$ready_fail" == "false" ]]; then
    ok "failure ready=false exit=1"
else
    bad "failure ready=false exit=1" "exit_fail=$exit_ok ready=$ready_fail"
fi
# Restore passing ssh shim
cat > "$SHIMS/ssh" <<'SHIM'
#!/bin/bash
for arg in "$@"; do
    [[ "$arg" == git@* ]] && { echo "Welcome to GitLab"; exit 0; }
done
echo "rt"
exit 0
SHIM
chmod +x "$SHIMS/ssh"

# --- T9: mode detection from settings.json ---
out_auto="$(run_pf "")"
auto_mode="$(echo "$out_auto" | jq -r '.mode')"
[[ "$auto_mode" == "red-team" ]] && ok "auto-detect mode from settings.json" || bad "auto-detect mode" "got: $auto_mode"

# --- T10: green-dev mode does NOT check tuoni ---
out_gd="$(run_pf green-dev)"
if echo "$out_gd" | jq -e '.checks[] | select(.name | startswith("tuoni"))' >/dev/null 2>&1; then
    bad "green-dev skips tuoni" "tuoni check present"
else
    ok "green-dev skips tuoni"
fi

# --- T11: green-dev mode checks deploybox ---
if echo "$out_gd" | jq -e '.checks[] | select(.name | startswith("spoke-deploybox"))' >/dev/null 2>&1; then
    ok "green-dev checks deploybox"
else
    bad "green-dev checks deploybox" "no deploybox check"
fi

# --- T12: red-team mode checks tuoni ---
out_rt="$(run_pf red-team)"
if echo "$out_rt" | jq -e '.checks[] | select(.name | startswith("tuoni"))' >/dev/null 2>&1; then
    ok "red-team checks tuoni"
else
    bad "red-team checks tuoni" "no tuoni check"
fi

# --- T13: ctf mode does NOT check providentia ---
out_ctf="$(run_pf ctf)"
if echo "$out_ctf" | jq -e '.checks[] | select(.name | startswith("providentia"))' >/dev/null 2>&1; then
    bad "ctf skips providentia" "providentia check present"
else
    ok "ctf skips providentia"
fi

# --- T14: env-vars check reports missing vars ---
# Remove a required var
sed -i '/TUONI_USERNAME/d' "$SANDBOX/.env"
unset _CLAUDE_ENV_LOADED 2>/dev/null || true
out_env="$(cd "$SANDBOX" && unset TUONI_USERNAME; PATH="$SHIMS:$PATH" _CLAUDE_ENV_LOADED= bash scripts/lib/pre-flight.sh red-team 2>&1)"
if echo "$out_env" | jq -e '.checks[] | select(.name == "env-vars" and .status == "fail")' >/dev/null 2>&1; then
    ok "env-vars detects missing TUONI_USERNAME"
else
    bad "env-vars detects missing" "$(echo "$out_env" | jq -c '.checks[] | select(.name == "env-vars")')"
fi
# Restore
echo "TUONI_USERNAME=admin" >> "$SANDBOX/.env"

# --- T15: skip status when host not configured ---
# Remove deploybox host
sed -i '/SPOKE_DEPLOYBOX_HOST/d' "$SANDBOX/.env"
unset _CLAUDE_ENV_LOADED 2>/dev/null || true
out_skip="$(cd "$SANDBOX" && unset SPOKE_DEPLOYBOX_HOST; PATH="$SHIMS:$PATH" _CLAUDE_ENV_LOADED= bash scripts/lib/pre-flight.sh platform-ops 2>&1)"
if echo "$out_skip" | jq -e '.checks[] | select(.name == "spoke-deploybox" and .status == "skip")' >/dev/null 2>&1; then
    ok "skip when host not set"
else
    bad "skip when host not set" "no skip entry for deploybox"
fi

# --- T16: homelab mode runs no infrastructure checks (only env-vars) ---
out_hl="$(run_pf homelab)"
infra_count="$(echo "$out_hl" | jq '[.checks[] | select(.name != "env-vars")] | length')"
[[ "$infra_count" -eq 0 ]] && ok "homelab has no infra checks" || bad "homelab has no infra checks" "got $infra_count"

# --- T17: latency_ms is a number ---
non_num="$(echo "$out" | jq '[.checks[] | select(.latency_ms | type != "number")] | length')"
[[ "$non_num" -eq 0 ]] && ok "latency_ms all numeric" || bad "latency_ms all numeric" "$non_num non-numeric"

echo ""
echo "Results: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
