#!/usr/bin/env bash
# mcp-wrapper.sh — load .env, scope secrets per MCP from config, then exec.
#
# Each MCP server receives ONLY the secrets declared in config/mcp-secrets.yaml.
# Reference MCPs (hacktricks, mitre, lolbins, cve) and local-only MCPs get zero
# range credentials. A compromised third-party package cannot read secrets it was
# never given. Unknown MCPs get zero secrets (fail-closed).
#
# Usage: mcp-wrapper.sh <command> [args...]
#
# MCP server name is inferred from command args. Override: MCP_SERVER_NAME=<name>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load ALL vars from .env (for URL derivation etc.)
# shellcheck source=scripts/lib/load-env.sh
source "$SCRIPT_DIR/lib/load-env.sh"

# --- Per-MCP secret scoping from config/mcp-secrets.yaml ---
SECRETS_CONFIG="$PROJECT_DIR/config/mcp-secrets.yaml"

_detect_mcp_name() {
    [[ -n "${MCP_SERVER_NAME:-}" ]] && { echo "$MCP_SERVER_NAME"; return; }
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
            *bloodhound*|*BloodHound*)  echo "bloodhound-mcp"; return ;;
            *hashcat*)                  echo "hashcat-mcp"; return ;;
            *nuclei-mcp*|*nuclei_mcp*)  echo "nuclei-mcp"; return ;;
            *ghidra-mcp*|*ghidra_mcp*) echo "ghidra-mcp"; return ;;
        esac
    done
    echo "unknown"
}

_mcp_name="$(_detect_mcp_name "$@")"

if [[ -f "$SECRETS_CONFIG" ]]; then
    # Parse config with python — extract secret list and allowed vars for this MCP
    _scoping="$(python3 -I -c '
import sys, re

config_file = sys.argv[1]
mcp_name = sys.argv[2]

content = open(config_file).read()

# Lightweight YAML parser for our simple structure
# Extract secrets list
secrets = []
in_secrets = False
in_scoping = False
mcp_allowed = []
in_mcp = False

for line in content.splitlines():
    stripped = line.strip()
    if stripped.startswith("#") or not stripped:
        continue

    # Detect top-level keys
    if line.startswith("secrets:"):
        in_secrets = True
        in_scoping = False
        in_mcp = False
        continue
    elif line.startswith("scoping:"):
        in_scoping = True
        in_secrets = False
        in_mcp = False
        continue
    elif not line.startswith(" ") and not line.startswith("\t"):
        in_secrets = False
        in_scoping = False
        in_mcp = False
        continue

    if in_secrets and stripped.startswith("- "):
        secrets.append(stripped[2:].strip().strip("\"").strip("'\''"))

    if in_scoping:
        # Check for MCP name key (2-space indent)
        m = re.match(r"^  (\S+):\s*(.*)", line)
        if m:
            key = m.group(1)
            val = m.group(2).strip()
            if key == mcp_name:
                in_mcp = True
                # Handle inline empty list: []
                if val == "[]":
                    in_mcp = False
                continue
            else:
                in_mcp = False
                continue
        if in_mcp and stripped.startswith("- "):
            mcp_allowed.append(stripped[2:].strip().strip("\"").strip("'\''"))

# Output: SECRETS|ALLOWED (pipe-delimited, single line)
print(",".join(secrets) + "|" + ",".join(mcp_allowed))
' "$SECRETS_CONFIG" "$_mcp_name" 2>/dev/null || true)"

    _all_secrets="${_scoping%%|*}"
    _allowed="${_scoping#*|}"

    # Unset every secret this MCP does NOT need
    IFS=',' read -ra _secret_arr <<< "$_all_secrets"
    IFS=',' read -ra _allowed_arr <<< "$_allowed"

    for _var in "${_secret_arr[@]}"; do
        [[ -z "$_var" ]] && continue
        _found=0
        for _a in "${_allowed_arr[@]}"; do
            [[ "$_a" == "$_var" ]] && { _found=1; break; }
        done
        if (( _found == 0 )); then
            unset "$_var" 2>/dev/null || true
        fi
    done
else
    # No config file — fail closed: unset all known secrets
    for _var in TUONI_USERNAME TUONI_PASSWORD PROVIDENTIA_TOKEN \
                GITLAB_TOKEN GITLAB_PROJECT OUTLINE_API_KEY OUTLINE_TOKEN; do
        unset "$_var" 2>/dev/null || true
    done
fi

unset _scoping _all_secrets _allowed _secret_arr _allowed_arr _var _a _found
unset -f _detect_mcp_name

# Honor MCP_CWD for servers that need a specific working directory
# (T3 Code / Claude Code don't reliably apply .mcp.json "cwd" field)
if [[ -n "${MCP_CWD:-}" && -d "$MCP_CWD" ]]; then
    cd "$MCP_CWD"
    unset MCP_CWD
fi

# nuclei-mcp writes OpenSSL info to stdout on init, breaking MCP stdio.
# Filter: pass only JSON-RPC lines (start with '{'), redirect rest to stderr.
if [[ "$_mcp_name" == "nuclei-mcp" ]]; then
    "$@" | awk '/^\{/{print; fflush(); next}{print > "/dev/stderr"}'
    exit "${PIPESTATUS[0]}"
fi

exec "$@"
