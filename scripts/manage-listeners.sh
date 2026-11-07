#!/usr/bin/env bash
# Tuoni listener management and pre-flight validation.
#
# Usage:
#   manage-listeners.sh validate-dns --domain <domain> --ip <listener-ip> [--ns <nameserver>]
#   manage-listeners.sh validate-dns --domain cb.example.com --ip 10.0.1.50
#
# Exit codes: 0 = all checks pass, 1 = one or more checks failed, 2 = usage error
set -euo pipefail

PASS=0
WARN=0
FAIL=0

ok()   { echo "  [PASS] $1"; ((PASS++)) || true; }
warn() { echo "  [WARN] $1"; [[ -n "${2:-}" ]] && echo "         -> $2"; ((WARN++)) || true; }
fail() { echo "  [FAIL] $1"; [[ -n "${2:-}" ]] && echo "         -> $2"; ((FAIL++)) || true; }
info() { echo "  [INFO] $1"; }

usage() {
    cat <<'EOF'
Usage: manage-listeners.sh <command> [options]

Commands:
  validate-dns    Pre-flight DNS delegation check for DNS listener deployment

validate-dns options:
  --domain <domain>   Callback domain (e.g. cb.example.com)
  --ip <ip>           Expected Tuoni listener IP
  --ns <nameserver>   Upstream nameserver to query (default: system resolver)
  --timeout <secs>    dig timeout per query (default: 5)
  --quiet             Suppress info lines, only show pass/warn/fail
EOF
    exit 2
}

# ── validate-dns ─────────────────────────────────────────────────────────

validate_dns() {
    local domain="" listener_ip="" nameserver="" timeout=5 quiet=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --domain)  domain="$2"; shift 2 ;;
            --ip)      listener_ip="$2"; shift 2 ;;
            --ns)      nameserver="$2"; shift 2 ;;
            --timeout) timeout="$2"; shift 2 ;;
            --quiet)   quiet=true; shift ;;
            *) echo "ERROR: unknown option: $1"; usage ;;
        esac
    done

    [[ -z "$domain" ]]      && { echo "ERROR: --domain required"; usage; }
    [[ -z "$listener_ip" ]] && { echo "ERROR: --ip required"; usage; }

    if ! command -v dig >/dev/null 2>&1; then
        echo "ERROR: dig not found. Install dnsutils / bind-utils."
        exit 2
    fi

    echo "DNS Pre-flight Validation"
    echo "========================="
    echo "  Domain:      $domain"
    echo "  Listener IP: $listener_ip"
    [[ -n "$nameserver" ]] && echo "  Nameserver:  $nameserver"
    echo ""

    local ns_flag=""
    [[ -n "$nameserver" ]] && ns_flag="@${nameserver}"

    # ── 1. NS record delegation ──────────────────────────────────────────
    $quiet || info "Checking NS records for $domain..."
    local ns_output
    # shellcheck disable=SC2086
    ns_output="$(dig +short +time="$timeout" $ns_flag NS "$domain" 2>/dev/null || true)"

    if [[ -z "$ns_output" ]]; then
        fail "No NS records found for $domain" \
             "Parent zone must delegate NS to your listener. Add: $domain NS <tuoni-host>"
    else
        $quiet || info "NS records: $(echo "$ns_output" | tr '\n' ' ')"

        local ns_points_to_ip=false
        while IFS= read -r ns_host; do
            [[ -z "$ns_host" ]] && continue
            ns_host="${ns_host%.}"
            local ns_resolved
            # shellcheck disable=SC2086
            ns_resolved="$(dig +short +time="$timeout" $ns_flag A "$ns_host" 2>/dev/null || true)"
            if echo "$ns_resolved" | grep -qF "$listener_ip"; then
                ns_points_to_ip=true
                ok "NS $ns_host resolves to $listener_ip"
            else
                $quiet || info "NS $ns_host resolves to: ${ns_resolved:-<nothing>}"
            fi
        done <<< "$ns_output"

        if $ns_points_to_ip; then
            ok "NS delegation points to listener IP"
        else
            fail "No NS record resolves to $listener_ip" \
                 "Ensure NS host A record points to $listener_ip"
        fi
    fi

    # ── 2. Direct query to listener (authoritative test) ─────────────────
    $quiet || info "Querying listener directly at $listener_ip for $domain SOA..."
    local direct_soa
    direct_soa="$(dig +short +time="$timeout" "@${listener_ip}" SOA "$domain" 2>/dev/null || true)"

    if [[ -n "$direct_soa" ]]; then
        ok "Listener responds to SOA query for $domain"
    else
        local direct_any
        direct_any="$(dig +time="$timeout" "@${listener_ip}" ANY "$domain" 2>/dev/null || true)"
        if echo "$direct_any" | grep -q "status: NOERROR\|status: NXDOMAIN"; then
            warn "Listener responds but no SOA record" \
                 "DNS listener may not be started yet. SOA response expected after listener start."
        else
            fail "Listener at $listener_ip not responding to DNS queries" \
                 "Check: 1) Tuoni DNS listener running on port 53  2) Firewall allows UDP/TCP 53  3) IP correct"
        fi
    fi

    # ── 3. A record test query ───────────────────────────────────────────
    local test_host="preflight-test.${domain}"
    $quiet || info "Testing A record resolution: $test_host via listener..."
    local test_a
    test_a="$(dig +short +time="$timeout" "@${listener_ip}" A "$test_host" 2>/dev/null || true)"

    if [[ -n "$test_a" ]]; then
        ok "Test query $test_host returned: $test_a"
    else
        warn "No A record response for $test_host" \
             "Expected if DNS listener not yet started. Will work once listener is active."
    fi

    # ── 4. End-to-end resolution through public resolver ─────────────────
    $quiet || info "Testing end-to-end resolution through system resolver..."
    local e2e_ns
    e2e_ns="$(dig +short +time="$timeout" NS "$domain" 2>/dev/null || true)"
    local e2e_a
    e2e_a="$(dig +short +time="$timeout" A "$test_host" 2>/dev/null || true)"

    if [[ -n "$e2e_a" ]]; then
        ok "End-to-end resolution works: $test_host -> $e2e_a"
    elif [[ -n "$e2e_ns" ]]; then
        warn "NS records visible but A query failed end-to-end" \
             "DNS propagation may need time, or listener not yet responding"
    else
        warn "End-to-end resolution not working yet" \
             "Check NS delegation from parent zone"
    fi

    # ── 5. TTL check ─────────────────────────────────────────────────────
    $quiet || info "Checking NS record TTL..."
    local ttl_output
    # shellcheck disable=SC2086
    ttl_output="$(dig +noall +answer +time="$timeout" $ns_flag NS "$domain" 2>/dev/null || true)"

    if [[ -n "$ttl_output" ]]; then
        local ttl
        ttl="$(echo "$ttl_output" | awk 'NR==1{print $2}')"
        if [[ -n "$ttl" && "$ttl" =~ ^[0-9]+$ ]]; then
            if [[ "$ttl" -le 300 ]]; then
                ok "NS TTL is $ttl seconds (low, good for ops flexibility)"
            elif [[ "$ttl" -le 3600 ]]; then
                ok "NS TTL is $ttl seconds (reasonable)"
            elif [[ "$ttl" -le 86400 ]]; then
                warn "NS TTL is $ttl seconds (high)" \
                     "Changes take up to $((ttl / 3600))h to propagate. Consider lowering for ops."
            else
                warn "NS TTL is $ttl seconds (very high: $((ttl / 86400))d)" \
                     "Strongly consider lowering TTL before engagement"
            fi
        fi
    else
        $quiet || info "Could not determine TTL (no answer section)"
    fi

    # ── 6. Reverse lookup ────────────────────────────────────────────────
    $quiet || info "Checking PTR record for $listener_ip..."
    local ptr_output
    ptr_output="$(dig +short +time="$timeout" -x "$listener_ip" 2>/dev/null || true)"

    if [[ -n "$ptr_output" ]]; then
        info "PTR for $listener_ip: $ptr_output"
        if echo "$ptr_output" | grep -qiF "$domain"; then
            ok "Reverse lookup matches callback domain"
        else
            warn "PTR exists but does not match $domain" \
                 "PTR: $ptr_output — may not matter for ops but could aid defender correlation"
        fi
    else
        $quiet || info "No PTR record for $listener_ip (common, not a blocker)"
    fi

    # ── 7. Conflicting records ───────────────────────────────────────────
    $quiet || info "Checking for conflicting A/AAAA/CNAME records on $domain..."
    local existing_a existing_aaaa existing_cname
    # shellcheck disable=SC2086
    existing_a="$(dig +short +time="$timeout" $ns_flag A "$domain" 2>/dev/null || true)"
    # shellcheck disable=SC2086
    existing_aaaa="$(dig +short +time="$timeout" $ns_flag AAAA "$domain" 2>/dev/null || true)"
    # shellcheck disable=SC2086
    existing_cname="$(dig +short +time="$timeout" $ns_flag CNAME "$domain" 2>/dev/null || true)"

    local conflicts=0
    if [[ -n "$existing_a" ]]; then
        local conflict_found=false
        while IFS= read -r addr; do
            [[ -z "$addr" ]] && continue
            if [[ "$addr" != "$listener_ip" ]]; then
                fail "Conflicting A record: $domain -> $addr (expected $listener_ip or no A)" \
                     "Remove or update A record to avoid split resolution"
                conflict_found=true
                ((conflicts++)) || true
            fi
        done <<< "$existing_a"
        if ! $conflict_found && [[ -n "$existing_a" ]]; then
            ok "A record points to listener IP"
        fi
    fi

    if [[ -n "$existing_cname" ]]; then
        fail "CNAME record exists on $domain: $existing_cname" \
             "CNAME conflicts with NS delegation. Remove CNAME before deploying DNS listener."
        ((conflicts++)) || true
    fi

    if [[ -n "$existing_aaaa" ]]; then
        warn "AAAA record exists: $domain -> $existing_aaaa" \
             "IPv6 record may cause split traffic. Remove if not needed."
    fi

    if [[ "$conflicts" -eq 0 ]]; then
        ok "No conflicting records found"
    fi

    # ── Summary ──────────────────────────────────────────────────────────
    echo ""
    echo "Summary: $PASS passed, $WARN warnings, $FAIL failed"

    if [[ "$FAIL" -gt 0 ]]; then
        echo ""
        echo "DNS delegation NOT ready. Fix FAIL items above before creating DNS listener."
        return 1
    elif [[ "$WARN" -gt 0 ]]; then
        echo ""
        echo "DNS delegation has warnings. Review WARN items — some are expected before listener start."
        return 0
    else
        echo ""
        echo "DNS delegation ready. Proceed with DNS listener creation."
        return 0
    fi
}

# ── Main dispatch ────────────────────────────────────────────────────────

[[ $# -lt 1 ]] && usage

COMMAND="$1"
shift

case "$COMMAND" in
    validate-dns) validate_dns "$@" ;;
    *)
        echo "ERROR: unknown command: $COMMAND"
        usage
        ;;
esac
