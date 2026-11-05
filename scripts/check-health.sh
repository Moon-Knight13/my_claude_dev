#!/usr/bin/env bash
# Platform health monitoring — Docker disk, MCP probes, dep audit, CI, spoke preflight.
# Designed for platform-ops mode. Non-destructive, read-only checks.
#
# Usage: bash scripts/check-health.sh [--section <name>]
# Sections: docker, mcp, deps, ci, spoke, all (default)
set -euo pipefail

PASS=0
WARN=0
FAIL=0

ok()   { echo "  OK  $1"; ((PASS++)) || true; }
warn() { echo " WARN $1"; echo "      -> $2"; ((WARN++)) || true; }
fail() { echo " FAIL $1"; echo "      -> $2"; ((FAIL++)) || true; }

SECTION="${1:-all}"
[[ "$SECTION" == "--section" ]] && SECTION="${2:-all}"

# ── Docker Disk Usage ────────────────────────────────────────────────────────
run_docker() {
    echo "Docker"
    echo "------"

    if ! command -v docker >/dev/null 2>&1; then
        warn "Docker not available" "docker command not found"
        return
    fi

    if ! docker info >/dev/null 2>&1; then
        warn "Docker daemon not running" "start Docker or check socket mount"
        return
    fi

    disk_json="$(docker system df --format json 2>/dev/null || echo "")"
    if [[ -n "$disk_json" ]]; then
        ok "Docker daemon reachable"
        echo "      Disk usage:"
        docker system df 2>/dev/null | head -5 | sed 's/^/      /'

        reclaimable="$(docker system df 2>/dev/null | awk '/Images/{print $NF}')"
        if [[ "$reclaimable" =~ [0-9] ]]; then
            echo "      Reclaimable (images): $reclaimable"
        fi
    else
        ok "Docker daemon reachable"
    fi

    dangling="$(docker images -f dangling=true -q 2>/dev/null | wc -l)"
    if [[ "$dangling" -gt 10 ]]; then
        warn "Dangling images: $dangling" "Run: docker image prune"
    elif [[ "$dangling" -gt 0 ]]; then
        ok "Dangling images: $dangling (manageable)"
    else
        ok "No dangling images"
    fi

    stopped="$(docker ps -a --filter status=exited -q 2>/dev/null | wc -l)"
    if [[ "$stopped" -gt 20 ]]; then
        warn "Stopped containers: $stopped" "Run: docker container prune"
    elif [[ "$stopped" -gt 0 ]]; then
        ok "Stopped containers: $stopped (manageable)"
    else
        ok "No stopped containers"
    fi

    echo ""
}

# ── MCP Server Health ────────────────────────────────────────────────────────
run_mcp() {
    echo "MCP Servers"
    echo "-----------"

    settings_file=".claude/settings.json"
    if [[ ! -f "$settings_file" ]]; then
        warn "No settings.json" "Run /mode to configure"
        echo ""
        return
    fi

    mode="$(jq -r '._mode // "none"' "$settings_file" 2>/dev/null)"
    ok "Active mode: $mode"

    mcp_count="$(jq '.mcpServers | length' "$settings_file" 2>/dev/null || echo 0)"
    ok "MCP servers configured: $mcp_count"

    jq -r '.mcpServers | keys[]' "$settings_file" 2>/dev/null | while read -r server; do
        cmd="$(jq -r ".mcpServers[\"$server\"].command // \"unknown\"" "$settings_file" 2>/dev/null)"
        case "$cmd" in
            npx)
                pkg="$(jq -r ".mcpServers[\"$server\"].args[1] // \"unknown\"" "$settings_file" 2>/dev/null)"
                ok "  $server -> npx $pkg"
                ;;
            node)
                script="$(jq -r ".mcpServers[\"$server\"].args[0] // \"unknown\"" "$settings_file" 2>/dev/null)"
                if [[ "$script" != *'$'* ]] && [[ ! -f "$script" ]]; then
                    warn "  $server -> $script" "script not found (env var not expanded?)"
                else
                    ok "  $server -> node $script"
                fi
                ;;
            *)
                ok "  $server -> $cmd"
                ;;
        esac
    done

    echo ""
}

# ── Dependency Audit ─────────────────────────────────────────────────────────
run_deps() {
    echo "Dependencies"
    echo "------------"

    if [[ -f "package.json" ]] && command -v npm >/dev/null 2>&1; then
        audit_out="$(npm audit --json 2>/dev/null || echo "{}")"
        vulns="$(echo "$audit_out" | jq '.metadata.vulnerabilities // {} | to_entries | map(select(.value > 0)) | length' 2>/dev/null || echo "?")"
        if [[ "$vulns" == "0" ]]; then
            ok "npm audit clean"
        elif [[ "$vulns" == "?" ]]; then
            warn "npm audit failed" "Run: npm audit"
        else
            critical="$(echo "$audit_out" | jq '.metadata.vulnerabilities.critical // 0' 2>/dev/null)"
            high="$(echo "$audit_out" | jq '.metadata.vulnerabilities.high // 0' 2>/dev/null)"
            if [[ "$critical" -gt 0 || "$high" -gt 0 ]]; then
                fail "npm: $critical critical, $high high vulns" "Run: npm audit fix"
            else
                warn "npm: $vulns vulnerability categories" "Run: npm audit"
            fi
        fi
    else
        ok "No package.json (npm audit skipped)"
    fi

    if command -v gitleaks >/dev/null 2>&1; then
        ok "gitleaks available"
    else
        warn "gitleaks not installed" "Secret scanning unavailable"
    fi

    if command -v semgrep >/dev/null 2>&1; then
        ok "semgrep available"
    else
        warn "semgrep not installed" "Static analysis unavailable locally (CI still runs it)"
    fi

    echo ""
}

# ── CI Status ────────────────────────────────────────────────────────────────
run_ci() {
    echo "CI Status"
    echo "---------"

    if ! command -v gh >/dev/null 2>&1 || ! gh auth status >/dev/null 2>&1; then
        warn "gh not authenticated" "CI status check requires gh auth"
        echo ""
        return
    fi

    default_branch="$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name 2>/dev/null || echo "main")"
    last_run="$(gh run list --branch "$default_branch" --limit 1 --json conclusion,headSha,createdAt,name 2>/dev/null)"

    if [[ -n "$last_run" && "$last_run" != "[]" ]]; then
        conclusion="$(echo "$last_run" | jq -r '.[0].conclusion // "unknown"')"
        sha="$(echo "$last_run" | jq -r '.[0].headSha // "unknown"' | head -c 7)"
        when="$(echo "$last_run" | jq -r '.[0].createdAt // "unknown"')"
        if [[ "$conclusion" == "success" ]]; then
            ok "Last CI on $default_branch: $conclusion ($sha, $when)"
        else
            fail "Last CI on $default_branch: $conclusion ($sha)" "Check: gh run list --branch $default_branch"
        fi
    else
        warn "No CI runs found" "Check workflow configuration"
    fi

    open_prs="$(gh pr list --state open --json number 2>/dev/null | jq length 2>/dev/null || echo "?")"
    ok "Open PRs: $open_prs"

    echo ""
}

# ── Spoke Preflight ──────────────────────────────────────────────────────────
run_spoke() {
    echo "Spoke Preflight"
    echo "---------------"

    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=scripts/lib/load-env.sh
    source "$SCRIPT_DIR/lib/load-env.sh"

    # Per-var probe ports: SSH spokes on 22, GitLab on its custom port, services on 443
    declare -A PROBE_PORTS=(
        [SPOKE_DEPLOYBOX_HOST]=22
        [SPOKE_KALI_HOST]=22
        [RANGE_GIT_HOST]="${RANGE_GIT_SSH_PORT:-10022}"
        [PROVIDENTIA_HOST]=443
        [OUTLINE_HOST]=443
    )

    # Firewall + connectivity check per spoke
    spoke_up=0
    spoke_total=0
    for var in SPOKE_DEPLOYBOX_HOST SPOKE_KALI_HOST RANGE_GIT_HOST PROVIDENTIA_HOST OUTLINE_HOST; do
        ip="${!var:-}"
        [[ -z "$ip" ]] && continue
        ((spoke_total++)) || true
        probe_port="${PROBE_PORTS[$var]}"

        if command -v ipset >/dev/null 2>&1 && ! ipset test allowed-domains "$ip" 2>/dev/null; then
            warn "$var ($ip) NOT in firewall" "Run: bash scripts/spoke-firewall.sh"
            continue
        fi

        if timeout 3 bash -c "echo >/dev/tcp/$ip/$probe_port" 2>/dev/null; then
            ok "$var ($ip:$probe_port) reachable"
            ((spoke_up++)) || true
        else
            warn "$var ($ip:$probe_port) unreachable" "Check VPN connection"
        fi
    done

    # SSH auth check for SSH-capable spokes
    declare -A SSH_USERS=(
        [SPOKE_DEPLOYBOX_HOST]="${SPOKE_DEPLOYBOX_USER:-gt}"
        [SPOKE_KALI_HOST]="${SPOKE_KALI_USER:-rt}"
    )
    for var in SPOKE_DEPLOYBOX_HOST SPOKE_KALI_HOST; do
        ip="${!var:-}"
        [[ -z "$ip" ]] && continue
        user="${SSH_USERS[$var]}"
        if ssh -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new \
               "$user@$ip" whoami >/dev/null 2>&1; then
            ok "SSH auth $var ($user@$ip)"
        else
            warn "SSH auth failed $var ($user@$ip)" "Add pubkey: cat ~/.ssh/id_ed25519.pub"
        fi
    done

    # GitLab SSH auth (custom port)
    if [[ -n "${RANGE_GIT_HOST:-}" ]]; then
        if ssh -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new \
               -p "${RANGE_GIT_SSH_PORT:-10022}" "git@${RANGE_GIT_HOST}" 2>&1 | grep -qi "welcome\|success\|gitlab"; then
            ok "GitLab SSH auth (${RANGE_GIT_HOST}:${RANGE_GIT_SSH_PORT:-10022})"
        else
            warn "GitLab SSH auth failed" "Add pubkey to GitLab profile SSH keys"
        fi
    fi

    # Determine available modes from connectivity
    modes_available="platform-ops"
    if [[ -n "${SPOKE_DEPLOYBOX_HOST:-}" ]] && timeout 3 bash -c "echo >/dev/tcp/${SPOKE_DEPLOYBOX_HOST}/22" 2>/dev/null; then
        modes_available="$modes_available green-dev"
    fi
    if [[ -n "${SPOKE_KALI_HOST:-}" ]] && timeout 3 bash -c "echo >/dev/tcp/${SPOKE_KALI_HOST}/22" 2>/dev/null; then
        modes_available="$modes_available red-team red-dev purple"
    fi
    ok "Available modes: $modes_available"

    if [[ "$spoke_total" -eq 0 ]]; then
        warn "No spoke hosts configured" "Set SPOKE_* vars in .env"
    elif [[ "$spoke_up" -eq 0 ]]; then
        warn "No spokes reachable" "Check VPN and spoke-firewall.sh"
    fi

    echo ""
}

# ── Run sections ─────────────────────────────────────────────────────────────
echo "Platform Health Check"
echo "====================="
echo ""

run_kali_tools() {
    echo "Kali Tools"
    echo "----------"

    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$SCRIPT_DIR/lib/load-env.sh"

    if [[ -z "${SPOKE_KALI_HOST:-}" ]]; then
        warn "SPOKE_KALI_HOST not set" "Kali tool check skipped"
        echo ""
        return
    fi

    if ! ssh -o ConnectTimeout=5 -o BatchMode=yes kali echo "ok" >/dev/null 2>&1; then
        warn "Kali SSH unreachable" "Check VPN and spoke-firewall.sh"
        echo ""
        return
    fi

    disk_pct=$(ssh -o ConnectTimeout=5 kali "df / | tail -1 | awk '{gsub(/%/,\"\",\$5); print \$5}'" 2>/dev/null || echo "?")
    if [[ "$disk_pct" != "?" && "$disk_pct" -gt 85 ]]; then
        fail "Kali disk at ${disk_pct}%" "Clean before installing tools"
    elif [[ "$disk_pct" != "?" ]]; then
        ok "Kali disk: ${disk_pct}%"
    fi

    snapshot_count=$(ssh -o ConnectTimeout=5 kali "ls /opt/kali-tool-snapshots/dpkg-*.list 2>/dev/null | wc -l" 2>/dev/null || echo "0")
    if [[ "$snapshot_count" -eq 0 ]]; then
        warn "No Kali tool snapshots" "Run: bash scripts/install-kali-tools.sh --snapshot"
    else
        ok "Kali tool snapshots: $snapshot_count"
    fi

    if command -v bash >/dev/null 2>&1 && [[ -f "$SCRIPT_DIR/check-kali-tools.sh" ]]; then
        tool_result=$(bash "$SCRIPT_DIR/check-kali-tools.sh" --check-only 2>&1 | tail -3)
        if echo "$tool_result" | grep -q "FAIL"; then
            fail "Kali critical tools missing" "Run: bash scripts/check-kali-tools.sh"
        else
            ok "Kali tools verified"
        fi
    else
        warn "check-kali-tools.sh not found" "Tool verification skipped"
    fi

    echo ""
}

case "$SECTION" in
    all)     run_docker; run_mcp; run_deps; run_ci; run_spoke; run_kali_tools ;;
    docker)  run_docker ;;
    mcp)     run_mcp ;;
    deps)    run_deps ;;
    ci)      run_ci ;;
    spoke)   run_spoke ;;
    kali)    run_kali_tools ;;
    *)       echo "Unknown section: $SECTION"; echo "Available: docker, mcp, deps, ci, spoke, kali, all"; exit 2 ;;
esac

echo "Health: ${PASS} ok, ${FAIL} failed, ${WARN} warnings"

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
exit 0
