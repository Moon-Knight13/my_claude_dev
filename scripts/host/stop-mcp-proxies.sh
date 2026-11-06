#!/usr/bin/env bash
# stop-mcp-proxies.sh — stop all MCP SSE proxy processes started by start-mcp-proxies.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUN_DIR="$PROJECT_DIR/.run/mcp-proxies"

if [[ ! -d "$RUN_DIR" ]]; then
    echo "No proxy run directory — nothing to stop"
    exit 0
fi

stopped=0
for pidfile in "$RUN_DIR"/*.pid; do
    [[ -f "$pidfile" ]] || continue
    pid="$(cat "$pidfile")"
    name="$(basename "$pidfile" .pid)"
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null && echo "Stopped $name (pid $pid)" && ((stopped++))
    else
        echo "Already dead: $name (pid $pid)"
    fi
    rm -f "$pidfile"
done

echo "Stopped $stopped proxy processes"
