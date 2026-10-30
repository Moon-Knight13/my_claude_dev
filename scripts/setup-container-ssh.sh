#!/usr/bin/env bash
# setup-container-ssh.sh — generate ~/.ssh/config inside the devcontainer
# from .env spoke variables. Called by project-setup.sh on container start.
#
# Reads SPOKE_* and HUB_SSH_USER from .env (via load-env.sh) and writes SSH
# Host blocks so ProxyJump through host.docker.internal works transparently.
# Idempotent: replaces the managed section on every run, preserves anything
# the user added outside the markers.
#
# Requires: the host ran scripts/local/bootstrap-hub.sh and has an SSH server
# accepting agent-forwarded keys on localhost.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/load-env.sh disable=SC1091
source "$SCRIPT_DIR/lib/load-env.sh"

SSH_DIR="$HOME/.ssh"
SSH_CONFIG="$SSH_DIR/config"
MARKER_BEGIN="# --- BEGIN managed by setup-container-ssh.sh ---"
MARKER_END="# --- END managed by setup-container-ssh.sh ---"

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

HUB_USER="${HUB_SSH_USER:-}"
if [[ -z "$HUB_USER" ]]; then
    echo "  --  HUB_SSH_USER not set in .env — skipping SSH config generation"
    echo "      Set it to your host username so ProxyJump works."
    exit 0
fi

build_config() {
    cat <<EOF
$MARKER_BEGIN

Host hub
    HostName host.docker.internal
    User $HUB_USER
    ForwardAgent yes
    StrictHostKeyChecking accept-new
    ServerAliveInterval 30
    ServerAliveCountMax 3
EOF

    local db_host="${SPOKE_DEPLOYBOX_HOST:-}"
    local db_user="${SPOKE_DEPLOYBOX_USER:-gt}"
    local db_port="${SPOKE_DEPLOYBOX_PORT:-22}"
    if [[ -n "$db_host" ]]; then
        cat <<EOF

Host deploybox $db_host
    HostName $db_host
    User $db_user
    Port $db_port
    ProxyJump hub
    ForwardAgent yes
    StrictHostKeyChecking accept-new
EOF
    fi

    local kali_host="${SPOKE_KALI_HOST:-}"
    local kali_user="${SPOKE_KALI_USER:-root}"
    local kali_port="${SPOKE_KALI_SSH_PORT:-22}"
    if [[ -n "$kali_host" ]]; then
        cat <<EOF

Host kali $kali_host
    HostName $kali_host
    User $kali_user
    Port $kali_port
    ProxyJump hub
    ForwardAgent yes
    StrictHostKeyChecking accept-new
EOF
    fi

    local git_host="${RANGE_GIT_HOST:-}"
    local git_user="${RANGE_GIT_USER:-}"
    local git_port="${RANGE_GIT_SSH_PORT:-10022}"
    if [[ -n "$git_host" && -n "$git_user" ]]; then
        cat <<EOF

Host range-git $git_host
    HostName $git_host
    User $git_user
    Port $git_port
    ProxyJump deploybox
    StrictHostKeyChecking accept-new
EOF
    fi

    echo ""
    echo "$MARKER_END"
}

new_block="$(build_config)"

if [[ -f "$SSH_CONFIG" ]]; then
    if grep -qF "$MARKER_BEGIN" "$SSH_CONFIG"; then
        # Replace existing managed block
        tmp="$(mktemp)"
        awk -v begin="$MARKER_BEGIN" -v end="$MARKER_END" -v block="$new_block" '
            $0 == begin { skip=1; print block; next }
            $0 == end   { skip=0; next }
            !skip       { print }
        ' "$SSH_CONFIG" > "$tmp"
        mv "$tmp" "$SSH_CONFIG"
        echo "  ++  Updated managed SSH config block"
    else
        # Append managed block
        echo "" >> "$SSH_CONFIG"
        echo "$new_block" >> "$SSH_CONFIG"
        echo "  ++  Appended managed SSH config block"
    fi
else
    echo "$new_block" > "$SSH_CONFIG"
    echo "  ++  Created ~/.ssh/config with managed block"
fi

chmod 600 "$SSH_CONFIG"

# Summary
echo "  --  Hub: ${HUB_USER}@host.docker.internal"
# shellcheck disable=SC2015
[[ -n "${SPOKE_DEPLOYBOX_HOST:-}" ]] && echo "  --  Deploy box: ${SPOKE_DEPLOYBOX_USER:-gt}@${SPOKE_DEPLOYBOX_HOST} (via hub)" || true
# shellcheck disable=SC2015
[[ -n "${SPOKE_KALI_HOST:-}" ]] && echo "  --  Kali: ${SPOKE_KALI_USER:-rt}@${SPOKE_KALI_HOST} (via hub)" || true
# shellcheck disable=SC2015
[[ -n "${RANGE_GIT_HOST:-}" && -n "${RANGE_GIT_USER:-}" ]] && echo "  --  Range git: ${RANGE_GIT_USER}@${RANGE_GIT_HOST}:${RANGE_GIT_SSH_PORT:-10022} (via deploybox)" || true
