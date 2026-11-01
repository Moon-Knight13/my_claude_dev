#!/usr/bin/env bash
# visual-spoke.sh — Manage SOCKS tunnel for operator GUI access to targets.
#
# Sets up SSH dynamic port forwarding through kali spoke so the operator's
# host RDP/VNC client can reach range targets. The devcontainer provides
# the tunnel; the operator's host provides the GUI client.
#
# Architecture:
#   [Host RDP/VNC client] → localhost:SOCKS_PORT → [devcontainer] →
#   SSH tunnel → [kali spoke] → target RDP/VNC
#
# Usage:
#   bash scripts/visual-spoke.sh up              # start SOCKS tunnel
#   bash scripts/visual-spoke.sh down             # stop SOCKS tunnel
#   bash scripts/visual-spoke.sh status           # check tunnel health
#   bash scripts/visual-spoke.sh test <target-ip> # test connectivity to target
#   bash scripts/visual-spoke.sh info             # print connection instructions
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load env if available
[[ -f "$HERE/lib/load-env.sh" ]] && source "$HERE/lib/load-env.sh"

# ── Config ────────────────────────────────────────────────────────────────
SOCKS_PORT="${SPOKE_KALI_SOCKS_PORT:-1080}"
SOCKS_BIND="${SOCKS_BIND:-0.0.0.0}"
KALI_HOST="${SPOKE_KALI_HOST:-kali}"
PIDFILE="${HOME}/.visual-spoke.pid"
LOGFILE="${HOME}/.visual-spoke.log"

# ── Helpers ───────────────────────────────────────────────────────────────
readonly RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' CYAN='\033[0;36m' NC='\033[0m'

is_running() {
    [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null
}

get_pid() {
    [[ -f "$PIDFILE" ]] && cat "$PIDFILE"
}

# ── Commands ──────────────────────────────────────────────────────────────
cmd_up() {
    if is_running; then
        printf "${YELLOW}SOCKS tunnel already running (PID %s) on port %s${NC}\n" "$(get_pid)" "$SOCKS_PORT"
        return 0
    fi

    # Verify kali spoke is reachable
    if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "$KALI_HOST" true 2>/dev/null; then
        printf "${RED}Cannot reach kali spoke at %s${NC}\n" "$KALI_HOST"
        echo "Check SSH config and VPN connectivity."
        return 1
    fi

    # Check port not in use
    if ss -tlnp 2>/dev/null | grep -q ":${SOCKS_PORT} " || \
       netstat -tlnp 2>/dev/null | grep -q ":${SOCKS_PORT} "; then
        printf "${RED}Port %s already in use${NC}\n" "$SOCKS_PORT"
        return 1
    fi

    echo "Starting SOCKS5 tunnel through ${KALI_HOST}:${SOCKS_PORT}..."

    # SSH dynamic port forward — binds to all interfaces so host can reach it.
    # -N: no remote command. -f: background. -D: SOCKS proxy.
    ssh -o ServerAliveInterval=30 \
        -o ServerAliveCountMax=3 \
        -o ExitOnForwardFailure=yes \
        -o StrictHostKeyChecking=accept-new \
        -N -f \
        -D "${SOCKS_BIND}:${SOCKS_PORT}" \
        "$KALI_HOST" \
        2>"$LOGFILE"

    # Find the SSH process
    sleep 1
    local pid
    pid=$(pgrep -f "ssh.*-D.*${SOCKS_PORT}.*${KALI_HOST}" | head -1)
    if [[ -n "$pid" ]]; then
        echo "$pid" > "$PIDFILE"
        printf "${GREEN}SOCKS tunnel UP — PID %s, port %s${NC}\n" "$pid" "$SOCKS_PORT"
        cmd_info
    else
        printf "${RED}Tunnel failed to start. Check %s${NC}\n" "$LOGFILE"
        return 1
    fi
}

cmd_down() {
    if ! is_running; then
        echo "No tunnel running."
        rm -f "$PIDFILE"
        return 0
    fi

    local pid
    pid=$(get_pid)
    kill "$pid" 2>/dev/null
    rm -f "$PIDFILE"
    printf "${GREEN}SOCKS tunnel stopped (was PID %s)${NC}\n" "$pid"
}

cmd_status() {
    if is_running; then
        local pid
        pid=$(get_pid)
        printf "${GREEN}UP${NC}  PID %s, SOCKS5 on %s:%s via %s\n" "$pid" "$SOCKS_BIND" "$SOCKS_PORT" "$KALI_HOST"

        # Test the SOCKS proxy responds
        if command -v curl >/dev/null 2>&1; then
            if curl -s --socks5 "127.0.0.1:${SOCKS_PORT}" --connect-timeout 3 "http://127.0.0.1/" >/dev/null 2>&1; then
                printf '%b%s%b\n' "${GREEN}" "SOCKS proxy accepting connections" "${NC}"
            else
                printf '%b%s%b\n' "${YELLOW}" "SOCKS proxy may be degraded" "${NC}"
            fi
        fi
    else
        printf '%bDOWN%b  No tunnel running\n' "${RED}" "${NC}"
        [[ -f "$PIDFILE" ]] && rm -f "$PIDFILE"
        return 1
    fi
}

cmd_test() {
    local target="${1:-}"
    if [[ -z "$target" ]]; then
        echo "Usage: visual-spoke.sh test <target-ip> [port]"
        return 1
    fi
    local port="${2:-3389}"

    # Validate target: IP address or hostname only (no shell metacharacters)
    if [[ ! "$target" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        echo "Invalid target: must be an IP address or hostname" >&2
        return 1
    fi
    if [[ ! "$port" =~ ^[0-9]+$ ]]; then
        echo "Invalid port: must be numeric" >&2
        return 1
    fi

    if ! is_running; then
        printf '%b%s%b\n' "${RED}" "SOCKS tunnel not running. Start with: visual-spoke.sh up" "${NC}"
        return 1
    fi

    echo "Testing ${target}:${port} through SOCKS..."
    if command -v nc >/dev/null 2>&1; then
        if nc -z -w 3 -X 5 -x "127.0.0.1:${SOCKS_PORT}" "$target" "$port" 2>/dev/null; then
            printf "${GREEN}REACHABLE${NC}  %s:%s\n" "$target" "$port"
        else
            printf "${RED}UNREACHABLE${NC}  %s:%s\n" "$target" "$port"
            return 1
        fi
    elif command -v proxychains4 >/dev/null 2>&1; then
        if proxychains4 -q nc -z -w 3 "$target" "$port" 2>/dev/null; then
            printf "${GREEN}REACHABLE${NC}  %s:%s\n" "$target" "$port"
        else
            printf "${RED}UNREACHABLE${NC}  %s:%s\n" "$target" "$port"
            return 1
        fi
    else
        echo "No nc or proxychains4 with SOCKS support. Install one to test."
        return 1
    fi
}

cmd_info() {
    echo ""
    printf '%b═══ Visual Spoke — Connection Instructions ═══%b\n' "${CYAN}" "${NC}"
    echo ""
    echo "SOCKS5 proxy: localhost:${SOCKS_PORT}"
    echo "Route:        devcontainer → kali spoke → target"
    echo ""
    echo "── RDP (Windows targets) ────────────────────────"
    echo "  xfreerdp:"
    echo "    xfreerdp /v:<target-ip> /proxy:socks5://localhost:${SOCKS_PORT} /u:<user> /d:<domain>"
    echo ""
    echo "  Remmina:"
    echo "    Set proxy: SOCKS5 → localhost:${SOCKS_PORT}"
    echo ""
    echo "── VNC (Linux targets) ────────────────────────────"
    echo "  With proxychains:"
    echo "    proxychains4 vncviewer <target-ip>:5900"
    echo ""
    echo "  With SSH local forward:"
    echo "    ssh -L 5901:<target-ip>:5900 -o ProxyCommand=\"nc -X 5 -x localhost:${SOCKS_PORT} %h %p\" kali"
    echo "    Then connect VNC client to localhost:5901"
    echo ""
    echo "── Browser (web admin panels) ────────────────────"
    echo "  Firefox: Settings → Network → Manual proxy → SOCKS Host: localhost, Port: ${SOCKS_PORT}"
    echo "  Chrome:  chrome --proxy-server=\"socks5://localhost:${SOCKS_PORT}\" --user-data-dir=/tmp/chrome-socks"
    echo ""
    echo "── Verify ─────────────────────────────────────────"
    echo "  visual-spoke.sh test <target-ip> [port]"
    echo ""
}

# ── Main ──────────────────────────────────────────────────────────────────
case "${1:-}" in
    up)     cmd_up ;;
    down)   cmd_down ;;
    status) cmd_status ;;
    test)   shift; cmd_test "$@" ;;
    info)   cmd_info ;;
    *)
        echo "Usage: visual-spoke.sh {up|down|status|test|info}"
        echo ""
        echo "  up      Start SOCKS tunnel through kali spoke"
        echo "  down    Stop SOCKS tunnel"
        echo "  status  Check tunnel health"
        echo "  test    Test target reachability through tunnel"
        echo "  info    Print connection instructions"
        exit 1
        ;;
esac
