#!/usr/bin/env bash
# install-kali-tools.sh — safely install additional tools on Kali spoke.
#
# Safety guardrails:
#   - Pre-flight disk/memory check (abort if disk >85%)
#   - Snapshot installed package list before changes
#   - Install only from declared manifest (no ad-hoc)
#   - Dry-run mode by default
#   - Rollback support via snapshot diff
#   - No system-level changes (kernel, init, network config)
#
# Usage:
#   bash scripts/install-kali-tools.sh --dry-run       # show what would install (DEFAULT)
#   bash scripts/install-kali-tools.sh --apply          # actually install
#   bash scripts/install-kali-tools.sh --apply --tier 2 # install tier 2 only
#   bash scripts/install-kali-tools.sh --rollback       # show packages added since last snapshot
#   bash scripts/install-kali-tools.sh --snapshot       # take package snapshot only
#
# Exit: 0 success, 1 safety check failed, 2 config error.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/load-env.sh
source "$SCRIPT_DIR/lib/load-env.sh"

KALI_HOST="${SPOKE_KALI_HOST:-}"
SNAPSHOT_DIR="/opt/kali-tool-snapshots"
DRY_RUN=true
APPLY=false
ROLLBACK=false
SNAPSHOT_ONLY=false
TIER_FILTER=""

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true; APPLY=false ;;
        --apply) APPLY=true; DRY_RUN=false ;;
        --rollback) ROLLBACK=true ;;
        --snapshot) SNAPSHOT_ONLY=true ;;
        --tier) shift; TIER_FILTER="${1:-}" ;;
        2|3|4|5|6) [[ -z "$TIER_FILTER" ]] && TIER_FILTER="$arg" ;;
        --help|-h)
            echo "Usage: $0 [--dry-run|--apply|--rollback|--snapshot] [--tier N]"
            exit 0 ;;
    esac
    shift 2>/dev/null || true
done

if [[ -z "$KALI_HOST" ]]; then
    echo "FAIL: SPOKE_KALI_HOST not set."
    exit 2
fi

# ── SSH check ─────────────────────────────────────────────────────────────
if ! ssh -o ConnectTimeout=10 -o BatchMode=yes kali echo "ok" >/dev/null 2>&1; then
    echo "FAIL: Cannot SSH to kali ($KALI_HOST)"
    exit 1
fi

run_kali() {
    ssh -o ConnectTimeout=30 kali "$@" 2>/dev/null
}

# ── Snapshot ──────────────────────────────────────────────────────────────
take_snapshot() {
    local ts
    ts=$(date +%Y%m%d-%H%M%S)
    echo "Taking package snapshot..."
    run_kali "mkdir -p $SNAPSHOT_DIR"
    run_kali "dpkg --get-selections > ${SNAPSHOT_DIR}/dpkg-${ts}.list"
    run_kali "pip3 list --format=freeze > ${SNAPSHOT_DIR}/pip3-${ts}.list 2>/dev/null || true"
    run_kali "ls -1 /opt/tools/ > ${SNAPSHOT_DIR}/binaries-${ts}.list 2>/dev/null || true"
    run_kali "ls -1 /opt/assemblies/ > ${SNAPSHOT_DIR}/assemblies-${ts}.list 2>/dev/null || true"
    echo "Snapshot saved: ${SNAPSHOT_DIR}/*-${ts}.list"
}

if [[ "$SNAPSHOT_ONLY" == true ]]; then
    take_snapshot
    exit 0
fi

# ── Rollback info ─────────────────────────────────────────────────────────
if [[ "$ROLLBACK" == true ]]; then
    echo "=== Rollback Info ==="
    latest_dpkg=$(run_kali "ls -t ${SNAPSHOT_DIR}/dpkg-*.list 2>/dev/null | head -1" || true)
    if [[ -z "$latest_dpkg" ]]; then
        echo "No snapshots found. Take one first: $0 --snapshot"
        exit 1
    fi
    echo "Latest snapshot: $latest_dpkg"
    echo ""
    echo "Packages added since snapshot:"
    run_kali "diff <(awk '{print \$1}' $latest_dpkg) <(dpkg --get-selections | awk '{print \$1}') | grep '^>' | sed 's/^> /  /' || echo '  (none)'"
    echo ""
    echo "To remove added packages:"
    echo "  ssh kali 'apt remove --purge <package-list>'"
    echo ""
    echo "Pip packages added:"
    latest_pip=$(run_kali "ls -t ${SNAPSHOT_DIR}/pip3-*.list 2>/dev/null | head -1" || true)
    if [[ -n "$latest_pip" ]]; then
        run_kali "diff <(cat $latest_pip | cut -d= -f1) <(pip3 list --format=freeze 2>/dev/null | cut -d= -f1) | grep '^>' | sed 's/^> /  /' || echo '  (none)'"
    fi
    exit 0
fi

# ── Pre-flight safety ────────────────────────────────────────────────────
echo "=== Pre-flight Safety Check ==="

disk_pct=$(run_kali "df / | tail -1 | awk '{gsub(/%/,\"\",\$5); print \$5}'")
disk_avail=$(run_kali "df -h / | tail -1 | awk '{print \$4}'")
mem_avail=$(run_kali "free -m | awk '/^Mem:/{print \$4}'")

echo "Disk used: ${disk_pct}% (${disk_avail} free)"
echo "Memory free: ${mem_avail}MB"

if [[ -n "$disk_pct" && "$disk_pct" -gt 85 ]]; then
    echo "ABORT: Disk usage ${disk_pct}% exceeds 85% safety threshold."
    echo "Free space before installing: docker prune, apt clean, remove old snapshots."
    exit 1
fi

if [[ -n "$mem_avail" && "$mem_avail" -lt 256 ]]; then
    echo "ABORT: Only ${mem_avail}MB free memory. Risk of OOM during install."
    exit 1
fi

echo "Safety checks passed."
echo ""

# ── Take pre-install snapshot ────────────────────────────────────────────
if [[ "$APPLY" == true ]]; then
    take_snapshot
    echo ""
fi

# ── Install functions ────────────────────────────────────────────────────
installed=0
skipped=0
failed=0

install_apt() {
    local pkg="$1"
    if run_kali "dpkg -l $pkg 2>/dev/null | grep -q '^ii'" 2>/dev/null; then
        echo "  SKIP $pkg (already installed)"
        ((skipped++)) || true
        return
    fi
    if [[ "$DRY_RUN" == true ]]; then
        echo "  WOULD INSTALL (apt): $pkg"
        return
    fi
    echo "  INSTALLING (apt): $pkg"
    if run_kali "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $pkg"; then
        echo "  OK $pkg"
        ((installed++)) || true
    else
        echo "  FAIL $pkg"
        ((failed++)) || true
    fi
}

install_pip() {
    local pkg="$1"
    if run_kali "pip3 show $pkg >/dev/null 2>&1"; then
        echo "  SKIP $pkg (already installed)"
        ((skipped++)) || true
        return
    fi
    if [[ "$DRY_RUN" == true ]]; then
        echo "  WOULD INSTALL (pip): $pkg"
        return
    fi
    echo "  INSTALLING (pip): $pkg"
    if run_kali "pip3 install --break-system-packages $pkg"; then
        echo "  OK $pkg"
        ((installed++)) || true
    else
        echo "  FAIL $pkg"
        ((failed++)) || true
    fi
}

install_binary() {
    local name="$1" url="$2" dest="$3"
    if run_kali "test -x $dest"; then
        echo "  SKIP $name (exists at $dest)"
        ((skipped++)) || true
        return
    fi
    if [[ "$DRY_RUN" == true ]]; then
        echo "  WOULD DOWNLOAD: $name -> $dest"
        return
    fi
    echo "  DOWNLOADING: $name"
    run_kali "mkdir -p $(dirname "$dest")"
    if run_kali "curl -sL -o $dest '$url' && chmod +x $dest"; then
        echo "  OK $name -> $dest"
        run_kali "ln -sf $dest /usr/local/bin/$name 2>/dev/null || true"
        ((installed++)) || true
    else
        echo "  FAIL $name"
        run_kali "rm -f $dest"
        ((failed++)) || true
    fi
}

# ── Tier 2: APT packages ─────────────────────────────────────────────────
if [[ -z "$TIER_FILTER" || "$TIER_FILTER" == "2" ]]; then
    echo "--- Tier 2: APT Packages ---"
    run_kali "apt-get update -qq" 2>/dev/null || true
    install_apt redis-tools
    install_apt postgresql-client
    install_apt nuclei
    echo ""
fi

# ── Tier 3: Python packages ──────────────────────────────────────────────
if [[ -z "$TIER_FILTER" || "$TIER_FILTER" == "3" ]]; then
    echo "--- Tier 3: Python Packages ---"
    for pkg in pexpect paramiko coercer mitm6 ldapdomaindump adidnsdump pypykatz Pcredz netexec; do
        install_pip "$pkg"
    done
    echo ""
fi

# ── Tier 4: Binary downloads ─────────────────────────────────────────────
if [[ -z "$TIER_FILTER" || "$TIER_FILTER" == "4" ]]; then
    echo "--- Tier 4: Binary Downloads ---"
    echo "  NOTE: Binary URLs must be set per-version. Check GitHub releases."
    echo "  Placeholders — operator must provide URLs or pre-stage binaries."
    # Actual URLs change per release. Operator provides or pre-stages.
    if ! run_kali "test -x /opt/tools/ligolo-agent"; then
        echo "  MISSING: ligolo-agent — stage to /opt/tools/ligolo-agent"
    else
        echo "  SKIP ligolo-agent (exists)"
    fi
    if ! run_kali "test -x /opt/tools/kerbrute"; then
        echo "  MISSING: kerbrute — stage to /opt/tools/kerbrute"
    else
        echo "  SKIP kerbrute (exists)"
    fi
    echo ""
fi

# ── Tier 5: .NET assemblies ──────────────────────────────────────────────
if [[ -z "$TIER_FILTER" || "$TIER_FILTER" == "5" ]]; then
    echo "--- Tier 5: .NET Assemblies ---"
    echo "  NOTE: Assemblies must be pre-compiled or downloaded from trusted source."
    run_kali "mkdir -p /opt/assemblies" 2>/dev/null || true
    for asm in SharpHound.exe Rubeus.exe Certify.exe Seatbelt.exe; do
        if run_kali "test -f /opt/assemblies/$asm"; then
            echo "  SKIP $asm (exists)"
        else
            echo "  MISSING: $asm — stage to /opt/assemblies/$asm"
        fi
    done
    echo ""
fi

# ── Summary ───────────────────────────────────────────────────────────────
echo "=== Summary ==="
if [[ "$DRY_RUN" == true ]]; then
    echo "MODE: DRY-RUN (no changes made)"
    echo "Run with --apply to install."
else
    echo "Installed: $installed"
    echo "Skipped (present): $skipped"
    echo "Failed: $failed"
    if [[ $failed -gt 0 ]]; then
        echo "WARNING: $failed installs failed. Check errors above."
        echo "Rollback info: $0 --rollback"
        exit 1
    fi
fi
echo "Done."
