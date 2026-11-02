#!/usr/bin/env bash
# check-tuoni-health.sh — verify Tuoni server health, plugins, and agent on Kali.
#
# Runs over SSH to SPOKE_KALI_HOST. Reports Tuoni version, loaded plugins,
# deployed TSE scripts, and whether an active agent exists.
#
# Usage: bash scripts/check-tuoni-health.sh
# Exit:  0 on success, 1 if any critical check fails.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/load-env.sh
source "$SCRIPT_DIR/lib/load-env.sh"

KALI_HOST="${SPOKE_KALI_HOST:-}"
TUONI_PORT="${SPOKE_KALI_C2_WEB_PORT:-8443}"
TUONI_SCRIPTS_DIR="${TUONI_SCRIPTS_DIR:-/srv/tuoni/data/scripts}"
TUONI_PLUGINS_DIR="${TUONI_PLUGINS_DIR:-/srv/tuoni/data/plugins}"

if [[ -z "$KALI_HOST" ]]; then
    echo "ERROR: SPOKE_KALI_HOST not set — cannot check Tuoni health."
    exit 1
fi

errors=0

# ── SSH reachability ────────────────────────────────────────────────────────
echo "=== Tuoni Health Check: $KALI_HOST ==="
echo ""
if ! ssh -o ConnectTimeout=10 -o BatchMode=yes kali echo "SSH OK" 2>/dev/null; then
    echo "FAIL: Cannot SSH to kali ($KALI_HOST)"
    exit 1
fi

# ── Tuoni process status ────────────────────────────────────────────────────
echo ""
echo "--- Tuoni Process ---"
process_info=$(ssh -o ConnectTimeout=10 kali \
    "ps aux | grep -i '[t]uoni' | head -3; \
     docker ps --filter 'name=tuoni' --format '{{.Names}}\t{{.Status}}\t{{.Image}}' 2>/dev/null || true" \
    || true)

if [[ -z "$process_info" ]]; then
    echo "FAIL: No Tuoni process running"
    ((errors++))
else
    echo "$process_info"
fi

# ── Tuoni API health ───────────────────────────────────────────────────────
echo ""
echo "--- Tuoni API ---"
api_code=$(ssh -o ConnectTimeout=10 kali \
    "curl -sk --connect-timeout 5 -o /dev/null -w '%{http_code}' https://localhost:${TUONI_PORT}/api/v1/auth/login" \
    2>/dev/null || echo "000")

if [[ "$api_code" == "000" ]]; then
    echo "FAIL: Tuoni API not responding on port ${TUONI_PORT}"
    ((errors++))
else
    echo "API responding (HTTP $api_code on /api/v1/auth/login)"
fi

# ── Tuoni version ──────────────────────────────────────────────────────────
echo ""
echo "--- Tuoni Version ---"
version=$(ssh -o ConnectTimeout=10 kali \
    "cat /app/version.txt 2>/dev/null \
     || cat /opt/tuoni/version.txt 2>/dev/null \
     || cat /srv/tuoni/version.txt 2>/dev/null \
     || docker exec tuoni-server cat /app/version.txt 2>/dev/null \
     || echo 'unknown'" \
    || echo "unknown")
echo "Version: $version"

# ── Commercial/Enterprise plugins ──────────────────────────────────────────
echo ""
echo "--- Tuoni Plugins (${TUONI_PLUGINS_DIR}) ---"
plugin_list=$(ssh -o ConnectTimeout=10 kali \
    "find ${TUONI_PLUGINS_DIR} -maxdepth 1 -name '*.jar' -exec basename {} \\; 2>/dev/null || echo 'none'" \
    || echo "check failed")
echo "$plugin_list"

plugin_count=$(echo "$plugin_list" | grep -c '\.jar$' || true)
echo "Plugin JARs: $plugin_count"

# ── TSE DynamicAlias scripts (tuoni-plugins) ───────────────────────────────
echo ""
echo "--- TSE Scripts (${TUONI_SCRIPTS_DIR}) ---"
script_list=$(ssh -o ConnectTimeout=10 kali \
    "ls -1 ${TUONI_SCRIPTS_DIR}/tuoni_*.py 2>/dev/null || echo 'none'" \
    || echo "check failed")
echo "$script_list"

script_count=$(echo "$script_list" | grep -c 'tuoni_.*\.py$' || true)
echo "TSE scripts: $script_count"

EXPECTED_SCRIPTS=(
    tuoni_net_recon.py
    tuoni_ad_enum.py
    tuoni_cred_dump.py
    tuoni_collect_intel.py
    tuoni_exfil_stage.py
    tuoni_ioc_cleanup.py
    tuoni_proc_migrate.py
    tuoni_log_clear.py
    tuoni_payload_gen.py
    tuoni_get_system.py
    tuoni_lateral_wmi.py
    tuoni_persist_swarm.py
)

missing=()
for script in "${EXPECTED_SCRIPTS[@]}"; do
    if ! echo "$script_list" | grep -q "$script"; then
        missing+=("$script")
    fi
done

if [[ ${#missing[@]} -gt 0 ]]; then
    echo "WARN: Missing TSE scripts: ${missing[*]}"
fi

# ── Active agents ──────────────────────────────────────────────────────────
echo ""
echo "--- Active Agents ---"
if [[ -n "${TUONI_USERNAME:-}" && -n "${TUONI_PASSWORD:-}" ]]; then
    # Tuoni v2 uses HTTP Basic Auth, not JSON body.
    basic_cred=$(printf '%s:%s' "${TUONI_USERNAME}" "${TUONI_PASSWORD}" | base64 -w0)

    auth_response=$(ssh -o ConnectTimeout=10 kali \
        "curl -sk --connect-timeout 5 -X POST https://localhost:${TUONI_PORT}/api/v2/auth/login \
         -H 'Authorization: Basic ${basic_cred}'" \
        2>/dev/null || true)

    token=$(echo "$auth_response" | python3 -I -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('accessToken', d.get('token', '')))
except: pass
" 2>/dev/null || true)

    if [[ -n "$token" ]]; then
        agents_response=$(ssh -o ConnectTimeout=10 kali \
            "curl -sk --connect-timeout 5 \
             https://localhost:${TUONI_PORT}/api/v1/agents \
             -H 'Authorization: Bearer ${token}'" \
            2>/dev/null || true)

        echo "$agents_response" | python3 -I -c "
import sys, json
try:
    agents = json.load(sys.stdin)
    if isinstance(agents, list):
        active = [a for a in agents if a.get('lastCallbackTime')]
        recent = sorted(active, key=lambda a: a.get('lastCallbackTime',''), reverse=True)[:10]
        print(f'Total: {len(agents)}, Recent: {len(active)}')
        for a in recent:
            guid = a.get('guid', '?')[:8]
            meta = a.get('metadata', {})
            hostname = meta.get('hostname', '?')
            user = meta.get('username', '?')
            integrity = meta.get('integrity', '?')
            cb = a.get('lastCallbackTime', '?')[:19]
            print(f'  {guid} {hostname} ({user}) [{integrity}] last={cb}')
    else:
        print('Unexpected response format')
except Exception as e:
    print(f'Parse error: {e}')
" 2>/dev/null || echo "parse failed"
    else
        echo "WARN: Could not authenticate to Tuoni API (check TUONI_USERNAME/TUONI_PASSWORD)"
        [[ -n "$auth_response" ]] && echo "  Response: $(echo "$auth_response" | head -c 200)"
    fi
else
    echo "SKIP: TUONI_USERNAME/TUONI_PASSWORD not set — cannot check agents via API"
fi

# ── Summary ────────────────────────────────────────────────────────────────
echo ""
echo "=== Summary ==="
echo "Tuoni version: $version"
echo "Plugins: $plugin_count JARs"
echo "TSE scripts: $script_count/12 deployed"
[[ ${#missing[@]} -gt 0 ]] && echo "Missing scripts: ${missing[*]}"
[[ $errors -gt 0 ]] && echo "Errors: $errors" && exit 1
echo "Health check complete."
