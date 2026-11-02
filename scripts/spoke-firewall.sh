#!/usr/bin/env bash
# spoke-firewall.sh — add spoke IPs to container firewall allow-list.
#
# Reads spoke/range-service host vars from .env and adds each IP to the
# allowed-domains ipset. Handles both raw IPs and hostnames (resolved via dig).
# Idempotent: ipset add -exist is a no-op for duplicates.
#
# Usage: bash scripts/spoke-firewall.sh
# Exit:  0 always (partial connectivity is fine; errors are warnings).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/load-env.sh
source "$SCRIPT_DIR/lib/load-env.sh"

SPOKE_VARS=(
    SPOKE_DEPLOYBOX_HOST
    SPOKE_KALI_HOST
    RANGE_GIT_HOST
    PROVIDENTIA_HOST
    OUTLINE_HOST
)

added=0
for var in "${SPOKE_VARS[@]}"; do
    host="${!var:-}"
    [[ -z "$host" ]] && continue

    ip="$host"
    if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        resolved=$(dig +short A "$host" 2>/dev/null | grep -E '^[0-9]+\.' | head -1)
        if [[ -z "$resolved" ]]; then
            echo "WARNING: $var='$host' — cannot resolve to IP, skipping"
            continue
        fi
        ip="$resolved"
    fi

    if ipset add -exist allowed-domains "$ip" 2>/dev/null; then
        echo "Allowed spoke: $var=$ip"
        ((added++))
    else
        echo "WARNING: $var=$ip — ipset add failed (ipset missing?)"
    fi
done

echo "spoke-firewall: $added spoke IPs added to allowed-domains"
