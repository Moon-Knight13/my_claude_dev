#!/usr/bin/env bash
# pre-flight.sh — pre-engagement connectivity and readiness check.
#
# Verifies spoke SSH, range DNS, MCP reachability, GitLab access, and env vars
# before an engagement starts. Mode-aware: only checks infrastructure relevant
# to the requested mode.
#
# Usage:
#   bash scripts/lib/pre-flight.sh [<mode>]
#   source scripts/lib/pre-flight.sh && run_preflight [<mode>]
#
# When sourced, sets PREFLIGHT_JSON to the JSON result and returns 0/1.
# When executed, prints JSON to stdout and exits 0 (all pass) or 1 (any fail).
#
# Output: {"mode":"<mode>","checks":[{"name":"...","status":"ok|fail|skip","latency_ms":N,"detail":"..."}],"ready":true|false}
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=scripts/lib/load-env.sh
source "$SCRIPT_DIR/load-env.sh"

# ── Mode detection ───────────────────────────────────────────────────────────

_detect_mode() {
    local requested="${1:-}"
    if [[ -n "$requested" ]]; then
        echo "$requested"
        return
    fi
    if [[ -f "$REPO_ROOT/.claude/settings.json" ]]; then
        local m
        m="$(jq -r '._mode // empty' "$REPO_ROOT/.claude/settings.json" 2>/dev/null)"
        if [[ -n "$m" ]]; then echo "$m"; return; fi
    fi
    echo "platform-ops"
}

# ── Mode → required infrastructure mapping ───────────────────────────────────
# Maps mode names to the checks they need. Each token is a check function name
# minus the _check_ prefix.

_checks_for_mode() {
    local mode="$1"
    local base="spoke_deploybox spoke_kali range_dns gitlab providentia tuoni"
    case "$mode" in
        red-team|pentest|purple)
            echo "gateway spoke_kali tuoni range_dns gitlab providentia" ;;
        red-dev)
            echo "gateway spoke_kali tuoni range_dns gitlab" ;;
        green-dev)
            echo "gateway spoke_deploybox range_dns gitlab providentia" ;;
        ctf)
            echo "gateway spoke_kali tuoni range_dns" ;;
        platform-ops)
            echo "spoke_deploybox spoke_kali range_dns gitlab providentia" ;;
        homelab)
            echo "" ;;
        *)
            echo "$base" ;;
    esac
}

# ── Required env vars per mode ───────────────────────────────────────────────

_required_env_for_mode() {
    local mode="$1"
    case "$mode" in
        red-team|pentest|purple)
            echo "SPOKE_KALI_HOST TUONI_USERNAME TUONI_PASSWORD RANGE_GIT_HOST PROVIDENTIA_HOST" ;;
        red-dev)
            echo "SPOKE_KALI_HOST TUONI_USERNAME TUONI_PASSWORD RANGE_GIT_HOST" ;;
        green-dev)
            echo "SPOKE_DEPLOYBOX_HOST RANGE_GIT_HOST PROVIDENTIA_HOST" ;;
        ctf)
            echo "SPOKE_KALI_HOST TUONI_USERNAME TUONI_PASSWORD" ;;
        platform-ops)
            echo "" ;;
        *)
            echo "" ;;
    esac
}

# ── JSON assembly ────────────────────────────────────────────────────────────

_CHECKS_JSON="[]"

_add_check() {
    local name="$1" status="$2" latency_ms="${3:-0}" detail="${4:-}"
    detail="${detail//\"/\\\"}"
    _CHECKS_JSON="$(echo "$_CHECKS_JSON" | jq -c \
        --arg n "$name" --arg s "$status" --argjson l "$latency_ms" --arg d "$detail" \
        '. + [{"name":$n,"status":$s,"latency_ms":$l,"detail":$d}]')"
}

# ── Individual check functions ───────────────────────────────────────────────

_tcp_probe() {
    local host="$1" port="$2" timeout_s="${3:-3}"
    local start end ms
    start="$(date +%s%N 2>/dev/null || date +%s)"
    if timeout "$timeout_s" bash -c "echo >/dev/tcp/$host/$port" 2>/dev/null; then
        end="$(date +%s%N 2>/dev/null || date +%s)"
        if [[ ${#start} -gt 10 ]]; then
            ms="$(( (end - start) / 1000000 ))"
        else
            ms="$(( (end - start) * 1000 ))"
        fi
        echo "$ms"
        return 0
    fi
    return 1
}

_ssh_auth_probe() {
    local user="$1" host="$2" port="${3:-22}" timeout_s="${4:-3}"
    local start end ms
    start="$(date +%s%N 2>/dev/null || date +%s)"
    if ssh -o BatchMode=yes -o ConnectTimeout="$timeout_s" -o StrictHostKeyChecking=accept-new \
           -p "$port" "$user@$host" whoami >/dev/null 2>&1; then
        end="$(date +%s%N 2>/dev/null || date +%s)"
        if [[ ${#start} -gt 10 ]]; then
            ms="$(( (end - start) / 1000000 ))"
        else
            ms="$(( (end - start) * 1000 ))"
        fi
        echo "$ms"
        return 0
    fi
    return 1
}

_check_gateway() {
    local host="${RANGE_GATEWAY_HOST:-}"
    if [[ -z "$host" ]]; then
        _add_check "gateway" "skip" 0 "RANGE_GATEWAY_HOST not set"
        return
    fi
    local start end ms
    start="$(date +%s%N 2>/dev/null || date +%s)"
    if ping -c 1 -W 3 "$host" >/dev/null 2>&1; then
        end="$(date +%s%N 2>/dev/null || date +%s)"
        if [[ ${#start} -gt 10 ]]; then
            ms="$(( (end - start) / 1000000 ))"
        else
            ms="$(( (end - start) * 1000 ))"
        fi
        _add_check "gateway" "ok" "$ms" "$host"
    else
        _add_check "gateway" "fail" 0 "$host unreachable"
    fi
}

_check_spoke_deploybox() {
    local host="${SPOKE_DEPLOYBOX_HOST:-}"
    local user="${SPOKE_DEPLOYBOX_USER:-gt}"
    local port="${SPOKE_DEPLOYBOX_PORT:-22}"
    if [[ -z "$host" ]]; then
        _add_check "spoke-deploybox" "skip" 0 "SPOKE_DEPLOYBOX_HOST not set"
        return
    fi
    local ms
    if ms="$(_tcp_probe "$host" "$port")"; then
        _add_check "spoke-deploybox-tcp" "ok" "$ms" "$host:$port"
    else
        _add_check "spoke-deploybox-tcp" "fail" 0 "$host:$port unreachable"
        return
    fi
    if ms="$(_ssh_auth_probe "$user" "$host" "$port")"; then
        _add_check "spoke-deploybox-ssh" "ok" "$ms" "$user@$host"
    else
        _add_check "spoke-deploybox-ssh" "fail" 0 "auth failed $user@$host"
    fi
}

_check_spoke_kali() {
    local host="${SPOKE_KALI_HOST:-}"
    local user="${SPOKE_KALI_USER:-rt}"
    local port="${SPOKE_KALI_SSH_PORT:-22}"
    if [[ -z "$host" ]]; then
        _add_check "spoke-kali" "skip" 0 "SPOKE_KALI_HOST not set"
        return
    fi
    local ms
    if ms="$(_tcp_probe "$host" "$port")"; then
        _add_check "spoke-kali-tcp" "ok" "$ms" "$host:$port"
    else
        _add_check "spoke-kali-tcp" "fail" 0 "$host:$port unreachable"
        return
    fi
    if ms="$(_ssh_auth_probe "$user" "$host" "$port")"; then
        _add_check "spoke-kali-ssh" "ok" "$ms" "$user@$host"
    else
        _add_check "spoke-kali-ssh" "fail" 0 "auth failed $user@$host"
    fi
}

_check_range_dns() {
    local dns1="172.21.19.11"
    local dns2="172.21.19.12"
    local test_domain="${RANGE_DNS_TEST_DOMAIN:-git.crp.cr14.net}"
    local ms
    if ms="$(_tcp_probe "$dns1" 53 2)"; then
        _add_check "range-dns-primary" "ok" "$ms" "$dns1:53"
    else
        _add_check "range-dns-primary" "fail" 0 "$dns1:53 unreachable"
    fi
    if ms="$(_tcp_probe "$dns2" 53 2)"; then
        _add_check "range-dns-secondary" "ok" "$ms" "$dns2:53"
    else
        _add_check "range-dns-secondary" "fail" 0 "$dns2:53 unreachable"
    fi
    if command -v dig >/dev/null 2>&1; then
        local start end
        start="$(date +%s%N 2>/dev/null || date +%s)"
        if dig +short +time=2 +tries=1 "@$dns1" "$test_domain" >/dev/null 2>&1; then
            end="$(date +%s%N 2>/dev/null || date +%s)"
            if [[ ${#start} -gt 10 ]]; then
                ms="$(( (end - start) / 1000000 ))"
            else
                ms="$(( (end - start) * 1000 ))"
            fi
            _add_check "range-dns-resolve" "ok" "$ms" "$test_domain via $dns1"
        else
            _add_check "range-dns-resolve" "fail" 0 "cannot resolve $test_domain"
        fi
    fi
}

_check_gitlab() {
    local host="${RANGE_GIT_HOST:-}"
    local port="${RANGE_GIT_SSH_PORT:-10022}"
    if [[ -z "$host" ]]; then
        _add_check "gitlab" "skip" 0 "RANGE_GIT_HOST not set"
        return
    fi
    local ms
    if ms="$(_tcp_probe "$host" "$port")"; then
        _add_check "gitlab-ssh" "ok" "$ms" "$host:$port"
    else
        _add_check "gitlab-ssh" "fail" 0 "$host:$port unreachable"
        return
    fi
    local start end
    start="$(date +%s%N 2>/dev/null || date +%s)"
    if ssh -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new \
           -p "$port" "git@${host}" 2>&1 | grep -qi "welcome\|success\|gitlab"; then
        end="$(date +%s%N 2>/dev/null || date +%s)"
        if [[ ${#start} -gt 10 ]]; then
            ms="$(( (end - start) / 1000000 ))"
        else
            ms="$(( (end - start) * 1000 ))"
        fi
        _add_check "gitlab-auth" "ok" "$ms" "git@$host:$port"
    else
        _add_check "gitlab-auth" "fail" 0 "SSH auth not confirmed"
    fi
}

_check_providentia() {
    local host="${PROVIDENTIA_HOST:-}"
    if [[ -z "$host" ]]; then
        _add_check "providentia" "skip" 0 "PROVIDENTIA_HOST not set"
        return
    fi
    local ms
    if ms="$(_tcp_probe "$host" 443)"; then
        _add_check "providentia-tcp" "ok" "$ms" "$host:443"
    else
        _add_check "providentia-tcp" "fail" 0 "$host:443 unreachable"
        return
    fi
    local start end url="${PROVIDENTIA_URL:-https://$host}"
    start="$(date +%s%N 2>/dev/null || date +%s)"
    if curl -sSf --connect-timeout 3 --max-time 5 -o /dev/null "$url" 2>/dev/null; then
        end="$(date +%s%N 2>/dev/null || date +%s)"
        if [[ ${#start} -gt 10 ]]; then
            ms="$(( (end - start) / 1000000 ))"
        else
            ms="$(( (end - start) * 1000 ))"
        fi
        _add_check "providentia-http" "ok" "$ms" "$url"
    else
        _add_check "providentia-http" "fail" 0 "HTTP check failed"
    fi
}

_check_tuoni() {
    local host="${SPOKE_KALI_HOST:-}"
    local web_port="${SPOKE_KALI_C2_WEB_PORT:-8443}"
    if [[ -z "$host" ]]; then
        _add_check "tuoni" "skip" 0 "SPOKE_KALI_HOST not set"
        return
    fi
    local ms
    if ms="$(_tcp_probe "$host" "$web_port")"; then
        _add_check "tuoni-tcp" "ok" "$ms" "$host:$web_port"
    else
        _add_check "tuoni-tcp" "fail" 0 "$host:$web_port unreachable"
        return
    fi
    local url="${TUONI_URL:-https://$host:$web_port}"
    local start end
    start="$(date +%s%N 2>/dev/null || date +%s)"
    if curl -sSf --connect-timeout 3 --max-time 5 -k -o /dev/null "$url" 2>/dev/null; then
        end="$(date +%s%N 2>/dev/null || date +%s)"
        if [[ ${#start} -gt 10 ]]; then
            ms="$(( (end - start) / 1000000 ))"
        else
            ms="$(( (end - start) * 1000 ))"
        fi
        _add_check "tuoni-http" "ok" "$ms" "$url"
    else
        _add_check "tuoni-http" "fail" 0 "HTTPS check failed (may need -k)"
    fi
}

_check_env_vars() {
    local mode="$1"
    local required
    required="$(_required_env_for_mode "$mode")"
    [[ -z "$required" ]] && return
    local missing=""
    for var in $required; do
        if [[ -z "${!var:-}" ]]; then
            missing="$missing $var"
        fi
    done
    if [[ -n "$missing" ]]; then
        _add_check "env-vars" "fail" 0 "missing:$missing"
    else
        _add_check "env-vars" "ok" 0 "all required vars set"
    fi
}

# ── Main runner ──────────────────────────────────────────────────────────────

run_preflight() {
    local mode
    mode="$(_detect_mode "${1:-}")"
    _CHECKS_JSON="[]"

    local checks
    checks="$(_checks_for_mode "$mode")"

    for check in $checks; do
        "_check_$check"
    done

    _check_env_vars "$mode"

    local ready="true"
    if echo "$_CHECKS_JSON" | jq -e '[.[] | select(.status == "fail")] | length > 0' >/dev/null 2>&1; then
        ready="false"
    fi

    PREFLIGHT_JSON="$(jq -nc \
        --arg mode "$mode" \
        --argjson checks "$_CHECKS_JSON" \
        --argjson ready "$ready" \
        '{"mode":$mode,"checks":$checks,"ready":$ready}')"

    echo "$PREFLIGHT_JSON"
    [[ "$ready" == "true" ]]
}

# When executed directly (not sourced), run and exit.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    run_preflight "${1:-}"
fi
