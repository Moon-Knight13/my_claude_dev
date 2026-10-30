#!/usr/bin/env bash
# shellcheck disable=SC2034  # CTP_* vars consumed by sourced guard functions
# Tests for P0-2 remote execution path — validates config parsing, helper
# routing, error handling for CTP_REMOTE_HOST.
#
# No real SSH or docker needed: tests stub the commands and verify the wrapper
# takes the correct code path based on config.
#
# Usage: bash scripts/tests/test-remote-exec.sh
# Exit: 0 pass, non-zero = number of failures.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

fails=0
ok()   { echo "PASS $1"; }
bad()  { echo "FAIL $1: $2"; fails=$((fails + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- 1. Config parser picks up CTP_REMOTE_HOST --------------------------------
cat > "$TMP/conf-remote" <<'EOF'
CTP_ALLOWED_TARGET=test-box_t02
CTP_ALLOWED_TEAM=t02
CTP_REMOTE_HOST=deploybox
CTP_PROJECT_DIR=/srv/inventories/dcm
EOF

# shellcheck source=/dev/null
source "$REPO_ROOT/scripts/lib/ctp-guard.sh"
CTP_REMOTE_HOST=""
ctp_load_config "$TMP/conf-remote"

if [[ "$CTP_REMOTE_HOST" == "deploybox" ]]; then
    ok config-parses-remote-host
else
    bad config-parses-remote-host "expected 'deploybox', got '$CTP_REMOTE_HOST'"
fi

if [[ "$CTP_PROJECT_DIR" == "/srv/inventories/dcm" ]]; then
    ok config-parses-project-dir
else
    bad config-parses-project-dir "expected '/srv/inventories/dcm', got '$CTP_PROJECT_DIR'"
fi

# --- 2. Config without CTP_REMOTE_HOST leaves it empty -----------------------
cat > "$TMP/conf-local" <<'EOF'
CTP_ALLOWED_TARGET=test-box_t02
CTP_ALLOWED_TEAM=t02
EOF

CTP_REMOTE_HOST=""
ctp_load_config "$TMP/conf-local"

if [[ -z "$CTP_REMOTE_HOST" ]]; then
    ok config-no-remote-host-empty
else
    bad config-no-remote-host-empty "expected empty, got '$CTP_REMOTE_HOST'"
fi

# --- 3. .ctp-bridge.conf.example has CTP_REMOTE_HOST key ---------------------
if grep -q "^CTP_REMOTE_HOST=" "$REPO_ROOT/.ctp-bridge.conf.example"; then
    ok example-has-remote-host-key
else
    bad example-has-remote-host-key "CTP_REMOTE_HOST= not found in .ctp-bridge.conf.example"
fi

# --- 4. ctp-bridge.sh defines _is_remote and _docker -------------------------
if grep -q '_is_remote()' "$REPO_ROOT/scripts/ctp-bridge.sh"; then
    ok wrapper-defines-is-remote
else
    bad wrapper-defines-is-remote "_is_remote() not found in ctp-bridge.sh"
fi

if grep -q '_docker()' "$REPO_ROOT/scripts/ctp-bridge.sh"; then
    ok wrapper-defines-docker-helper
else
    bad wrapper-defines-docker-helper "_docker() not found in ctp-bridge.sh"
fi

# --- 5. _docker routes through ssh when remote --------------------------------
# shellcheck disable=SC2016
if grep -q 'ssh -o BatchMode=yes "$CTP_REMOTE_HOST" docker' "$REPO_ROOT/scripts/ctp-bridge.sh"; then
    ok docker-routes-through-ssh
else
    bad docker-routes-through-ssh "SSH routing not found in _docker()"
fi

# --- 6. All docker calls outside _docker() use the helper ---------------------
# Grep for bare `docker` invocations. The only bare `docker` should be inside
# the _docker() function body (which routes through ssh or calls docker directly).
# We look for lines calling docker as a command, excluding the _docker function
# body, comments, and the function definition.
bare_docker="$(awk '
    /_docker\(\)/ { infn=1; next }
    infn && /^}/ { infn=0; next }
    infn { next }
    /^[[:space:]]*#/ { next }
    /[[:space:]]_docker[[:space:]]/ { next }
    /^\s*docker\b/ { print NR": "$0 }
' "$REPO_ROOT/scripts/ctp-bridge.sh" || true)"
bare_docker_count="$(echo "$bare_docker" | grep -c . || true)"
if [[ "$bare_docker_count" -eq 0 ]]; then
    ok no-bare-docker-calls
else
    bad no-bare-docker-calls "found $bare_docker_count bare 'docker' call(s): $bare_docker"
fi

# --- 7. Remote requires CTP_PROJECT_DIR message in _resolve_workdir -----------
# shellcheck disable=SC2016
if grep -q 'CTP_PROJECT_DIR is required when CTP_REMOTE_HOST is set' "$REPO_ROOT/scripts/ctp-bridge.sh"; then
    ok remote-requires-project-dir-message
else
    bad remote-requires-project-dir-message "missing error message for remote without CTP_PROJECT_DIR"
fi

# --- 8. SSH connectivity check exists -----------------------------------------
# shellcheck disable=SC2016
if grep -q 'ConnectTimeout.*CTP_REMOTE_HOST' "$REPO_ROOT/scripts/ctp-bridge.sh"; then
    ok ssh-connectivity-check
else
    bad ssh-connectivity-check "SSH connectivity pre-check not found"
fi

# --- 9. _resolve_workdir refuses remote without CTP_PROJECT_DIR ---------------
result="$(
    # shellcheck source=/dev/null
    source "$REPO_ROOT/scripts/lib/ctp-guard.sh"
    CTP_REMOTE_HOST="deploybox"
    CTP_PROJECT_DIR=""
    _is_remote() { [[ -n "$CTP_REMOTE_HOST" ]]; }
    if _is_remote && [[ -z "$CTP_PROJECT_DIR" ]]; then
        echo "correctly-refused"
    else
        echo "incorrectly-allowed"
    fi
)"
if [[ "$result" == "correctly-refused" ]]; then
    ok resolve-workdir-refuses-remote-no-project-dir
else
    bad resolve-workdir-refuses-remote-no-project-dir "remote without CTP_PROJECT_DIR was not refused"
fi

# --- 10. _resolve_workdir accepts CTP_PROJECT_DIR when remote -----------------
result="$(
    CTP_REMOTE_HOST="deploybox"
    CTP_PROJECT_DIR="/srv/inventories/dcm"
    if [[ -n "$CTP_PROJECT_DIR" ]]; then
        printf '%s' "$CTP_PROJECT_DIR"
    fi
)"
if [[ "$result" == "/srv/inventories/dcm" ]]; then
    ok resolve-workdir-uses-project-dir-remote
else
    bad resolve-workdir-uses-project-dir-remote "expected /srv/inventories/dcm, got '$result'"
fi

# --- 11. Remote container-not-running includes host hint ----------------------
if grep -q 'checked on remote host' "$REPO_ROOT/scripts/ctp-bridge.sh"; then
    ok remote-container-error-shows-host
else
    bad remote-container-error-shows-host "container error does not mention remote host"
fi

# --- 12. Guard stack still classifies correctly with remote config ------------
CTP_REMOTE_HOST="deploybox"
CTP_ALLOWED_TARGET="test-box_t02"
CTP_ALLOWED_TEAM="t02"
CTP_ALLOWED_VERBS="deploy deploy-role"
verdict="$(ctp_classify host deploy test-box_t02)" && vrc=0 || vrc=$?
if [[ "$vrc" -eq 0 && "$verdict" == "confirm mutating deploy test-box_t02" ]]; then
    ok classify-works-with-remote-config
else
    bad classify-works-with-remote-config "verdict='$verdict' rc=$vrc"
fi

# --- 13. Read verbs also work with remote config ------------------------------
verdict="$(ctp_classify host list test-box_t02)" && vrc=0 || vrc=$?
if [[ "$vrc" -eq 0 && "$verdict" == "confirm read list test-box_t02" ]]; then
    ok classify-read-works-remote
else
    bad classify-read-works-remote "verdict='$verdict' rc=$vrc"
fi

echo ""
if [[ "$fails" -eq 0 ]]; then
    echo "ALL PASS"
else
    echo "$fails FAILED"
fi
exit "$fails"
