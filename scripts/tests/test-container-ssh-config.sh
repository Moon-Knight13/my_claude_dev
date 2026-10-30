#!/usr/bin/env bash
# Tests for scripts/setup-container-ssh.sh — container SSH config generation.
#
# Runs the script against a temp HOME and verifies the generated ~/.ssh/config.
# No network, no prompts, deterministic.
#
# Usage: bash scripts/tests/test-container-ssh-config.sh
# Exit: 0 pass, non-zero = number of failures.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$(dirname "$HERE")/setup-container-ssh.sh"
# shellcheck disable=SC2034  # REPO_ROOT used by sourced scripts
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

fails=0

ok()   { echo "PASS $1"; }
bad()  { echo "FAIL $1: $2"; fails=$((fails + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

run_script() {
    local test_home="$1"; shift
    mkdir -p "$test_home/.ssh"
    (
        export HOME="$test_home"
        export _CLAUDE_ENV_LOADED=1
        "$@" bash "$SCRIPT" 2>&1
    )
}

# --- 1. Skip when HUB_SSH_USER unset ----------------------------------------
test_home="$TMP/t1"
out="$(HUB_SSH_USER="" run_script "$test_home")"
if echo "$out" | grep -q "skipping SSH config generation"; then
    ok skip-when-no-hub-user
else
    bad skip-when-no-hub-user "did not skip: $out"
fi

# --- 2. Full spoke set generates all blocks ----------------------------------
test_home="$TMP/t2"
out="$(
    HUB_SSH_USER=chris \
    SPOKE_DEPLOYBOX_HOST=deploy.example.net \
    SPOKE_DEPLOYBOX_USER=gt \
    SPOKE_DEPLOYBOX_PORT=22 \
    SPOKE_KALI_HOST=10.0.0.5 \
    SPOKE_KALI_USER=root \
    SPOKE_KALI_SSH_PORT=22 \
    RANGE_GIT_HOST=git.example.net \
    RANGE_GIT_USER=gt \
    RANGE_GIT_SSH_PORT=10022 \
    run_script "$test_home"
)"
cfg="$test_home/.ssh/config"
if [[ -f "$cfg" ]] \
   && grep -q "Host hub" "$cfg" \
   && grep -q "User chris" "$cfg" \
   && grep -q "Host deploybox deploy.example.net" "$cfg" \
   && grep -q "ProxyJump hub" "$cfg" \
   && grep -q "Host kali 10.0.0.5" "$cfg" \
   && grep -q "Host range-git git.example.net" "$cfg" \
   && grep -q "ProxyJump deploybox" "$cfg" \
   && grep -q "Port 10022" "$cfg"; then
    ok full-spoke-set
else
    bad full-spoke-set "missing expected blocks:$(printf '\n%s' "$(cat "$cfg" 2>/dev/null)")"
fi

# --- 3. Partial spokes: only deploy box ------------------------------------
test_home="$TMP/t3"
out="$(
    HUB_SSH_USER=chris \
    SPOKE_DEPLOYBOX_HOST=deploy.example.net \
    SPOKE_DEPLOYBOX_USER=gt \
    SPOKE_KALI_HOST="" \
    RANGE_GIT_HOST="" \
    run_script "$test_home"
)"
cfg="$test_home/.ssh/config"
if grep -q "Host deploybox" "$cfg" \
   && ! grep -q "Host kali" "$cfg" \
   && ! grep -q "Host range-git" "$cfg"; then
    ok partial-spokes-deploy-only
else
    bad partial-spokes-deploy-only "unexpected blocks present"
fi

# --- 4. Idempotent: running twice produces same file -------------------------
test_home="$TMP/t4"
HUB_SSH_USER=chris \
SPOKE_DEPLOYBOX_HOST=deploy.example.net \
SPOKE_DEPLOYBOX_USER=gt \
SPOKE_KALI_HOST=10.0.0.5 \
SPOKE_KALI_USER=root \
RANGE_GIT_HOST="" \
    run_script "$test_home" >/dev/null
sum1="$(cksum "$test_home/.ssh/config")"
HUB_SSH_USER=chris \
SPOKE_DEPLOYBOX_HOST=deploy.example.net \
SPOKE_DEPLOYBOX_USER=gt \
SPOKE_KALI_HOST=10.0.0.5 \
SPOKE_KALI_USER=root \
RANGE_GIT_HOST="" \
    run_script "$test_home" >/dev/null
sum2="$(cksum "$test_home/.ssh/config")"
if [[ "$sum1" == "$sum2" ]]; then
    ok idempotent
else
    bad idempotent "second run changed the file"
fi

# --- 5. Update: changed user propagates -----------------------------------
test_home="$TMP/t5"
HUB_SSH_USER=alice SPOKE_DEPLOYBOX_HOST=deploy.example.net run_script "$test_home" >/dev/null
HUB_SSH_USER=bob   SPOKE_DEPLOYBOX_HOST=deploy.example.net run_script "$test_home" >/dev/null
cfg="$test_home/.ssh/config"
if grep -q "User bob" "$cfg" && ! grep -q "User alice" "$cfg"; then
    ok update-replaces-user
else
    bad update-replaces-user "old user not replaced"
fi

# --- 6. Preserves content outside managed block ------------------------------
test_home="$TMP/t6"
mkdir -p "$test_home/.ssh"
cat >"$test_home/.ssh/config" <<'PRE'
Host personal
    HostName personal.example.com
    User me
PRE
HUB_SSH_USER=chris SPOKE_DEPLOYBOX_HOST=deploy.example.net run_script "$test_home" >/dev/null
cfg="$test_home/.ssh/config"
if grep -q "Host personal" "$cfg" && grep -q "Host hub" "$cfg"; then
    ok preserves-existing-content
else
    bad preserves-existing-content "existing content lost"
fi

# --- 7. Permissions are 600 ------------------------------------------------
test_home="$TMP/t7"
HUB_SSH_USER=chris SPOKE_DEPLOYBOX_HOST=deploy.example.net run_script "$test_home" >/dev/null
perms="$(stat -c '%a' "$test_home/.ssh/config")"
if [[ "$perms" == "600" ]]; then
    ok permissions-600
else
    bad permissions-600 "got $perms, expected 600"
fi

# --- 8. ForwardAgent on spokes -------------------------------------------
test_home="$TMP/t8"
HUB_SSH_USER=chris SPOKE_DEPLOYBOX_HOST=deploy.example.net SPOKE_KALI_HOST=10.0.0.5 \
    run_script "$test_home" >/dev/null
cfg="$test_home/.ssh/config"
deploy_block="$(awk '/^Host deploybox/,/^$/' "$cfg")"
kali_block="$(awk '/^Host kali/,/^$/' "$cfg")"
if echo "$deploy_block" | grep -q "ForwardAgent yes" \
   && echo "$kali_block" | grep -q "ForwardAgent yes"; then
    ok forward-agent-on-spokes
else
    bad forward-agent-on-spokes "ForwardAgent missing on spoke blocks"
fi

echo ""
if [[ "$fails" -eq 0 ]]; then
    echo "ALL PASS"
else
    echo "$fails FAILED"
fi
exit "$fails"
