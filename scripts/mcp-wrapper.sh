#!/usr/bin/env bash
# mcp-wrapper.sh — load .env, scope secrets per MCP, then exec.
#
# Each MCP server receives ONLY the secrets it needs. Reference MCPs
# (hacktricks, mitre, lolbins, cve) and local-only MCPs (obsidian, rea)
# get zero range credentials. A compromised third-party package cannot
# read secrets it was never given.
#
# Usage: mcp-wrapper.sh <command> [args...]
#
# The MCP server name is inferred from the command arguments. Override
# with MCP_SERVER_NAME=<name> if auto-detection fails.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load ALL vars from .env into this process (for URL derivation etc.)
# shellcheck source=scripts/lib/load-env.sh
source "$SCRIPT_DIR/lib/load-env.sh"

# --- Per-MCP secret scoping ---
# Define which env vars each MCP server is allowed to see.
# Vars NOT in the allow-list are unset before exec.
# Non-secret vars (paths, ports, feature flags) pass through to all.

_secret_vars=(
    TUONI_USERNAME TUONI_PASSWORD
    PROVIDENTIA_TOKEN
    GITLAB_TOKEN GITLAB_PROJECT
    OUTLINE_API_KEY OUTLINE_TOKEN
)

# Map: MCP server name → space-separated list of secret vars it needs.
# Missing from map = no secrets (fail-closed).
declare -A _mcp_secrets=(
    [tuoni-mcp]="TUONI_USERNAME TUONI_PASSWORD"
    [range-intel]="PROVIDENTIA_TOKEN GITLAB_TOKEN GITLAB_PROJECT"
    [outline-readonly]="OUTLINE_API_KEY OUTLINE_TOKEN"
)

_detect_mcp_name() {
    # Explicit override
    [[ -n "${MCP_SERVER_NAME:-}" ]] && { echo "$MCP_SERVER_NAME"; return; }

    # Walk args looking for recognisable MCP names
    local arg
    for arg in "$@"; do
        case "$arg" in
            *tuoni_mcp*|*tuoni-mcp*)    echo "tuoni-mcp"; return ;;
            *range_intel*|*range-intel*) echo "range-intel"; return ;;
            *outline*)                  echo "outline-readonly"; return ;;
            *obsidian*)                 echo "obsidian-mcp"; return ;;
            *hacktricks*)               echo "hacktricks-mcp"; return ;;
            *mitre*)                    echo "mitre-mcp"; return ;;
            *lolbins*|*living-off*)     echo "lolbins-mcp"; return ;;
            *cve-mcp*)                  echo "cve-mcp"; return ;;
            *rea-agents*|*rea-mcp*)     echo "rea-mcp"; return ;;
            *ollama*)                   echo "local-ollama"; return ;;
        esac
    done
    echo "unknown"
}

_mcp_name="$(_detect_mcp_name "$@")"

# Determine which secrets this MCP is allowed
_allowed="${_mcp_secrets[$_mcp_name]:-}"

# Unset every secret var this MCP does NOT need
for _var in "${_secret_vars[@]}"; do
    if [[ -z "$_allowed" ]] || [[ " $_allowed " != *" $_var "* ]]; then
        unset "$_var" 2>/dev/null || true
    fi
done

unset _secret_vars _mcp_secrets _allowed _var _mcp_name
unset -f _detect_mcp_name

exec "$@"
