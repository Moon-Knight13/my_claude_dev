#!/usr/bin/env bash
# check-kali-tools.sh — verify tool inventory on Kali spoke.
#
# Non-destructive, read-only. Reports what is installed, missing, or broken.
# Mirrors check-tuoni-health.sh pattern for spoke infrastructure monitoring.
#
# Usage:
#   bash scripts/check-kali-tools.sh                # full inventory
#   bash scripts/check-kali-tools.sh --tier 1       # stock Kali only
#   bash scripts/check-kali-tools.sh --json         # machine-readable output
#   bash scripts/check-kali-tools.sh --check-only   # exit 0/1 for CI gate
#
# Exit: 0 if all required tools present, 1 if critical tools missing.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/load-env.sh
source "$SCRIPT_DIR/lib/load-env.sh"

KALI_HOST="${SPOKE_KALI_HOST:-}"
TIER_FILTER=""
JSON_MODE=false
CHECK_ONLY=false

for arg in "$@"; do
    case "$arg" in
        --tier) shift; TIER_FILTER="${1:-}" ;;
        1|2|3|4|5|6) [[ -n "$TIER_FILTER" ]] || TIER_FILTER="$arg" ;;
        --json) JSON_MODE=true ;;
        --check-only) CHECK_ONLY=true ;;
        --help|-h)
            echo "Usage: $0 [--tier N] [--json] [--check-only]"
            exit 0 ;;
    esac
    shift 2>/dev/null || true
done

if [[ -z "$KALI_HOST" ]]; then
    echo "FAIL: SPOKE_KALI_HOST not set."
    exit 2
fi

# ── SSH reachability ──────────────────────────────────────────────────────
if ! ssh -o ConnectTimeout=10 -o BatchMode=yes kali echo "ok" >/dev/null 2>&1; then
    echo "FAIL: Cannot SSH to kali ($KALI_HOST)"
    exit 1
fi

ok=0
missing=0
warn=0
results=""

check_binary() {
    local tier="$1" name="$2" critical="${3:-false}"
    [[ -n "$TIER_FILTER" && "$TIER_FILTER" != "$tier" ]] && return

    if ssh -o ConnectTimeout=5 kali "command -v $name >/dev/null 2>&1" 2>/dev/null; then
        ((ok++)) || true
        results+="$tier|$name|installed|$critical\n"
    else
        if [[ "$critical" == "true" ]]; then
            ((missing++)) || true
        else
            ((warn++)) || true
        fi
        results+="$tier|$name|MISSING|$critical\n"
    fi
}

check_pip() {
    local name="$1" critical="${2:-false}"
    [[ -n "$TIER_FILTER" && "$TIER_FILTER" != "3" ]] && return

    if ssh -o ConnectTimeout=5 kali "pip3 show $name >/dev/null 2>&1" 2>/dev/null; then
        ((ok++)) || true
        results+="3|$name|installed|$critical\n"
    else
        if [[ "$critical" == "true" ]]; then
            ((missing++)) || true
        else
            ((warn++)) || true
        fi
        results+="3|$name|MISSING|$critical\n"
    fi
}

check_file() {
    local tier="$1" name="$2" path="$3" critical="${4:-false}"
    [[ -n "$TIER_FILTER" && "$TIER_FILTER" != "$tier" ]] && return

    if ssh -o ConnectTimeout=5 kali "test -f $path" 2>/dev/null; then
        ((ok++)) || true
        results+="$tier|$name|installed|$critical\n"
    else
        if [[ "$critical" == "true" ]]; then
            ((missing++)) || true
        else
            ((warn++)) || true
        fi
        results+="$tier|$name|MISSING|$critical\n"
    fi
}

# ── Pre-install safety: disk and memory ───────────────────────────────────
echo "=== Kali Spoke Tool Inventory: $KALI_HOST ==="
echo ""
echo "--- System Resources ---"

disk_info=$(ssh -o ConnectTimeout=5 kali "df -h / | tail -1" 2>/dev/null || echo "unknown")
mem_info=$(ssh -o ConnectTimeout=5 kali "free -h | awk '/^Mem:/{print \$2,\$3,\$4}'" 2>/dev/null || echo "unknown")
echo "Disk: $disk_info"
echo "Memory (total used free): $mem_info"

disk_pct=$(echo "$disk_info" | awk '{gsub(/%/,"",$5); print $5}')
if [[ -n "$disk_pct" && "$disk_pct" -gt 90 ]]; then
    echo "WARNING: Disk usage ${disk_pct}% — do NOT install additional packages"
    echo "Run cleanup before proceeding."
    [[ "$CHECK_ONLY" == true ]] && exit 1
fi
echo ""

# ── Tier 1: Stock Kali (critical) ─────────────────────────────────────────
echo "--- Tier 1: Stock Kali Tools (verify only) ---"
for tool in nmap masscan hydra medusa crackmapexec smbclient rpcclient \
    enum4linux-ng impacket-secretsdump impacket-wmiexec impacket-psexec \
    impacket-smbexec impacket-ntlmrelayx xfreerdp rdesktop sshpass \
    proxychains4 chisel socat gobuster feroxbuster nikto sqlmap responder \
    searchsploit bloodhound-python ldapsearch certipy evil-winrm hping3 \
    tshark john hashcat wfuzz; do
    check_binary 1 "$tool" true
done

# ── Tier 2: APT packages ─────────────────────────────────────────────────
echo "--- Tier 2: APT Packages ---"
check_binary 2 "redis-cli" true
check_binary 2 "psql" true

# ── Tier 3: Python packages ──────────────────────────────────────────────
echo "--- Tier 3: Python Packages ---"
for pkg in pexpect paramiko coercer mitm6 ldapdomaindump adidnsdump pypykatz Pcredz netexec; do
    check_pip "$pkg" false
done

# ── Tier 4: Binary tools ─────────────────────────────────────────────────
echo "--- Tier 4: Binary Downloads ---"
check_file 4 "ligolo-agent" "/opt/tools/ligolo-agent" false
check_file 4 "kerbrute" "/opt/tools/kerbrute" false

# ── Tier 5: .NET assemblies ──────────────────────────────────────────────
echo "--- Tier 5: .NET Assemblies ---"
for asm in SharpHound.exe Rubeus.exe Certify.exe Seatbelt.exe; do
    check_file 5 "$asm" "/opt/assemblies/$asm" false
done

# ── Tier 6: Custom tools ─────────────────────────────────────────────────
echo "--- Tier 6: Custom ---"
check_file 6 "icmp_c2.py" "/opt/tools/icmp_c2.py" false

# ── MCP service prerequisites ────────────────────────────────────────────
echo "--- MCP Service Prerequisites ---"
# BloodHound CE + Neo4j (for BloodHound MCP)
bh_status=$(ssh -o ConnectTimeout=5 kali \
    "docker ps --filter 'name=bloodhound' --format '{{.Status}}' 2>/dev/null || echo 'not running'" \
    2>/dev/null || echo "check failed")
neo4j_status=$(ssh -o ConnectTimeout=5 kali \
    "docker ps --filter 'name=neo4j' --format '{{.Status}}' 2>/dev/null || echo 'not running'" \
    2>/dev/null || echo "check failed")

echo "BloodHound CE: $bh_status"
echo "Neo4j: $neo4j_status"

# Nuclei scanner + templates
check_binary 2 "nuclei" false
nuclei_templates=$(ssh -o ConnectTimeout=5 kali \
    "ls /root/nuclei-templates/ 2>/dev/null | wc -l || echo 0" \
    2>/dev/null || echo "0")
echo "Nuclei templates: $nuclei_templates directories"

# ── Summary ───────────────────────────────────────────────────────────────
echo ""
echo "=== Summary ==="
echo "Installed: $ok"
echo "Missing (critical): $missing"
echo "Missing (optional): $warn"

if [[ "$JSON_MODE" == true ]]; then
    echo ""
    echo "--- JSON ---"
    echo -e "$results" | awk -F'|' 'NF>1{printf "{\"tier\":%s,\"tool\":\"%s\",\"status\":\"%s\",\"critical\":%s}\n",$1,$2,$3,$4}'
fi

if [[ "$CHECK_ONLY" == true && $missing -gt 0 ]]; then
    echo "FAIL: $missing critical tools missing."
    exit 1
fi

echo "Tool check complete."
