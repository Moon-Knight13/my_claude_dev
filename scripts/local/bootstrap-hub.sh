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
    (echo >/dev/tcp/localhost/22) 2>/dev/null
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
            if ! command -v systemctl >/dev/null 2>&1; then
                fail "No systemctl found. Start sshd manually."
                ERRORS=$((ERRORS + 1))
            else
                if ! sudo systemctl enable --now sshd 2>/dev/null && \
                   ! sudo systemctl enable --now ssh 2>/dev/null && \
                   ! sudo systemctl enable --now ssh.socket 2>/dev/null; then
                    note "sshd not installed. Installing openssh-server..."
                    if command -v apt-get >/dev/null 2>&1; then
                        info "Running: sudo apt-get install -y openssh-server"
                        sudo apt-get install -y openssh-server
                    elif command -v dnf >/dev/null 2>&1; then
                        info "Running: sudo dnf install -y openssh-server"
                        sudo dnf install -y openssh-server
                    elif command -v pacman >/dev/null 2>&1; then
                        info "Running: sudo pacman -S --noconfirm openssh"
                        sudo pacman -S --noconfirm openssh
                    else
                        fail "Unknown package manager. Install openssh-server manually."
                        ERRORS=$((ERRORS + 1))
                    fi
                    if [[ "$ERRORS" -eq 0 ]]; then
                        sudo systemctl enable --now sshd 2>/dev/null || \
                        sudo systemctl enable --now ssh 2>/dev/null || \
                        sudo systemctl enable --now ssh.socket 2>/dev/null || {
                            fail "Installed but could not start sshd."
                            ERRORS=$((ERRORS + 1))
                        }
                    fi
                fi
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

    # Verify it came up (socket activation may need a moment)
    sleep 2
    if ssh_server_running; then
        ok "SSH server now running"
    else
        fail "SSH server still not responding on localhost:22"
        ERRORS=$((ERRORS + 1))
    fi
fi

# ── Step 3: Hub SSH key ───────────────────────────────────────────────────────
# One key per hub machine. Used to authenticate to spokes (deploy box, Kali) and
# to GitLab. Forwarded via agent into the devcontainer and through ProxyJump.
# On the spokes, onward hops to range boxes use the gt account's own keys.
step "Checking hub SSH key"

HOSTNAME_SHORT="$(hostname -s 2>/dev/null || hostname)"
HUB_KEY="$HOME/.ssh/mcd_hub_${HOSTNAME_SHORT}"

if [[ -f "$HUB_KEY" ]]; then
    ok "Hub key exists: $HUB_KEY"
else
    note "No hub key found. Generating..."
    ssh-keygen -t ed25519 -C "mcd-hub-${HOSTNAME_SHORT}" -f "$HUB_KEY" -N "" \
        || ssh-keygen -t ed25519 -C "mcd-hub-${HOSTNAME_SHORT}" -f "$HUB_KEY"
    ok "Generated: $HUB_KEY"
fi

# Ensure key is in agent
if ssh-add -l 2>/dev/null | grep -q "mcd-hub-${HOSTNAME_SHORT}\|${HUB_KEY}"; then
    ok "Hub key loaded in agent"
else
    note "Adding hub key to agent..."
    ssh-add "$HUB_KEY"
    ok "Hub key added to agent"
fi

info "Agent keys:"
ssh-add -l | while read -r line; do note "  $line"; done

# Ensure hub key authorises localhost login (needed for container ProxyJump)
AUTH_KEYS="$HOME/.ssh/authorized_keys"
HUB_PUB="$(cat "${HUB_KEY}.pub")"
if [[ -f "$AUTH_KEYS" ]] && grep -qF "$HUB_PUB" "$AUTH_KEYS"; then
    ok "Hub key already in localhost authorized_keys"
else
    mkdir -p "$HOME/.ssh"
    echo "$HUB_PUB" >> "$AUTH_KEYS"
    chmod 600 "$AUTH_KEYS"
    ok "Hub key added to localhost authorized_keys"
fi

echo ""
info "Public key (add to GitLab profile and spoke authorized_keys):"
echo ""
cat "${HUB_KEY}.pub"
echo ""

# ── Step 4: Load spoke config from .env ───────────────────────────────────────
step "Loading spoke configuration"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

load_env_var() {
    local var_name="$1"
    local default="${2:-}"
    local val=""
    if [[ -f "$REPO_ROOT/.env" ]]; then
        val=$(grep -E "^${var_name}=" "$REPO_ROOT/.env" 2>/dev/null | cut -d= -f2- | tr -d "'\"" || true)
    fi
    echo "${val:-$default}"
}

DEPLOYBOX_HOST="$(load_env_var SPOKE_DEPLOYBOX_HOST)"
DEPLOYBOX_USER="$(load_env_var SPOKE_DEPLOYBOX_USER gt)"
KALI_HOST="$(load_env_var SPOKE_KALI_HOST)"
KALI_USER="$(load_env_var SPOKE_KALI_USER root)"

if [[ -z "$DEPLOYBOX_HOST" && -z "$KALI_HOST" ]]; then
    note "No spoke hosts configured in .env. Fill SPOKE_DEPLOYBOX_HOST and/or"
    note "SPOKE_KALI_HOST to enable VPN check and key distribution."
    note "Skipping spoke steps."
    SKIP_SPOKES=1
else
    SKIP_SPOKES=0
    [[ -n "$DEPLOYBOX_HOST" ]] && ok "Deploy box: ${DEPLOYBOX_USER}@${DEPLOYBOX_HOST}"
    [[ -n "$KALI_HOST" ]] && ok "Kali box: ${KALI_USER}@${KALI_HOST}"
fi

# ── Step 5: VPN check ────────────────────────────────────────────────────────
step "Checking VPN / range connectivity"

if [[ "${SKIP_VPN_CHECK:-0}" == "1" || "$SKIP_SPOKES" == "1" ]]; then
    note "VPN check skipped"
else
    VPN_OK=0
    for spoke_host in "$DEPLOYBOX_HOST" "$KALI_HOST"; do
        [[ -z "$spoke_host" ]] && continue
        if host "$spoke_host" >/dev/null 2>&1; then
            ok "DNS resolves $spoke_host — VPN connected"
            VPN_OK=1
            break
        elif (echo >/dev/tcp/"$spoke_host"/22) 2>/dev/null; then
            ok "TCP reachable $spoke_host:22 — VPN connected (DNS not resolving)"
            VPN_OK=1
            break
        else
            # SSH config may map hostname to a different IP (e.g. via Host/Hostname)
            resolved_ip=$(ssh -G "$spoke_host" 2>/dev/null | awk '/^hostname /{print $2}')
            if [[ -n "$resolved_ip" && "$resolved_ip" != "$spoke_host" ]] && \
               (echo >/dev/tcp/"$resolved_ip"/22) 2>/dev/null; then
                ok "SSH-config resolves $spoke_host to $resolved_ip — VPN connected"
                VPN_OK=1
                break
            fi
        fi
    done
    if [[ "$VPN_OK" -eq 0 ]]; then
        fail "Cannot reach any spoke host — VPN not connected?"
        ERRORS=$((ERRORS + 1))
    fi
fi

# ── Step 6: Copy key to spokes ────────────────────────────────────────────────
step "Distributing hub key to spokes"

if [[ "$SKIP_SPOKES" == "1" ]]; then
    note "No spokes configured. Skipping key distribution."
else
    copy_key_to_spoke() {
        local label="$1" host="$2" user="$3"
        [[ -z "$host" ]] && return

        if ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no -o BatchMode=yes \
            "${user}@${host}" "echo ok" >/dev/null 2>&1; then
            ok "Already authenticated to $label ($host)"
        else
            note "Cannot authenticate to $label ($host)"
            read -rp "  Copy hub key to ${user}@${host}? [y/N] " answer
            if [[ "$answer" =~ ^[Yy] ]]; then
                if ssh-copy-id -i "${HUB_KEY}.pub" "${user}@${host}"; then
                    ok "Key copied to $label"
                else
                    warn "Key copy failed — do it manually"
                fi
            else
                note "Skipped. Copy manually later:"
                note "  ssh-copy-id -i ${HUB_KEY}.pub ${user}@${host}"
            fi
        fi
    }

    copy_key_to_spoke "deploy box" "$DEPLOYBOX_HOST" "$DEPLOYBOX_USER"
    copy_key_to_spoke "Kali box" "$KALI_HOST" "$KALI_USER"

    echo ""
    note "Remember to also add your public key to GitLab:"
    note "  cat ${HUB_KEY}.pub"
    note "  Then paste at your GitLab profile SSH keys page"
fi

# ── Step 7: Docker check ─────────────────────────────────────────────────────
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
