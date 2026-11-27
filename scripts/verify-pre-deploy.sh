#!/usr/bin/env bash
# verify-pre-deploy.sh — liveness probe before any deploy/mutation action.
#
# Safety gate: confirms spoke is reachable and in a known state before
# ctp-bridge or any deploy script pushes changes. Designed to be called
# by other scripts (ctp-bridge, deploy-tuoni-plugins.sh, etc.) or manually.
#
# Usage:
#   bash scripts/verify-pre-deploy.sh <spoke>
#   bash scripts/verify-pre-deploy.sh kali
#   bash scripts/verify-pre-deploy.sh deploybox
#
# Exit codes:
#   0 = spoke reachable, safe to proceed
#   1 = spoke unreachable or degraded, do NOT deploy
#   3 = usage error
#
# Integration:
#   source scripts/verify-pre-deploy.sh  (for verify_spoke_ready function)
#   verify_spoke_ready "kali" || exit 1
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Sourceable function ──────────────────────────────────────────────────────
verify_spoke_ready() {
    local spoke="${1:?spoke name required}"
    local verify_script="$SCRIPT_DIR/verify-spoke-health.sh"

    if [[ ! -x "$verify_script" ]]; then
        echo " FAIL verify-spoke-health.sh not found or not executable" >&2
        return 1
    fi

    local result
    result="$(bash "$verify_script" "$spoke" --json --quiet 2>/dev/null)" || true

    if [[ -z "$result" ]]; then
        echo " FAIL pre-deploy: could not run health check for $spoke" >&2
        return 1
    fi

    local status
    status="$(echo "$result" | python3 -I -c "import sys,json; print(json.load(sys.stdin).get('status','unknown'))" 2>/dev/null)" || status="unknown"

    case "$status" in
        healthy)
            echo "  OK  pre-deploy: $spoke is healthy — safe to proceed"
            return 0
            ;;
        degraded)
            echo " WARN pre-deploy: $spoke is degraded" >&2
            # Show which checks failed
            echo "$result" | python3 -I -c "
import sys, json
data = json.load(sys.stdin)
for c in data.get('checks', []):
    if c['result'] != 'ok':
        print(f\"      {c['result'].upper()}: {c['name']} — {c['detail']}\", file=sys.stderr)
" 2>&1 || true
            echo "      Deploy blocked. Fix issues or set FORCE_DEPLOY=true to override." >&2

            if [[ "${FORCE_DEPLOY:-}" == "true" ]]; then
                echo " WARN pre-deploy: FORCE_DEPLOY=true — proceeding despite degraded state" >&2
                return 0
            fi
            return 1
            ;;
        down|*)
            echo " FAIL pre-deploy: $spoke is ${status} — deploy refused" >&2
            return 1
            ;;
    esac
}

# ── Direct invocation ────────────────────────────────────────────────────────
# When sourced, only the function is defined. When run directly, execute it.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    SPOKE="${1:-}"
    if [[ -z "$SPOKE" ]]; then
        echo "Usage: $(basename "$0") <spoke>" >&2
        echo "Spokes: kali, deploybox" >&2
        exit 3
    fi

    verify_spoke_ready "$SPOKE"
    exit $?
fi
