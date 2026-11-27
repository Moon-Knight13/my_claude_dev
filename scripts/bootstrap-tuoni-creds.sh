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

# ── Detect yq variant (Go mikefarah/yq required, may be installed as yq-go) ─
YQ_BIN=$(ssh -o ConnectTimeout=10 kali 'if command -v yq-go >/dev/null 2>&1; then echo yq-go; elif command -v yq >/dev/null 2>&1 && yq --version 2>&1 | grep -q "mikefarah"; then echo yq; fi' 2>/dev/null)

if [[ -z "$YQ_BIN" ]]; then
    echo "FAIL: Go yq (mikefarah/yq) not found on Kali — install or symlink as yq-go"
    exit 1
fi
echo "Using yq binary: ${YQ_BIN}"

# ── Check config exists ───────────────────────────────────────────────────
if ! ssh -o ConnectTimeout=10 kali "test -f ${TUONI_CONFIG}" 2>/dev/null; then
    echo "FAIL: ${TUONI_CONFIG} not found on Kali"
    exit 1
fi

# ── Write credentials via yq ──────────────────────────────────────────────
echo "Writing credentials to ${TUONI_CONFIG}..."

ssh -o ConnectTimeout=10 kali bash -s -- "$TUONI_USER" "$TUONI_PASS" "$TUONI_CONFIG" "$YQ_BIN" <<'REMOTE_SCRIPT'
set -euo pipefail
user="$1"
pass="$2"
config="$3"
yq_bin="$4"

cp "$config" "${config}.bak"

"$yq_bin" -i ".users[0].username = \"${user}\"" "$config"
"$yq_bin" -i ".users[0].password = \"${pass}\"" "$config"

current_user=$("$yq_bin" '.users[0].username' "$config")
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
        2>/dev/null | tr -d '[:space:]' || echo "000")

    if [[ "$code" =~ ^[1-5][0-9]{2}$ ]]; then
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

auth_code=$(ssh -o ConnectTimeout=10 kali \
    "curl -sk --connect-timeout 5 -X POST -o /dev/null -w '%{http_code}' \
     -u '${TUONI_USER}:${TUONI_PASS}' \
     https://localhost:${TUONI_PORT}/api/v1/auth/login" \
    2>/dev/null | tr -d '[:space:]' || echo "000")

if [[ "$auth_code" == "200" ]]; then
    echo ""
    echo "=== SUCCESS ==="
    echo "Tuoni credentials bootstrapped and verified."
    echo "  User: ${TUONI_USER}"
    echo "  API:  https://${KALI_HOST}:${TUONI_PORT}"
    exit 0
else
    echo ""
    echo "=== FAIL ==="
    echo "Auth returned HTTP ${auth_code}"
    exit 1
fi
