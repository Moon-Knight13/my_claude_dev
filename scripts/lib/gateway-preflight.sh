#!/usr/bin/env bash
# gateway-preflight.sh — exercise zone gateway reachability check.
#
# Source this file, then call check_gateway_reachable. Returns 0 if the
# gateway responds to ICMP, 1 if unreachable or unconfigured.
#
# Usage:
#   source "$SCRIPT_DIR/lib/gateway-preflight.sh"
#   check_gateway_reachable || { echo "Gateway down"; exit 1; }
#
# Requires: RANGE_GATEWAY_HOST set in .env (the fw1-mil management IP).
# Mode scope: green-dev, platform-ops (ICMP to fw1-mil is not an OPSEC concern).

# Source load-env.sh if not already loaded.
if [[ -z "${_CLAUDE_ENV_LOADED:-}" ]]; then
    _gw_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=scripts/lib/load-env.sh
    source "$_gw_lib_dir/load-env.sh"
    unset _gw_lib_dir
fi

check_gateway_reachable() {
    local host="${RANGE_GATEWAY_HOST:-}"
    local timeout="${1:-3}"

    if [[ -z "$host" ]]; then
        echo " SKIP Exercise zone gateway — RANGE_GATEWAY_HOST not set"
        return 1
    fi

    if ping -c 1 -W "$timeout" "$host" >/dev/null 2>&1; then
        echo "  OK  Exercise zone gateway ($host) reachable"
        return 0
    else
        echo " FAIL Exercise zone gateway ($host) unreachable"
        echo "      -> Check VPN connection and fw1-mil status"
        echo "      -> Do NOT investigate routing until gateway responds"
        return 1
    fi
}
