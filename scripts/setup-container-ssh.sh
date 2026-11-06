#!/usr/bin/env bash
# setup-container-ssh.sh — generate ~/.ssh/config spoke aliases from .env.
#
# Works in TWO modes:
#   Container: ProxyJump through hub (host.docker.internal / 127.0.0.1).
#              Called by project-setup.sh on container start.
#   Host:      Direct to deploybox (VPN), kali/range-git via deploybox.
#              Called by host-setup.sh. No hub hop needed (host IS hub).
#
# Reads SPOKE_* and HUB_SSH_USER from .env (via load-env.sh) and writes SSH
# Host blocks. Idempotent: replaces the managed section on every run,
# preserves anything the user added outside the markers.
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

# Detect surface: host or container
if [[ "${DEVCONTAINER:-}" == "true" ]]; then
    SURFACE="container"
    # Resolve hub hostname: host.docker.internal when available, else 127.0.0.1
    if getent hosts host.docker.internal &>/dev/null; then
        HUB_HOSTNAME="host.docker.internal"
    else
        HUB_HOSTNAME="127.0.0.1"
    fi
    HUB_USER="${HUB_SSH_USER:-}"
    if [[ -z "$HUB_USER" ]]; then
        echo "  --  HUB_SSH_USER not set in .env — skipping SSH config generation"
        echo "      Set it to your host username so ProxyJump works."
        exit 0
    fi
else
    SURFACE="host"
fi

build_config() {
    cat <<EOF
$MARKER_BEGIN
# Surface: $SURFACE
EOF

    # Hub block: container only (host IS the hub)
    if [[ "$SURFACE" == "container" ]]; then
        cat <<EOF

Host hub
    HostName $HUB_HOSTNAME
    User $HUB_USER
    ForwardAgent yes
    StrictHostKeyChecking accept-new
    ServerAliveInterval 30
    ServerAliveCountMax 3
EOF
    fi

    local db_host="${SPOKE_DEPLOYBOX_HOST:-}"
    local db_user="${SPOKE_DEPLOYBOX_USER:-gt}"
    local db_port="${SPOKE_DEPLOYBOX_PORT:-22}"
    if [[ -n "$db_host" ]]; then
        # Container: ProxyJump through hub. Host: direct (VPN access).
        local db_proxy=""
        [[ "$SURFACE" == "container" ]] && db_proxy="    ProxyJump hub"
        cat <<EOF

Host deploybox $db_host
    HostName $db_host
    User $db_user
    Port $db_port
${db_proxy:+$db_proxy
}    ForwardAgent yes
    StrictHostKeyChecking accept-new
EOF
    fi

    local kali_host="${SPOKE_KALI_HOST:-}"
    local kali_user="${SPOKE_KALI_USER:-root}"
    local kali_port="${SPOKE_KALI_SSH_PORT:-22}"
    if [[ -n "$kali_host" ]]; then
        # Container: ProxyJump through hub. Host: direct (VPN).
        # Kali is reachable from host without deploybox — same as container
        # going through hub directly. Keeps kali alive if deploybox is removed.
        local kali_proxy=""
        [[ "$SURFACE" == "container" ]] && kali_proxy="    ProxyJump hub"
        cat <<EOF

Host kali $kali_host
    HostName $kali_host
    User $kali_user
    Port $kali_port
${kali_proxy:+$kali_proxy
}    ForwardAgent yes
    StrictHostKeyChecking accept-new
EOF
    fi

    local git_host="${RANGE_GIT_HOST:-}"
    git_host="${git_host#https://}"
    git_host="${git_host#http://}"
    git_host="${git_host%/}"
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
if [[ "$SURFACE" == "container" ]]; then
    echo "  --  Hub: ${HUB_USER}@${HUB_HOSTNAME}"
    local_via="via hub"
else
    echo "  --  Surface: host (no hub hop)"
    local_via="direct"
fi
# shellcheck disable=SC2015
[[ -n "${SPOKE_DEPLOYBOX_HOST:-}" ]] && echo "  --  Deploy box: ${SPOKE_DEPLOYBOX_USER:-gt}@${SPOKE_DEPLOYBOX_HOST} ($local_via)" || true
# shellcheck disable=SC2015
if [[ -n "${SPOKE_KALI_HOST:-}" ]]; then
    if [[ "$SURFACE" == "container" ]]; then
        echo "  --  Kali: ${SPOKE_KALI_USER:-rt}@${SPOKE_KALI_HOST} (via hub)"
    else
        echo "  --  Kali: ${SPOKE_KALI_USER:-rt}@${SPOKE_KALI_HOST} (direct)"
    fi
fi
# shellcheck disable=SC2015
[[ -n "${RANGE_GIT_HOST:-}" && -n "${RANGE_GIT_USER:-}" ]] && echo "  --  Range git: ${RANGE_GIT_USER}@${RANGE_GIT_HOST}:${RANGE_GIT_SSH_PORT:-10022} (via deploybox)" || true
