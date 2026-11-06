#!/usr/bin/env bash
# start-mcp-proxies.sh — start SSE proxies for range-facing MCPs on the host.
#
# Architecture:
#   supergateway (stdio->SSE on 127.0.0.1, internal port)
#   -> mcp-auth-proxy.js (Bearer token check, 0.0.0.0, external port)
#   -> container reaches via host.docker.internal:<external_port>/sse
#
# Run on HOST before starting devcontainer (bridge networking mode).
# Requires: node, npx, .env with MCP_PROXY_TOKEN and range credentials.
#
# Usage:
#   bash scripts/host/start-mcp-proxies.sh          # start all
#   bash scripts/host/start-mcp-proxies.sh status    # show running state
#   bash scripts/host/start-mcp-proxies.sh stop      # stop all (alias for stop script)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUN_DIR="$PROJECT_DIR/.run/mcp-proxies"

# shellcheck source=scripts/lib/load-env.sh
source "$PROJECT_DIR/scripts/lib/load-env.sh"

# ── Subcommands ──────────────────────────────────────────────────────────────

if [[ "${1:-}" == "stop" ]]; then
    exec bash "$SCRIPT_DIR/stop-mcp-proxies.sh"
fi

if [[ "${1:-}" == "status" ]]; then
    echo "MCP proxy status:"
    for pidfile in "$RUN_DIR"/*.pid; do
        [[ -f "$pidfile" ]] || { echo "  No proxies running"; exit 0; }
        name="$(basename "$pidfile" .pid)"
        pid="$(cat "$pidfile")"
        if kill -0 "$pid" 2>/dev/null; then
            echo "  RUNNING  $name (pid $pid)"
        else
            echo "  DEAD     $name (stale pid $pid)"
        fi
    done
    exit 0
fi

# ── Preflight ────────────────────────────────────────────────────────────────

if [[ -z "${MCP_PROXY_TOKEN:-}" ]]; then
    echo "ERROR: MCP_PROXY_TOKEN not set in .env"
    echo "Generate one: openssl rand -hex 32"
    exit 1
fi

command -v npx >/dev/null 2>&1 || { echo "ERROR: npx not found"; exit 1; }
command -v node >/dev/null 2>&1 || { echo "ERROR: node not found"; exit 1; }

mkdir -p "$RUN_DIR"

# Kill any leftover processes from a prior run
if ls "$RUN_DIR"/*.pid >/dev/null 2>&1; then
    echo "Cleaning up stale proxy processes..."
    bash "$SCRIPT_DIR/stop-mcp-proxies.sh" 2>/dev/null || true
fi

# ── Port assignments ─────────────────────────────────────────────────────────
# External port = auth proxy (reachable from container)
# Internal port = supergateway (localhost only)

declare -A EXT_PORTS INT_PORTS
EXT_PORTS[range-intel]=8101;   INT_PORTS[range-intel]=18101
EXT_PORTS[tuoni-mcp]=8102;     INT_PORTS[tuoni-mcp]=18102
EXT_PORTS[outline-readonly]=8103; INT_PORTS[outline-readonly]=18103

# ── MCP launch commands ──────────────────────────────────────────────────────
# Each command is what supergateway passes to --stdio.
# mcp-wrapper.sh handles .env loading and secret scoping.

VENV_PYTHON="$PROJECT_DIR/mcp-servers/.venv/bin/python3"

declare -A MCP_STDIO_CMDS MCP_EXTRA_ENV

MCP_STDIO_CMDS[range-intel]="$VENV_PYTHON -m range_intel.server"
MCP_EXTRA_ENV[range-intel]="PYTHONPATH=$PROJECT_DIR/mcp-servers/range-intel/src"

MCP_STDIO_CMDS[tuoni-mcp]="$VENV_PYTHON -m tuoni_mcp"
MCP_EXTRA_ENV[tuoni-mcp]="TUONI_VERIFY_TLS=false TUONI_MCP_PROFILES=agent-ops,access,discovery,authoring,administration"

MCP_STDIO_CMDS[outline-readonly]="node $PROJECT_DIR/mcp-servers/outline-readonly/src/server.js"
MCP_EXTRA_ENV[outline-readonly]=""

# ── Start proxies ────────────────────────────────────────────────────────────

started=0
failed=0

for mcp in range-intel tuoni-mcp outline-readonly; do
    ext_port="${EXT_PORTS[$mcp]}"
    int_port="${INT_PORTS[$mcp]}"
    stdio_cmd="${MCP_STDIO_CMDS[$mcp]}"
    extra_env="${MCP_EXTRA_ENV[$mcp]}"

    echo "Starting $mcp (SSE :$ext_port)..."

    # Build the stdio command with env vars prepended
    full_stdio_cmd="$stdio_cmd"
    if [[ -n "$extra_env" ]]; then
        full_stdio_cmd="env $extra_env $stdio_cmd"
    fi

    # Start supergateway on internal port (localhost only)
    npx -y supergateway \
        --stdio "$full_stdio_cmd" \
        --port "$int_port" \
        --host 127.0.0.1 \
        --logLevel none \
        >> "$RUN_DIR/$mcp-gateway.log" 2>&1 &
    echo $! > "$RUN_DIR/$mcp-gateway.pid"

    # Brief pause for supergateway to bind
    sleep 1

    # Start auth proxy on external port
    MCP_PROXY_TOKEN="$MCP_PROXY_TOKEN" \
        node "$SCRIPT_DIR/mcp-auth-proxy.js" "$ext_port" "$int_port" \
        >> "$RUN_DIR/$mcp-proxy.log" 2>&1 &
    echo $! > "$RUN_DIR/$mcp-proxy.pid"

    # Verify auth proxy is listening
    sleep 0.5
    proxy_pid="$(cat "$RUN_DIR/$mcp-proxy.pid")"
    if kill -0 "$proxy_pid" 2>/dev/null; then
        echo "  $mcp: :$ext_port (auth) -> :$int_port (SSE) -> stdio"
        ((started++))
    else
        echo "  FAIL: $mcp auth proxy died — check $RUN_DIR/$mcp-proxy.log"
        ((failed++))
    fi
done

echo ""
echo "MCP SSE proxies: $started started, $failed failed"
echo "PID files: $RUN_DIR/"
echo "Container reaches via http://host.docker.internal:<port>/sse"

if (( failed > 0 )); then
    echo "Check logs: ls $RUN_DIR/*.log"
    exit 1
fi
