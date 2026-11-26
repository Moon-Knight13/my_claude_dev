#!/usr/bin/env bash
# bootstrap-tuoni-creds.sh — Sync .env credentials to Kali Tuoni instance.
#
# Reads TUONI_USERNAME + TUONI_PASSWORD from .env, writes them into
# /srv/tuoni/config/tuoni.yml on Kali via yq, restarts Tuoni, and
# verifies the credentials work against the API.
#
# Usage: bash scripts/bootstrap-tuoni-creds.sh
# Exit:  0 on success, 1 on failure.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/load-env.sh
source "$SCRIPT_DIR/lib/load-env.sh"

KALI_HOST="${SPOKE_KALI_HOST:-}"
TUONI_PORT="${SPOKE_KALI_C2_WEB_PORT:-8443}"
TUONI_USER="${TUONI_USERNAME:-}"
TUONI_PASS="${TUONI_PASSWORD:-}"
TUONI_CONFIG="/srv/tuoni/config/tuoni.yml"
TUONI_DIR="/srv/tuoni"
MAX_RETRIES=15
RETRY_INTERVAL=2

# ── Validate required vars ─────────────────────────────────────────────────
missing=()
[[ -z "$KALI_HOST" ]] && missing+=("SPOKE_KALI_HOST")
[[ -z "$TUONI_USER" ]] && missing+=("TUONI_USERNAME")
[[ -z "$TUONI_PASS" ]] && missing+=("TUONI_PASSWORD")

if [[ ${#missing[@]} -gt 0 ]]; then
    echo "ERROR: Missing required .env variables: ${missing[*]}"
    exit 1
fi

# ── SSH reachability ───────────────────────────────────────────────────────
echo "=== Bootstrap Tuoni Credentials ==="
echo ""
echo "Target: rt@${KALI_HOST}"
echo "Config: ${TUONI_CONFIG}"
echo ""

if ! ssh -o ConnectTimeout=10 -o BatchMode=yes kali echo "SSH OK" 2>/dev/null; then
    echo "FAIL: Cannot SSH to kali (${KALI_HOST})"
    exit 1
fi

# ── Check yq available ────────────────────────────────────────────────────
if ! ssh -o ConnectTimeout=10 kali "command -v yq" >/dev/null 2>&1; then
    echo "FAIL: yq not found on Kali — install with: sudo apt install yq"
    exit 1
fi

# ── Check config exists ───────────────────────────────────────────────────
if ! ssh -o ConnectTimeout=10 kali "test -f ${TUONI_CONFIG}" 2>/dev/null; then
    echo "FAIL: ${TUONI_CONFIG} not found on Kali"
    exit 1
fi

# ── Write credentials via yq ──────────────────────────────────────────────
echo "Writing credentials to ${TUONI_CONFIG}..."

ssh -o ConnectTimeout=10 kali bash -s -- "$TUONI_USER" "$TUONI_PASS" "$TUONI_CONFIG" <<'REMOTE_SCRIPT'
set -euo pipefail
user="$1"
pass="$2"
config="$3"

cp "$config" "${config}.bak"

yq -i ".users[0].username = \"${user}\"" "$config"
yq -i ".users[0].password = \"${pass}\"" "$config"

current_user=$(yq '.users[0].username' "$config")
if [[ "$current_user" != "$user" ]]; then
    echo "FAIL: yq write did not stick — username is '$current_user'"
    exit 1
fi

echo "OK: Credentials written (backup at ${config}.bak)"
REMOTE_SCRIPT

# ── Restart Tuoni ──────────────────────────────────────────────────────────
echo ""
echo "Restarting Tuoni..."

ssh -o ConnectTimeout=10 kali "cd ${TUONI_DIR} && ./tuoni restart" 2>&1 || {
    echo "FAIL: Tuoni restart command failed"
    exit 1
}

# ── Wait for API ──────────────────────────────────────────────────────────
echo ""
echo "Waiting for Tuoni API on port ${TUONI_PORT}..."

for i in $(seq 1 "$MAX_RETRIES"); do
    code=$(ssh -o ConnectTimeout=10 kali \
        "curl -sk --connect-timeout 3 -o /dev/null -w '%{http_code}' https://localhost:${TUONI_PORT}/api/v1/auth/login" \
        2>/dev/null || echo "000")

    if [[ "$code" != "000" ]]; then
        echo "API responding (HTTP ${code}) after ${i}/${MAX_RETRIES} attempts"
        break
    fi

    if [[ "$i" -eq "$MAX_RETRIES" ]]; then
        echo "FAIL: Tuoni API did not come up after $((MAX_RETRIES * RETRY_INTERVAL))s"
        exit 1
    fi

    sleep "$RETRY_INTERVAL"
done

# ── Verify auth ───────────────────────────────────────────────────────────
echo ""
echo "Verifying credentials..."

auth_result=$(ssh -o ConnectTimeout=10 kali \
    "curl -sk --connect-timeout 5 -w '\n%{http_code}' \
     -u '${TUONI_USER}:${TUONI_PASS}' \
     https://localhost:${TUONI_PORT}/api/v1/auth/login" \
    2>/dev/null || echo "000")

http_code=$(echo "$auth_result" | tail -1)
body=$(echo "$auth_result" | head -n -1)

if [[ "$http_code" == "200" ]]; then
    echo ""
    echo "=== SUCCESS ==="
    echo "Tuoni credentials bootstrapped and verified."
    echo "  User: ${TUONI_USER}"
    echo "  API:  https://${KALI_HOST}:${TUONI_PORT}"
    exit 0
else
    echo ""
    echo "=== FAIL ==="
    echo "Auth returned HTTP ${http_code}"
    [[ -n "$body" ]] && echo "Response: $(echo "$body" | head -c 200)"
    exit 1
fi
