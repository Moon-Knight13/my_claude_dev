#!/usr/bin/env bash
# mcp-doctor.sh — diagnose MCP server configuration and connectivity.
#
# Checks each server's resolved env vars, .mcp.json registration, and
# reachability. Run after editing .env or when an MCP server won't connect.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=scripts/lib/load-env.sh
source "$SCRIPT_DIR/lib/load-env.sh"

MCP_FILE="$PROJECT_DIR/.mcp.json"
PASS="[OK]"
WARN="[!!]"
FAIL="[XX]"

_status=0

echo "MCP Doctor"
echo "=========="
echo ""

# --- .mcp.json existence ---
if [[ -f "$MCP_FILE" ]]; then
    _count="$(python3 -I -c "import json; print(len(json.load(open('$MCP_FILE'))['mcpServers']))" 2>/dev/null || echo "?")"
    echo "$PASS  .mcp.json exists ($_count servers registered)"
else
    echo "$FAIL  .mcp.json missing — run: bash scripts/setup-mcp-servers.sh"
    _status=1
fi
echo ""

# --- Env var map ---
echo "Env Var Resolution (what MCP servers will see via mcp-wrapper.sh):"
echo "─────────────────────────────────────────────────────────────────"
_check_var() {
    local name="$1" required="${2:-false}" source_hint="$3"
    local val="${!name:-}"
    if [[ -n "$val" ]]; then
        # Mask tokens/passwords — show first 4 chars only.
        if [[ "$name" == *TOKEN* || "$name" == *PASSWORD* || "$name" == *KEY* || "$name" == *SECRET* ]]; then
            echo "  $PASS  $name = ${val:0:4}****  (from $source_hint)"
        else
            echo "  $PASS  $name = $val  (from $source_hint)"
        fi
    elif [[ "$required" == "true" ]]; then
        echo "  $FAIL  $name = <unset>  (needed by $source_hint)"
        _status=1
    else
        echo "  $WARN  $name = <unset>  (optional, for $source_hint)"
    fi
}

echo ""
echo "  Range services:"
_check_var OUTLINE_HOST false ".env"
_check_var OUTLINE_URL false "derived from OUTLINE_HOST"
_check_var OUTLINE_API_URL false "derived → outline-readonly"
_check_var OUTLINE_API_KEY false ".env → outline-readonly"
_check_var PROVIDENTIA_HOST false ".env"
_check_var PROVIDENTIA_URL false "derived → range-intel"
_check_var PROVIDENTIA_TOKEN false ".env → range-intel"
_check_var RANGE_GIT_HOST false ".env"
_check_var GITLAB_URL false "derived → range-intel"
_check_var GITLAB_TOKEN false ".env → range-intel"
_check_var GITLAB_PROJECT false ".env → range-intel"

echo ""
echo "  Tuoni C2:"
_check_var SPOKE_KALI_HOST false ".env"
_check_var TUONI_URL false "derived → tuoni-mcp"
_check_var TUONI_USERNAME false ".env → tuoni-mcp"
_check_var TUONI_PASSWORD false ".env → tuoni-mcp"

echo ""
echo "  Ghidra / REA:"
_check_var GHIDRA_INSTALL_DIR false "load-env.sh default → rea-mcp"
_check_var JAVA_HOME false "load-env.sh default → rea-mcp"

echo ""
echo "  BloodHound MCP:"
_check_var BH_NEO4J_USER false ".env → bloodhound-mcp"
_check_var BH_NEO4J_PASSWORD false ".env → bloodhound-mcp"

echo ""
echo "  Hashcat MCP:"
_check_var HASHCAT_HOST false "derived from SPOKE_KALI_HOST → hashcat-mcp"

echo ""
echo "  Nuclei MCP:"
_check_var NUCLEI_HOST false "derived from SPOKE_KALI_HOST → nuclei-mcp"

echo ""
echo "  Ollama / local model:"
_check_var LOCAL_MODEL_ENABLED false ".env"
_check_var OLLAMA_HOST false "derived from LOCAL_MODEL_ENDPOINT → local-ollama"
_check_var OLLAMA_MODEL false "derived from LOCAL_MODEL_MODEL → local-ollama"
echo ""

# --- Wrapper check ---
if [[ -x "$SCRIPT_DIR/mcp-wrapper.sh" ]]; then
    echo "$PASS  mcp-wrapper.sh is executable"
else
    echo "$FAIL  mcp-wrapper.sh missing or not executable"
    _status=1
fi

# --- All servers use wrapper? ---
if [[ -f "$MCP_FILE" ]]; then
    _direct="$(python3 -I -c "
import json, sys
cfg = json.load(open('$MCP_FILE'))
direct = [n for n, s in cfg['mcpServers'].items() if 'mcp-wrapper' not in s.get('command','')]
if direct: print(', '.join(direct))
" 2>/dev/null || true)"
    if [[ -n "$_direct" ]]; then
        echo "$WARN  Servers NOT using mcp-wrapper.sh (won't get .env vars): $_direct"
    else
        echo "$PASS  All servers route through mcp-wrapper.sh"
    fi
fi

# --- Connectivity probes (best-effort, non-blocking) ---
echo ""
echo "Connectivity (2s timeout per probe):"
echo "─────────────────────────────────────"

_probe_url() {
    local label="$1" url="$2"
    if [[ -z "$url" ]]; then
        echo "  $WARN  $label — URL not set, skipping"
        return
    fi
    if curl -sSf -o /dev/null --max-time 2 "$url" 2>/dev/null; then
        echo "  $PASS  $label — $url reachable"
    else
        echo "  $FAIL  $label — $url unreachable"
        _status=1
    fi
}

_probe_url "Outline" "${OUTLINE_API_URL:-}"
_probe_url "Providentia" "${PROVIDENTIA_URL:-}"
_probe_url "GitLab" "${GITLAB_URL:-}"
_probe_url "Tuoni" "${TUONI_URL:-}"

# --- Tuoni plugin JAR health (quick SSH check) ---
if [[ -n "${SPOKE_KALI_HOST:-}" ]]; then
    _jar_out=$(ssh -o ConnectTimeout=5 -o BatchMode=yes kali \
        "sudo docker exec tuoni-server ls /app/plugins/ 2>/dev/null" 2>/dev/null) || true
    _srv_ver=$(ssh -o ConnectTimeout=5 -o BatchMode=yes kali \
        "sudo docker exec tuoni-server cat /app/cp/version.txt 2>/dev/null || \
         sudo docker inspect tuoni-server --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep ^VERSION= | cut -d= -f2" 2>/dev/null) || true
    _srv_ver="${_srv_ver%%$'\n'*}"
    if [[ -n "$_jar_out" && -n "$_srv_ver" ]]; then
        _jar_mismatch=""
        while IFS= read -r jar; do
            [[ -z "$jar" ]] && continue
            jv=$(echo "$jar" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)
            [[ -n "$jv" && "$jv" != "$_srv_ver" ]] && _jar_mismatch="$jar ($jv != $_srv_ver)"
        done <<< "$_jar_out"
        if [[ -n "$_jar_mismatch" ]]; then
            echo "  $FAIL  Tuoni plugin JAR mismatch: $_jar_mismatch"
            echo "         Server will crash on startup. Run update-plugins.sh or ./tuoni update"
            _status=1
        else
            echo "  $PASS  Tuoni plugin JARs match server v${_srv_ver}"
        fi
    elif [[ -z "$_jar_out" ]]; then
        echo "  $WARN  Tuoni plugin JAR check skipped (SSH/docker access failed)"
    fi
fi

# --- New MCP service probes ---
if [[ -n "${SPOKE_KALI_HOST:-}" ]]; then
    _neo4j_port="${BH_NEO4J_PORT:-7687}"
    if timeout 3 bash -c "echo >/dev/tcp/${SPOKE_KALI_HOST}/$_neo4j_port" 2>/dev/null; then
        echo "  $PASS  Neo4j (BloodHound) — ${SPOKE_KALI_HOST}:${_neo4j_port} reachable"
    else
        echo "  $WARN  Neo4j (BloodHound) — ${SPOKE_KALI_HOST}:${_neo4j_port} unreachable (deploy BloodHound CE on Kali)"
    fi

    if ssh -o ConnectTimeout=5 -o BatchMode=yes kali "command -v hashcat" >/dev/null 2>&1; then
        echo "  $PASS  Hashcat — available on Kali"
    else
        echo "  $WARN  Hashcat — not found on Kali"
    fi

    if ssh -o ConnectTimeout=5 -o BatchMode=yes kali "command -v nuclei" >/dev/null 2>&1; then
        echo "  $PASS  Nuclei — available on Kali"
    else
        echo "  $WARN  Nuclei — not found on Kali"
    fi
fi

_probe_url "Ollama" "${OLLAMA_HOST:-}"

# --- Ghidra install check ---
echo ""
if [[ -d "${GHIDRA_INSTALL_DIR:-}" ]]; then
    echo "$PASS  Ghidra installed at $GHIDRA_INSTALL_DIR"
    if [[ -d "$HOME/.ghidra" ]]; then
        echo "$PASS  Ghidra first-run init completed (~/.ghidra exists)"
    else
        echo "$WARN  Ghidra first-run init not done (~/.ghidra missing) — rea-mcp Ghidra features may fail"
    fi
else
    echo "$WARN  Ghidra not installed at ${GHIDRA_INSTALL_DIR:-<unset>}"
fi

if [[ -d "${JAVA_HOME:-}" ]]; then
    echo "$PASS  JDK found at $JAVA_HOME"
else
    echo "$WARN  JDK not found at ${JAVA_HOME:-<unset>}"
fi

echo ""
if [[ "$_status" -eq 0 ]]; then
    echo "All checks passed."
else
    echo "Some checks failed — review output above."
fi
exit "$_status"
