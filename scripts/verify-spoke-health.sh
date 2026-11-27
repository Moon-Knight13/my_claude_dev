#!/usr/bin/env bash
# verify-spoke-health.sh — structured spoke health verification.
#
# Pure bash + SSH. No MCPs, no .env required (but used if present).
# Designed for scripted pipelines, ctp-bridge pre-deploy gates, and the
# spoke-health skill (which can call this for actual checks).
#
# Usage:
#   bash scripts/verify-spoke-health.sh <spoke> [--json] [--quiet]
#   bash scripts/verify-spoke-health.sh kali --json
#   bash scripts/verify-spoke-health.sh deploybox
#
# Spokes: kali, deploybox
#
# Exit codes:
#   0 = healthy  (all checks pass)
#   1 = degraded (SSH ok, some services down)
#   2 = down     (SSH unreachable)
#   3 = usage error
set -uo pipefail

# ── Defaults + args ──────────────────────────────────────────────────────────
SPOKE=""
JSON=false
QUIET=false
SSH_TIMEOUT=10

for arg in "$@"; do
    case "$arg" in
        --json)  JSON=true ;;
        --quiet) QUIET=true ;;
        -*)      echo "Unknown flag: $arg" >&2; exit 3 ;;
        *)       SPOKE="$arg" ;;
    esac
done

if [[ -z "$SPOKE" ]]; then
    echo "Usage: $(basename "$0") <spoke> [--json] [--quiet]" >&2
    echo "Spokes: kali, deploybox" >&2
    exit 3
fi

# ── Load environment if available ────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/lib/load-env.sh" ]]; then
    # shellcheck source=scripts/lib/load-env.sh
    source "$SCRIPT_DIR/lib/load-env.sh"
fi

# ── Result tracking ──────────────────────────────────────────────────────────
declare -a CHECK_NAMES=()
declare -a CHECK_RESULTS=()     # ok | warn | fail
declare -a CHECK_DETAILS=()

record() {
    local name="$1" result="$2" detail="${3:-}"
    CHECK_NAMES+=("$name")
    CHECK_RESULTS+=("$result")
    CHECK_DETAILS+=("$detail")
}

log() {
    $QUIET && return
    if $JSON; then
        printf '%s\n' "$*" >&2
    else
        printf '%s\n' "$*"
    fi
}

# ── SSH resolver ─────────────────────────────────────────────────────────────
# Resolve host from env vars, fall back to SSH config alias.
resolve_ssh() {
    local spoke="$1"
    case "$spoke" in
        kali)
            local host="${SPOKE_KALI_HOST:-}"
            local user="${SPOKE_KALI_USER:-rt}"
            local port="${SPOKE_KALI_SSH_PORT:-22}"
            if [[ -n "$host" ]]; then
                echo "$user@$host" "$port"
            else
                echo "kali" ""
            fi
            ;;
        deploybox)
            local host="${SPOKE_DEPLOYBOX_HOST:-}"
            local user="${SPOKE_DEPLOYBOX_USER:-gt}"
            local port="${SPOKE_DEPLOYBOX_PORT:-22}"
            if [[ -n "$host" ]]; then
                echo "$user@$host" "$port"
            else
                echo "deploybox" ""
            fi
            ;;
        *)
            echo "" ""
            ;;
    esac
}

ssh_cmd() {
    local target port
    read -r target port <<< "$(resolve_ssh "$SPOKE")"
    if [[ -z "$target" ]]; then
        return 1
    fi
    local -a opts=(-o BatchMode=yes -o ConnectTimeout="$SSH_TIMEOUT" -o StrictHostKeyChecking=accept-new)
    [[ -n "$port" ]] && opts+=(-p "$port")
    ssh "${opts[@]}" "$target" "$@"
}

# ── Check: SSH connectivity ─────────────────────────────────────────────────
check_ssh() {
    local start end elapsed
    start=$(date +%s%N 2>/dev/null || date +%s)

    if ssh_cmd echo "ok" >/dev/null 2>&1; then
        end=$(date +%s%N 2>/dev/null || date +%s)
        if [[ ${#start} -gt 10 ]]; then
            elapsed=$(( (end - start) / 1000000 ))
            record "ssh" "ok" "${elapsed}ms"
        else
            record "ssh" "ok" ""
        fi
        return 0
    fi

    local ssh_err
    ssh_err="$(ssh_cmd echo "ok" 2>&1)" || true
    if echo "$ssh_err" | grep -qi "permission denied\|publickey"; then
        record "ssh" "fail" "auth denied — host alive but pubkey rejected"
        return 1
    fi

    record "ssh" "fail" "unreachable — network or host down"
    return 2
}

# ── Check: Docker containers (Kali) ─────────────────────────────────────────
# Expected containers per spoke.
declare -A EXPECTED_CONTAINERS
EXPECTED_CONTAINERS[kali]="tuoni-server tuoni-client tuoni-client-nginx tuoni-docs bloodhound-bloodhound-1 bloodhound-app-db-1 bloodhound-graph-db-1"
EXPECTED_CONTAINERS[deploybox]=""

check_containers() {
    local expected="${EXPECTED_CONTAINERS[$SPOKE]:-}"
    [[ -z "$expected" ]] && return 0

    local running
    running="$(ssh_cmd 'docker ps --format "{{.Names}}" 2>/dev/null || sudo docker ps --format "{{.Names}}" 2>/dev/null' 2>/dev/null)" || {
        record "containers" "warn" "docker command failed"
        return 1
    }

    local missing=() found=0 total=0
    for name in $expected; do
        ((total++)) || true
        if echo "$running" | grep -q "^${name}$"; then
            ((found++)) || true
        else
            missing+=("$name")
        fi
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        record "containers" "ok" "${found}/${total} running"
    elif [[ $found -gt 0 ]]; then
        record "containers" "warn" "${found}/${total} running, missing: ${missing[*]}"
    else
        record "containers" "fail" "0/${total} running"
    fi
}

# ── Check: Service-specific probes ───────────────────────────────────────────
check_services_kali() {
    # Tuoni API
    local tuoni_port="${SPOKE_KALI_C2_WEB_PORT:-8443}"
    local code
    code="$(ssh_cmd "curl -sk --connect-timeout 5 -o /dev/null -w '%{http_code}' https://localhost:${tuoni_port}/api/v1/auth/login" 2>/dev/null)" || code="000"
    if [[ "$code" == "000" ]]; then
        record "tuoni-api" "fail" "not responding on port ${tuoni_port}"
    elif [[ "$code" =~ ^(200|401|403)$ ]]; then
        record "tuoni-api" "ok" "HTTP ${code}"
    else
        record "tuoni-api" "warn" "HTTP ${code} (unexpected)"
    fi

    # BloodHound API (default port 8080)
    code="$(ssh_cmd "curl -sk --connect-timeout 5 -o /dev/null -w '%{http_code}' http://localhost:8080/api/version" 2>/dev/null)" || code="000"
    if [[ "$code" == "000" ]]; then
        record "bloodhound-api" "fail" "not responding"
    elif [[ "$code" =~ ^(200|401|403)$ ]]; then
        record "bloodhound-api" "ok" "HTTP ${code}"
    else
        record "bloodhound-api" "warn" "HTTP ${code}"
    fi

    # Neo4j bolt port
    if ssh_cmd "timeout 3 bash -c 'echo >/dev/tcp/localhost/7687'" 2>/dev/null; then
        record "neo4j-bolt" "ok" "port 7687 open"
    else
        record "neo4j-bolt" "warn" "port 7687 closed"
    fi
}

check_services_deploybox() {
    # Docker daemon
    if ssh_cmd "docker info >/dev/null 2>&1" 2>/dev/null; then
        record "docker-daemon" "ok" "running"
    else
        record "docker-daemon" "warn" "not running or inaccessible"
    fi
}

# ── Run checks ───────────────────────────────────────────────────────────────
case "$SPOKE" in
    kali|deploybox) ;;
    *) echo "Unknown spoke: $SPOKE" >&2; echo "Spokes: kali, deploybox" >&2; exit 3 ;;
esac

log "Verifying spoke: $SPOKE"
log "────────────────────────"

# SSH first — everything else depends on it
if ! check_ssh; then
    # SSH failed — determine exit code from result
    last_detail="${CHECK_DETAILS[0]}"
    if [[ "$last_detail" == *"unreachable"* ]]; then
        EXIT_CODE=2
    else
        EXIT_CODE=2
    fi

    if $JSON; then
        printf '{"spoke":"%s","status":"down","exit_code":%d,"checks":[{"name":"ssh","result":"fail","detail":"%s"}]}\n' \
            "$SPOKE" "$EXIT_CODE" "$last_detail"
    else
        log "SSH: FAIL — $last_detail"
        log "Status: DOWN"
    fi
    exit $EXIT_CODE
fi

log "SSH: OK"

# Container and service checks
check_containers

case "$SPOKE" in
    kali)      check_services_kali ;;
    deploybox) check_services_deploybox ;;
esac

# ── Compute overall status ───────────────────────────────────────────────────
has_fail=false
has_warn=false
for r in "${CHECK_RESULTS[@]}"; do
    case "$r" in
        fail) has_fail=true ;;
        warn) has_warn=true ;;
    esac
done

if $has_fail; then
    STATUS="degraded"
    EXIT_CODE=1
elif $has_warn; then
    STATUS="degraded"
    EXIT_CODE=1
else
    STATUS="healthy"
    EXIT_CODE=0
fi

# ── Output ───────────────────────────────────────────────────────────────────
if $JSON; then
    checks_json="["
    for i in "${!CHECK_NAMES[@]}"; do
        [[ $i -gt 0 ]] && checks_json+=","
        checks_json+="$(printf '{"name":"%s","result":"%s","detail":"%s"}' \
            "${CHECK_NAMES[$i]}" "${CHECK_RESULTS[$i]}" "${CHECK_DETAILS[$i]}")"
    done
    checks_json+="]"
    printf '{"spoke":"%s","status":"%s","exit_code":%d,"checks":%s}\n' \
        "$SPOKE" "$STATUS" "$EXIT_CODE" "$checks_json"
else
    for i in "${!CHECK_NAMES[@]}"; do
        local_result="${CHECK_RESULTS[$i]}"
        local_name="${CHECK_NAMES[$i]}"
        local_detail="${CHECK_DETAILS[$i]}"
        case "$local_result" in
            ok)   printf '  OK   %-20s %s\n' "$local_name" "$local_detail" ;;
            warn) printf '  WARN %-20s %s\n' "$local_name" "$local_detail" ;;
            fail) printf '  FAIL %-20s %s\n' "$local_name" "$local_detail" ;;
        esac
    done
    log ""
    log "Status: ${STATUS^^} (exit $EXIT_CODE)"
fi

exit $EXIT_CODE
