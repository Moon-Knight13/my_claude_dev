#!/usr/bin/env bash
# check-tuoni-version.sh — Query deployed Tuoni version, compare against
# official MCP requirements, and recommend the right MCP server config.
#
# Exit codes:
#   0  version meets official MCP requirement
#   1  version too old (or unreachable)
#   2  usage error
#
# Outputs a single machine-readable line followed by a human summary:
#   TUONI_VERSION=0.16.1 MCP_COMPAT=custom UPGRADE_TO=0.17.0
#
# Requires: curl, TUONI_URL + TUONI_USERNAME + TUONI_PASSWORD (from env or .env)
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load .env if present (same pattern as check-day0.sh).
# shellcheck source=scripts/lib/load-env.sh disable=SC1090,SC1091
source "$_SCRIPT_DIR/lib/load-env.sh"

# Load allocations.env — single source of truth for box assignments.
# This is the PREFERRED source; tuoni-mcp/.env is fallback for compat.
# Environment variables set by the caller take precedence (never overwritten).
_load_tuoni_env() {
    local file="$1"
    [[ -f "$file" ]] || return 1
    local line key val
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        line="${line#"${line%%[![:space:]]*}"}"
        [[ "$line" == export\ * ]] && line="${line#export }"
        [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
        key="${BASH_REMATCH[1]}"
        val="${BASH_REMATCH[2]}"
        # Environment wins: never clobber a variable the caller already set.
        [[ -n "${!key+x}" ]] && continue
        val="${val%\"}" ; val="${val#\"}"
        val="${val%\'}" ; val="${val#\'}"
        export "$key=$val"
    done < "$file"
    return 0
}

_alloc_file="$_SCRIPT_DIR/../config/allocations.env"
if _load_tuoni_env "$_alloc_file"; then
    echo "INFO  Loaded allocations from config/allocations.env"
elif _load_tuoni_env "$HOME/tuoni-mcp/.env"; then
    echo "INFO  Fallback: loaded creds from ~/tuoni-mcp/.env (consider migrating to config/allocations.env)"
fi
unset -f _load_tuoni_env

# ── Minimum version required by official shell-dot/tuoni-mcp ────────────
OFFICIAL_MCP_MIN="0.17.0"

# ── Validate inputs ─────────────────────────────────────────────────────
if [[ -z "${TUONI_URL:-}" ]]; then
    echo "FAIL  TUONI_URL not set. Export it or add to .env." >&2
    exit 2
fi
if [[ -z "${TUONI_USERNAME:-}" || -z "${TUONI_PASSWORD:-}" ]]; then
    echo "FAIL  TUONI_USERNAME / TUONI_PASSWORD not set." >&2
    exit 2
fi

# ── Helper: semver compare (major.minor.patch) ──────────────────────────
# Returns 0 if $1 >= $2.
_ver_gte() {
    local IFS=.
    local -a a=($1) b=($2)
    local i
    for i in 0 1 2; do
        local av="${a[$i]:-0}" bv="${b[$i]:-0}"
        (( av > bv )) && return 0
        (( av < bv )) && return 1
    done
    return 0
}

# ── Reachability pre-check ───────────────────────────────────────────────
_host="${TUONI_URL#https://}"
_host="${_host#http://}"
_host="${_host%%:*}"
_port="${TUONI_URL##*:}"
_port="${_port%%/*}"

if ! timeout 5 bash -c "echo >/dev/tcp/$_host/$_port" 2>/dev/null; then
    echo "TUONI_VERSION=unknown MCP_COMPAT=unreachable UPGRADE_TO=$OFFICIAL_MCP_MIN"
    echo "FAIL  Cannot reach $_host:$_port — box may have been reallocated."
    echo "      Check Providentia for current allocation and update config/allocations.env"
    exit 1
fi

# ── Authenticate (try v1 then v2) ───────────────────────────────────────
TLS_FLAG=""
if [[ "${TUONI_TLS_VERIFY:-true}" == "false" || "${TUONI_VERIFY_TLS:-true}" == "false" ]]; then
    TLS_FLAG="--insecure"
fi

_auth_response=""
_auth_endpoint=""

# Try v1 first (older servers).
_auth_response=$(curl -s -w "\n%{http_code}" $TLS_FLAG \
    -X POST "${TUONI_URL}/api/v1/auth/login" \
    -H "Content-Type: application/json" \
    -u "${TUONI_USERNAME}:${TUONI_PASSWORD}" 2>/dev/null) || true

_http_code="${_auth_response##*$'\n'}"
_body="${_auth_response%$'\n'*}"

if [[ "$_http_code" == "200" ]]; then
    _auth_endpoint="v1"
else
    # Try v2.
    _auth_response=$(curl -s -w "\n%{http_code}" $TLS_FLAG \
        -X POST "${TUONI_URL}/api/v2/auth/login" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"${TUONI_USERNAME}\",\"password\":\"${TUONI_PASSWORD}\"}" 2>/dev/null) || true
    _http_code="${_auth_response##*$'\n'}"
    _body="${_auth_response%$'\n'*}"
    if [[ "$_http_code" == "200" ]]; then
        _auth_endpoint="v2"
    fi
fi

if [[ -z "$_auth_endpoint" ]]; then
    echo "TUONI_VERSION=unknown MCP_COMPAT=unreachable UPGRADE_TO=$OFFICIAL_MCP_MIN"
    echo "FAIL  Cannot reach Tuoni at ${TUONI_URL} (HTTP $_http_code)." >&2
    exit 1
fi

# ── Extract token ───────────────────────────────────────────────────────
# v0.16.x wraps the JWT in JSON; v0.17+ returns the bare JWT from v1.
_token=""
if [[ "$_body" == eyJ* ]]; then
    _token="$_body"
elif command -v python3 &>/dev/null; then
    _token=$(echo "$_body" | python3 -Ic "
import sys, json
d = json.load(sys.stdin)
print(d.get('token', d.get('accessToken', '')))" 2>/dev/null) || true
fi

# ── Get version from /docs/api (OpenAPI spec) or /api/v1/conf ──────────
_version="unknown"

if [[ -n "$_token" ]]; then
    # Try OpenAPI spec endpoint.
    _spec=$(curl -s $TLS_FLAG \
        -H "Authorization: Bearer $_token" \
        "${TUONI_URL}/docs/api" 2>/dev/null) || true
    if [[ -n "$_spec" ]] && command -v python3 &>/dev/null; then
        _version=$(echo "$_spec" | python3 -Ic "
import sys, json
d = json.load(sys.stdin)
print(d.get('info', {}).get('version', 'unknown'))" 2>/dev/null) || true
    fi

    # Fallback: try configuration endpoint.
    if [[ "$_version" == "unknown" || -z "$_version" ]]; then
        _conf=$(curl -s $TLS_FLAG \
            -H "Authorization: Bearer $_token" \
            "${TUONI_URL}/api/v1/conf" 2>/dev/null) || true
        if [[ -n "$_conf" ]] && command -v python3 &>/dev/null; then
            _version=$(echo "$_conf" | python3 -Ic "
import sys, json
d = json.load(sys.stdin)
print(d.get('version', 'unknown'))" 2>/dev/null) || true
        fi
    fi
fi

# If still unknown, infer from auth endpoint.
if [[ "$_version" == "unknown" || -z "$_version" ]]; then
    if [[ "$_auth_endpoint" == "v2" ]]; then
        _version="0.17.0+"
    else
        _version="0.16.x"
    fi
fi

# ── Compare and report ──────────────────────────────────────────────────
_compat="custom"
_exit=1

# Strip any trailing + or - for comparison.
_clean_version="${_version%%[+-]*}"

if [[ "$_clean_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && _ver_gte "$_clean_version" "$OFFICIAL_MCP_MIN"; then
    _compat="official"
    _exit=0
elif [[ "$_auth_endpoint" == "v2" ]]; then
    _compat="official"
    _exit=0
fi

echo "TUONI_VERSION=$_version MCP_COMPAT=$_compat UPGRADE_TO=$OFFICIAL_MCP_MIN"

if [[ "$_compat" == "official" ]]; then
    echo "OK    Tuoni $_version supports official MCP (v2 API)."
    echo "      Use: tuoni-official MCP server (shell-dot/tuoni-mcp)"
else
    echo "WARN  Tuoni $_version < $OFFICIAL_MCP_MIN — official MCP incompatible."
    echo "      Use: tuoni-c2-readonly (custom MCP, v1 API)"
    echo "      Upgrade Tuoni to ${OFFICIAL_MCP_MIN}+ to switch to official MCP."
fi

exit "$_exit"
