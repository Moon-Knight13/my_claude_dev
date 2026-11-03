#!/usr/bin/env bash
# post-start.sh — devcontainer postStartCommand runner.
#
# Runs each provisioning script quietly. On success: one-line summary.
# On failure: dumps that script's full output for debugging.
# Set DEVCONTAINER_VERBOSE=1 in .env for full output from all scripts.
set -uo pipefail

VERBOSE="${DEVCONTAINER_VERBOSE:-0}"
LOGDIR="/tmp/devcontainer-start"
mkdir -p "$LOGDIR"

passed=0
failed=0
warnings=""

run_step() {
    local label="$1"; shift
    local logfile="$LOGDIR/${label//[^a-zA-Z0-9_-]/_}.log"

    if [[ "$VERBOSE" == "1" ]]; then
        echo "── $label ──"
        "$@" 2>&1 | tee "$logfile"
        local rc=${PIPESTATUS[0]}
    else
        "$@" > "$logfile" 2>&1
        local rc=$?
    fi

    if (( rc == 0 )); then
        ((passed++))
        [[ "$VERBOSE" != "1" ]] && echo "  OK  $label"
    else
        ((failed++))
        warnings="${warnings}\n  FAIL  $label (exit $rc)"
        if [[ "$VERBOSE" != "1" ]]; then
            echo "  FAIL  $label (exit $rc) — output:"
            sed 's/^/    | /' "$logfile"
        fi
    fi
    return 0
}

echo "Provisioning devcontainer..."

if [ -z "${DOCKER_HOST_NETWORK:-}" ]; then
    run_step "firewall"          sudo /usr/local/bin/init-firewall.sh
else
    echo "  ⊘ firewall: skipped (host networking)"
fi
run_step "caveman"           bash scripts/install-caveman.sh
run_step "bmad-install"      bash scripts/install-bmad.sh
run_step "bmad-bootstrap"    bash scripts/bootstrap-bmad.sh
run_step "pre-commit"        bash scripts/bootstrap-precommit.sh
run_step "claude-plugins"    bash scripts/install-claude-plugins.sh
run_step "tuoni-mcp"         bash scripts/install-tuoni-mcp.sh
run_step "mcp-servers"       bash scripts/setup-mcp-servers.sh
run_step "day0-check"        bash scripts/setup-day0.sh
run_step "project-setup"     bash scripts/project-setup.sh

echo ""
if (( failed == 0 )); then
    echo "Devcontainer ready. $passed/$((passed+failed)) steps passed."
else
    echo "Devcontainer started with issues. $passed passed, $failed failed."
    echo -e "$warnings"
    echo ""
    echo "Full logs in $LOGDIR/. Set DEVCONTAINER_VERBOSE=1 in .env for verbose output."
fi
