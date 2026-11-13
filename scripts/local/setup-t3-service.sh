#!/usr/bin/env bash
# setup-t3-service.sh — Install and configure T3 Code as a persistent service.
#
# Ensures T3 Code survives reboots and is reachable from mobile devices.
# Run once on a fresh hub, or to repair after a reinstall.
#
# Prerequisites:
#   - t3 CLI installed (~/.local/bin/t3)
#   - systemd (Linux)
#
# What this does:
#   1. Installs T3 as a systemd user service with lingering (survives logout)
#   2. Enables memory protection (OOM killer takes agents, not the server)
#   3. Sets up browser sandbox (for html_render)
#   4. Prompts for T3 Connect sign-in (interactive — enables phone access)
#
# After running:
#   - T3 starts at boot automatically
#   - Install T3 Code mobile app (iOS/Android)
#   - Sign in with same T3 account
#   - Hub appears as environment on phone
#
# Remote access options (configured after install):
#   - T3 Connect: tunneled, no VPN needed, works anywhere
#   - Tailscale: direct, encrypted, requires tailnet setup
#   - LAN pairing: local network only, QR code
#
# Security notes:
#   - T3 Connect routes through T3 relay servers
#   - Fine for base/platform-ops/homelab work
#   - For red-team OPSEC work, prefer Tailscale (direct, no relay)
#   - Pairing tokens are credentials — treat like SSH keys
#   - Use --scope for read-only phone access: t3 pair --scope orchestration:read
set -euo pipefail

command -v t3 >/dev/null 2>&1 || { echo "ERROR: t3 CLI not found. Install from https://t3.codes"; exit 1; }

echo "=== T3 Code Service Setup ==="
echo ""

# Step 1: Install service
echo "[1/4] Installing T3 background service..."
if t3 service status 2>&1 | grep -q "not installed"; then
    t3 service install
else
    echo "  Already installed."
    t3 service status
fi
echo ""

# Step 2: Memory protection (interactive — needs sudo)
echo "[2/4] Memory protection..."
echo "  Run manually: t3 service protect"
echo "  (Needs sudo, say 'y' to also protect SSH)"
echo ""

# Step 3: Browser sandbox (for html_render)
echo "[3/4] Browser sandbox..."
echo "  Run manually if on Ubuntu 23.10+:"
echo "    sudo env \"PATH=\$PATH\" t3 browser setup --base-dir ~/.t3"
echo ""

# Step 4: T3 Connect
echo "[4/4] T3 Connect (phone/remote access)..."
echo "  Run manually: t3 up"
echo "  This prompts browser sign-in to your T3 account."
echo "  After sign-in, install T3 Code mobile app and sign in with same account."
echo ""

echo "=== Service Status ==="
t3 service status
echo ""
echo "Done. Interactive steps (protect, browser setup, t3 up) must be run manually."
echo "See docs: https://github.com/pingdotgg/t3code/blob/main/docs/user/remote-access.md"
