#!/usr/bin/env bash
# check-host-prereqs.sh — validate host-side prerequisites before devcontainer start.
#
# Runs on the HOST via devcontainer.json initializeCommand. Checks that the
# host's DNS and networking are configured so the container can reach range
# services through Docker's embedded DNS.
#
# Exit 0: all checks pass or are not applicable (no VPN, no spokes configured).
# Exit 1: a required prerequisite is missing and the container would fail.
set -uo pipefail

warn()  { echo "WARNING: $*"; }
fail()  { echo "FAIL: $*"; FAILED=1; }
FAILED=0

# Only check if spokes are configured — if .env has no spoke hosts, range
# connectivity is not expected and there is nothing to validate.
ENV_FILE="${1:-.env}"
if [[ ! -f "$ENV_FILE" ]]; then
    echo "check-host-prereqs: no .env file, skipping range checks."
    exit 0
fi

has_spokes=0
while IFS='=' read -r key value; do
    [[ "$key" =~ ^[[:space:]]*# ]] && continue
    [[ -z "$value" ]] && continue
    case "$key" in
        SPOKE_*_HOST|RANGE_GIT_HOST|PROVIDENTIA_HOST|OUTLINE_HOST)
            has_spokes=1; break ;;
    esac
done < "$ENV_FILE"

if (( ! has_spokes )); then
    echo "check-host-prereqs: no spoke hosts in .env, skipping range checks."
    exit 0
fi

echo "check-host-prereqs: spoke hosts configured, validating host DNS..."

# 1. Check systemd-resolved stub listener on Docker bridge.
#    Without this, the container's --dns 172.17.0.1 has nothing to talk to.
DOCKER_BRIDGE_IP=$(ip -4 addr show docker0 2>/dev/null | grep -oP 'inet \K[0-9.]+')
if [[ -z "$DOCKER_BRIDGE_IP" ]]; then
    warn "docker0 interface not found — Docker may not be running."
else
    if ss -ulnp 2>/dev/null | grep -q "${DOCKER_BRIDGE_IP}:53"; then
        echo "  OK: systemd-resolved listening on ${DOCKER_BRIDGE_IP}:53"
    else
        fail "systemd-resolved is not listening on ${DOCKER_BRIDGE_IP}:53.
    The container uses --dns ${DOCKER_BRIDGE_IP} to reach the host's split-DNS
    resolver, but nothing is listening there. Fix:

      sudo mkdir -p /etc/systemd/resolved.conf.d
      echo -e '[Resolve]\nDNSStubListenerExtra=${DOCKER_BRIDGE_IP}' \\
        | sudo tee /etc/systemd/resolved.conf.d/docker-dns.conf
      sudo systemctl restart systemd-resolved"
    fi
fi

# 2. Check that at least one range hostname resolves via the Docker bridge listener.
#    This validates that split-DNS is configured on the VPN link.
test_host=""
while IFS='=' read -r key value; do
    [[ "$key" =~ ^[[:space:]]*# ]] && continue
    [[ -z "$value" ]] && continue
    # Strip scheme and trailing slash.
    value="${value#https://}"; value="${value#http://}"; value="${value%/}"
    # Skip raw IPs — they don't need DNS.
    [[ "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && continue
    case "$key" in
        SPOKE_*_HOST|RANGE_GIT_HOST|PROVIDENTIA_HOST|OUTLINE_HOST)
            test_host="$value"; break ;;
    esac
done < "$ENV_FILE"

if [[ -n "$test_host" ]]; then
    if [[ -n "$DOCKER_BRIDGE_IP" ]]; then
        resolved=$(dig +short +timeout=3 "@${DOCKER_BRIDGE_IP}" A "$test_host" 2>/dev/null | grep -E '^[0-9]+\.' | head -1)
    else
        resolved=$(dig +short +timeout=3 A "$test_host" 2>/dev/null | grep -E '^[0-9]+\.' | head -1)
    fi
    if [[ -n "$resolved" ]]; then
        echo "  OK: $test_host resolves to $resolved via ${DOCKER_BRIDGE_IP:-system DNS}"
    else
        fail "$test_host does not resolve via ${DOCKER_BRIDGE_IP:-system DNS}.
    VPN split-DNS is not configured. The container will not be able to
    resolve range hostnames. Ensure the VPN is connected and split-DNS
    is set on the VPN interface:

      sudo resolvectl dns <vpn-interface> <range-dns-ip-1> <range-dns-ip-2>
      sudo resolvectl domain <vpn-interface> <range-domain-1> <range-domain-2>"
    fi
fi

if (( FAILED )); then
    echo ""
    echo "Host prerequisites check FAILED. The devcontainer will not have"
    echo "range connectivity. Fix the issues above or unset spoke hosts in"
    echo ".env to skip range checks."
    exit 1
fi

echo "check-host-prereqs: all checks passed."
exit 0
