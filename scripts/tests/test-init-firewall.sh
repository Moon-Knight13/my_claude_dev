#!/usr/bin/env bash
# test-init-firewall.sh — contract tests for .devcontainer/init-firewall.sh.
#
# The firewall script requires root + iptables + network, so it cannot be
# exercised directly in a test harness. These tests pin the structural
# guarantees that matter for security review: validation regexes, required
# domain allowlist, IPv6 deny-by-default, self-verification, and default-DROP
# policy — all without running iptables.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FW="$ROOT/.devcontainer/init-firewall.sh"
PASS=0; FAIL=0
ok()   { echo "  OK  $1"; ((PASS++)) || true; }
bad()  { echo " FAIL $1"; ((FAIL++)) || true; }
check(){ if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }

echo "init-firewall.sh contract tests"
echo "================================"

# ── 1. Syntax ────────────────────────────────────────────────────────────
echo ""
echo "[1] Script syntax:"
if bash -n "$FW" 2>/dev/null; then
    ok "bash -n passes"
else
    bad "bash -n fails"
fi

# ── 2. CIDR validation regex ─────────────────────────────────────────────
echo ""
echo "[2] CIDR validation regex:"
CIDR_RE='^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$'
if grep -qF "$CIDR_RE" "$FW"; then
    ok "CIDR regex present in script"
else
    bad "CIDR regex missing — validation may be broken"
fi

for good in "192.168.1.0/24" "10.0.0.0/8" "140.82.112.0/20" "1.2.3.4/32"; do
    if [[ "$good" =~ $CIDR_RE ]]; then ok "CIDR accepts $good"
    else bad "CIDR rejects valid $good"; fi
done
for bad_val in "2606:50c0::/32" "not-a-cidr" "192.168.1.0" "10.0.0.0/abc"; do
    if [[ ! "$bad_val" =~ $CIDR_RE ]]; then ok "CIDR rejects $bad_val"
    else bad "CIDR accepts invalid $bad_val"; fi
done

# ── 3. IP validation regex ───────────────────────────────────────────────
echo ""
echo "[3] IP validation regex:"
IP_RE='^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'
if grep -qF "$IP_RE" "$FW"; then
    ok "IP regex present in script"
else
    bad "IP regex missing — DNS result validation may be broken"
fi

for good in "1.2.3.4" "255.255.255.255" "10.0.0.1"; do
    if [[ "$good" =~ $IP_RE ]]; then ok "IP accepts $good"
    else bad "IP rejects valid $good"; fi
done
for bad_val in "::1" "fe80::1" "not-an-ip" "1.2.3"; do
    if [[ ! "$bad_val" =~ $IP_RE ]]; then ok "IP rejects $bad_val"
    else bad "IP accepts invalid $bad_val"; fi
done

# ── 4. Required domain allowlist ─────────────────────────────────────────
echo ""
echo "[4] Required domain allowlist:"
REQUIRED_DOMAINS=(
    registry.npmjs.org
    api.anthropic.com
    codeload.github.com
    raw.githubusercontent.com
    objects.githubusercontent.com
    pypi.org
    files.pythonhosted.org
)
for domain in "${REQUIRED_DOMAINS[@]}"; do
    if grep -qF "\"$domain\"" "$FW"; then ok "allowlist includes $domain"
    else bad "allowlist missing $domain"; fi
done

# ── 5. IPv6 skip logic ──────────────────────────────────────────────────
echo ""
echo "[5] IPv6 handling:"
if grep -q '\*:\*' "$FW"; then
    ok "IPv6 CIDR skip pattern present"
else
    bad "IPv6 CIDR skip pattern missing — IPv6 ranges may be fed to ipset"
fi
if grep -q 'ip6tables -P OUTPUT DROP' "$FW"; then
    ok "IPv6 default-DROP policy set"
else
    bad "IPv6 default-DROP policy missing"
fi

# ── 6. Default-DROP and self-verification ────────────────────────────────
echo ""
echo "[6] Policy and verification:"
if grep -q 'iptables -P OUTPUT DROP' "$FW"; then
    ok "IPv4 OUTPUT default-DROP policy"
else
    bad "IPv4 OUTPUT default-DROP missing — firewall is open by default"
fi
if grep -q 'iptables -P INPUT DROP' "$FW"; then
    ok "IPv4 INPUT default-DROP policy"
else
    bad "IPv4 INPUT default-DROP missing"
fi
if grep -q 'example\.com' "$FW"; then
    ok "self-test blocks example.com"
else
    bad "self-test for blocked domain missing"
fi
if grep -q 'api\.github\.com' "$FW"; then
    ok "self-test verifies GitHub API reachable"
else
    bad "self-test for allowed domain missing"
fi

# ── 7. Host gateway detection ────────────────────────────────────────────
echo ""
echo "[7] Host gateway detection:"
if grep -q "ip route.*awk.*/default/.*print \\\$3" "$FW"; then
    ok "gateway parsed from default route"
else
    bad "gateway detection pattern missing or changed"
fi
if grep -qF 'dport 11434' "$FW" && grep -qF 'dport 22' "$FW"; then
    ok "host egress allows Ollama (11434) and SSH (22)"
else
    bad "host egress port rules missing"
fi

# ── Summary ──────────────────────────────────────────────────────────────
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if [[ $FAIL -gt 0 ]]; then exit 1; fi
