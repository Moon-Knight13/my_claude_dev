#!/usr/bin/env bash
# setup-killswitch.sh — install the Claude subscription killswitch on a shared
# dev box (Deploybox). Wipes the Claude Code OAuth token from the box whenever
# the target user has no active SSH session, so a personal subscription cannot
# be reused by whoever connects to the shared account next. The user re-`/login`s
# on their next connect.
#
# On a shared account (all devs SSH as the same user, e.g. gt) this is the
# primary control against SEQUENTIAL reuse (you leave -> token wiped -> a later
# connector must log in with their own credentials). It cannot stop concurrent
# sessions sharing the token, and a peer with sudo can disable it — it is a
# hygiene control, not insider-proof. See scripts/host/README.md.
#
# Idempotent; every system change is guarded. Requires sudo. Usage:
#   sudo bash scripts/host/setup-killswitch.sh [--yes] [--user <name>]
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$_SCRIPT_DIR/lib/host-common.sh"

TARGET_USER="${KILLSWITCH_USER:-}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes) export ASSUME_YES=1 ;;
        --user) TARGET_USER="$2"; shift ;;
        *) host_warn "unknown arg: $1" ;;
    esac
    shift
done
# Default to the invoking (non-root) user, not root, when run via sudo.
TARGET_USER="${TARGET_USER:-${SUDO_USER:-$(id -un)}}"

host_step "Killswitch setup for user: $TARGET_USER"

if ! require_sudo; then
    exit 1
fi

TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
if [[ -z "$TARGET_HOME" ]]; then
    host_warn "cannot resolve home dir for $TARGET_USER"; exit 1
fi

WIPE_SCRIPT=/usr/local/sbin/claude-killswitch.sh
PAM_FILE=/etc/pam.d/sshd
KEEPALIVE=/etc/ssh/sshd_config.d/10-killswitch-keepalive.conf

# 1. Install the wipe script (pgrep-only session count — no loginctl fallback,
#    which counts stale `closing` sessions and would block the wipe).
host_step "Installing $WIPE_SCRIPT"
_wipe_tmp="$(mktemp)"
cat > "$_wipe_tmp" <<EOF
#!/bin/sh
# claude-killswitch.sh — wipe the Claude token when TARGET_USER has no live SSH
# session. Installed by scripts/host/setup-killswitch.sh. Idempotent.
set -eu
TARGET_USER=$TARGET_USER
CRED="$TARGET_HOME/.claude/.credentials.json"
LOG=/var/log/claude-killswitch.log

# A live SSH channel always has a \$TARGET_USER-owned sshd child; it dies the
# instant the transport closes. Do NOT use \`loginctl list-sessions\` — it counts
# stale \`closing\` sessions and blocks the wipe.
sessions=\$(pgrep -u "\$TARGET_USER" -x sshd 2>/dev/null | wc -l)

if [ "\$sessions" -gt 0 ]; then
  exit 0
fi

if [ -f "\$CRED" ]; then
  shred -u "\$CRED" 2>/dev/null || rm -f "\$CRED"
  pkill -u "\$TARGET_USER" -f 'native-binary/claude' 2>/dev/null || true
  pkill -u "\$TARGET_USER" -f 'anthropic.claude-code' 2>/dev/null || true
  echo "\$(date -Is) killswitch: wiped \$CRED (0 ssh sessions)" >> "\$LOG"
fi
EOF
$SUDO install -o root -g root -m 0755 "$_wipe_tmp" "$WIPE_SCRIPT"
rm -f "$_wipe_tmp"
$SUDO sh -n "$WIPE_SCRIPT"
host_info "installed + syntax-checked"

# 2. PAM close hook — instant wipe on graceful disconnect (grep-guarded).
host_step "Wiring PAM close hook into $PAM_FILE"
if $SUDO grep -q 'claude-killswitch.sh' "$PAM_FILE"; then
    host_note "already present — skipping"
elif confirm "append pam_exec killswitch line to $PAM_FILE (backup taken)"; then
    $SUDO cp -a "$PAM_FILE" "${PAM_FILE}.bak.killswitch"
    printf '\n# Claude subscription killswitch: wipe token when no SSH session remains\nsession    optional     pam_exec.so %s\n' \
        "$WIPE_SCRIPT" | $SUDO tee -a "$PAM_FILE" >/dev/null
    host_info "appended (backup: ${PAM_FILE}.bak.killswitch)"
else
    host_note "skipped PAM hook"
fi

# 3. systemd timer backstop (30s) for dropped connections.
host_step "Installing systemd service + timer"
_svc="$(mktemp)"; _tmr="$(mktemp)"
cat > "$_svc" <<EOF
[Unit]
Description=Claude subscription killswitch (wipe token when no SSH session remains)

[Service]
Type=oneshot
ExecStart=$WIPE_SCRIPT
EOF
cat > "$_tmr" <<'EOF'
[Unit]
Description=Backstop poll for the Claude subscription killswitch

[Timer]
OnBootSec=30s
OnUnitActiveSec=30s
AccuracySec=5s
Unit=claude-killswitch.service

[Install]
WantedBy=timers.target
EOF
$SUDO install -o root -g root -m 0644 "$_svc" /etc/systemd/system/claude-killswitch.service
$SUDO install -o root -g root -m 0644 "$_tmr" /etc/systemd/system/claude-killswitch.timer
rm -f "$_svc" "$_tmr"
$SUDO systemctl daemon-reload
$SUDO systemctl enable --now claude-killswitch.timer >/dev/null 2>&1 || true
host_info "timer: $($SUDO systemctl is-active claude-killswitch.timer)"

# 4. sshd keepalive so dropped connections are reaped in ~2 min.
host_step "Configuring sshd keepalive ($KEEPALIVE)"
if [[ -f "$KEEPALIVE" ]]; then
    host_note "already present — skipping"
elif confirm "write $KEEPALIVE (ClientAliveInterval 60 / CountMax 2) and reload sshd"; then
    printf '# Detect dropped SSH connections quickly so the killswitch can wipe soon after.\nClientAliveInterval 60\nClientAliveCountMax 2\n' \
        | $SUDO tee "$KEEPALIVE" >/dev/null
    if $SUDO sshd -t; then
        $SUDO systemctl reload ssh 2>/dev/null || $SUDO systemctl reload sshd 2>/dev/null || true
        host_info "keepalive applied + sshd reloaded"
    else
        host_warn "sshd config test failed; removing drop-in"
        $SUDO rm -f "$KEEPALIVE"
    fi
else
    host_note "skipped keepalive"
fi

host_step "Killswitch setup complete for $TARGET_USER"
host_note "verify a wipe after disconnect: sudo tail /var/log/claude-killswitch.log"
