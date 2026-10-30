#!/usr/bin/env bash
# bootstrap-hub.sh — run on the OPERATOR'S laptop before launching the
# devcontainer. Prepares the host as a hub for spoke connectivity: the
# devcontainer reaches range systems via SSH ProxyJump through this host.
#
# What it does:
#   1. Detects OS and enables the SSH server (one-time, persists across reboots)
#   2. Verifies SSH server is accepting connections on localhost
#   3. Verifies SSH agent has at least one key loaded
#   4. Optionally checks VPN connectivity to the range
#   5. Prints a spoke readiness summary
#
# Nothing sensitive is written to the repo. The SSH server runs on localhost
# and accepts only key-based auth by default on all modern OSes.
#
# Idempotent. Usage:
#   bash scripts/local/bootstrap-hub.sh
#
# Pre-set env vars for non-interactive use:
#   SKIP_VPN_CHECK=1 bash scripts/local/bootstrap-hub.sh
set -euo pipefail

info()  { echo "  ++  $*"; }
note()  { echo "  --  $*"; }
warn()  { echo "  !!  $*" >&2; }
step()  { echo ""; echo ">> $*"; }
ok()    { echo "  ✓   $*"; }
fail()  { echo "  ✗   $*" >&2; }

ERRORS=0

# ── Step 1: Detect OS ────────────────────────────────────────────────────────
step "Detecting operating system"
OS="unknown"
case "$(uname -s)" in
    Darwin)  OS="macos"   ;;
    Linux)   OS="linux"   ;;
    MINGW*|MSYS*|CYGWIN*) OS="windows" ;;
esac

if [[ "$OS" == "unknown" ]]; then
    fail "Unsupported OS: $(uname -s)"
    exit 1
fi
ok "Detected: $OS"

# ── Step 2: Enable SSH server ─────────────────────────────────────────────────
step "Checking SSH server"

ssh_server_running() {
    ssh -o ConnectTimeout=2 -o StrictHostKeyChecking=no -o BatchMode=yes \
        localhost "echo ok" >/dev/null 2>&1
}

if ssh_server_running; then
    ok "SSH server already running on localhost"
else
    note "SSH server not running. Enabling..."
    case "$OS" in
        macos)
            info "Running: sudo systemsetup -setremotelogin on"
            sudo systemsetup -setremotelogin on
            ;;
        linux)
            if command -v systemctl >/dev/null 2>&1; then
                info "Running: sudo systemctl enable --now sshd"
                sudo systemctl enable --now sshd 2>/dev/null || \
                sudo systemctl enable --now ssh 2>/dev/null || {
                    fail "Could not start sshd. Install openssh-server:"
                    fail "  Ubuntu/Debian: sudo apt install openssh-server"
                    fail "  Fedora/RHEL:   sudo dnf install openssh-server"
                    ERRORS=$((ERRORS + 1))
                }
            else
                fail "No systemctl found. Start sshd manually."
                ERRORS=$((ERRORS + 1))
            fi
            ;;
        windows)
            fail "Windows detected. Run in PowerShell (Admin):"
            fail "  Set-Service sshd -StartupType Automatic"
            fail "  Start-Service sshd"
            fail "Then re-run this script."
            ERRORS=$((ERRORS + 1))
            ;;
    esac

    # Verify it came up
    sleep 1
    if ssh_server_running; then
        ok "SSH server now running"
    else
        fail "SSH server still not responding on localhost:22"
        ERRORS=$((ERRORS + 1))
    fi
fi

# ── Step 3: SSH agent ─────────────────────────────────────────────────────────
step "Checking SSH agent"

if ssh-add -l >/dev/null 2>&1; then
    KEY_COUNT=$(ssh-add -l | wc -l | tr -d ' ')
    ok "SSH agent has $KEY_COUNT key(s) loaded"
    ssh-add -l | while read -r line; do note "  $line"; done
else
    fail "No keys in SSH agent. Add your key:"
    fail "  ssh-add ~/.ssh/id_ed25519"
    ERRORS=$((ERRORS + 1))
fi

# ── Step 4: VPN check (optional) ──────────────────────────────────────────────
step "Checking VPN / range connectivity"

if [[ "${SKIP_VPN_CHECK:-0}" == "1" ]]; then
    note "VPN check skipped (SKIP_VPN_CHECK=1)"
else
    # Try to resolve a range hostname. Use SPOKE_DEPLOYBOX_HOST from .env if set,
    # otherwise ask. Do NOT hardcode any range domain (public repo).
    SPOKE_HOST="${SPOKE_DEPLOYBOX_HOST:-}"
    if [[ -z "$SPOKE_HOST" ]]; then
        # Try loading from .env in repo root
        SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
        if [[ -f "$REPO_ROOT/.env" ]]; then
            SPOKE_HOST=$(grep -E "^SPOKE_DEPLOYBOX_HOST=" "$REPO_ROOT/.env" 2>/dev/null | cut -d= -f2- | tr -d "'\"" || true)
        fi
    fi

    if [[ -z "$SPOKE_HOST" ]]; then
        note "No SPOKE_DEPLOYBOX_HOST set. Skipping VPN check."
        note "Set it in .env or export it to enable this check."
    else
        if host "$SPOKE_HOST" >/dev/null 2>&1; then
            ok "DNS resolves $SPOKE_HOST — VPN appears connected"
            # Try SSH connection
            if ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no -o BatchMode=yes \
                "${SPOKE_DEPLOYBOX_USER:-gt}@${SPOKE_HOST}" "echo ok" >/dev/null 2>&1; then
                ok "SSH to deploy box works from host"
            else
                note "DNS resolves but SSH failed — check credentials or box status"
            fi
        else
            fail "Cannot resolve $SPOKE_HOST — VPN not connected or wrong hostname"
            ERRORS=$((ERRORS + 1))
        fi
    fi
fi

# ── Step 5: Docker check ─────────────────────────────────────────────────────
step "Checking Docker"

if command -v docker >/dev/null 2>&1; then
    if docker info >/dev/null 2>&1; then
        ok "Docker is running"
    else
        fail "Docker installed but not running. Start Docker Desktop."
        ERRORS=$((ERRORS + 1))
    fi
else
    fail "Docker not found. Install Docker Desktop."
    ERRORS=$((ERRORS + 1))
fi

# ── Summary ───────────────────────────────────────────────────────────────────
step "Hub readiness summary"
echo ""
if [[ "$ERRORS" -eq 0 ]]; then
    ok "All checks passed. Ready to launch devcontainer."
    echo ""
    note "Next: open this repo in VS Code and Reopen in Container"
    note "Spokes will be reachable via SSH ProxyJump through host.docker.internal"
else
    fail "$ERRORS check(s) failed. Fix the issues above and re-run."
    exit 1
fi
