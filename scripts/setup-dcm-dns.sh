#!/usr/bin/env bash
# Bind range DNS servers to DCM interface.
# Must run after each reboot or VPN reconnect — resolvectl settings are ephemeral.
# Persistent fix: add [Resolve] entries via systemd-networkd or NetworkManager dispatcher.
set -euo pipefail

IFACE="DCM"
DNS1="172.21.19.11"
DNS2="172.21.19.12"
DOMAIN="crp.cr14.net"
TEST_HOST="git.${DOMAIN}"

if ! ip link show "$IFACE" &>/dev/null; then
    echo "ERROR: interface $IFACE does not exist. Is WireGuard/VPN connected?" >&2
    exit 1
fi

echo "Binding DNS $DNS1 $DNS2 to $IFACE..."
sudo resolvectl dns "$IFACE" "$DNS1" "$DNS2"

echo "Setting search domain $DOMAIN on $IFACE..."
sudo resolvectl domain "$IFACE" "$DOMAIN"

echo ""
echo "Current state:"
resolvectl status "$IFACE"

echo ""
echo "Verifying resolution..."
if host "$TEST_HOST" &>/dev/null; then
    resolved="$(host "$TEST_HOST" | head -1)"
    echo "OK: $resolved"
else
    echo "WARN: $TEST_HOST did not resolve. DNS servers may be unreachable." >&2
    exit 1
fi
