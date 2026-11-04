#!/usr/bin/env bash
# deploy-tuoni-plugins.sh — Clone, build, and deploy TSE DynamicAlias scripts
# to Kali's Tuoni instance.
#
# Workflow:
#   1. Clone/pull Moon-Knight13/tuoni-plugins from GitHub
#   2. Run build_scripts.py to inline shared code into dist/
#   3. SCP dist/*.py to Kali /srv/tuoni/data/scripts/
#   4. Restart tuoni-server container
#   5. Verify scripts are loaded
#
# Requires: git, python3, ssh (kali alias), SPOKE_KALI_HOST in .env
#
# Usage:
#   bash scripts/deploy-tuoni-plugins.sh              # default: clone + build + deploy
#   bash scripts/deploy-tuoni-plugins.sh --skip-build  # deploy existing dist/ (already built)
#   bash scripts/deploy-tuoni-plugins.sh --check-only   # verify deployed scripts, no changes
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=scripts/lib/load-env.sh
source "$SCRIPT_DIR/lib/load-env.sh"

KALI_HOST="${SPOKE_KALI_HOST:-}"
PLUGINS_REPO="https://github.com/Moon-Knight13/tuoni-plugins.git"
PLUGINS_BRANCH="refactor/overhaul-v2"
PLUGINS_DIR="${TUONI_PLUGINS_CLONE_DIR:-${PROJECT_DIR}/.cache/tuoni-plugins}"
REMOTE_SCRIPTS_DIR="/srv/tuoni/data/scripts"

SKIP_BUILD=false
CHECK_ONLY=false

for arg in "$@"; do
    case "$arg" in
        --skip-build) SKIP_BUILD=true ;;
        --check-only) CHECK_ONLY=true ;;
        --help|-h)
            echo "Usage: $0 [--skip-build] [--check-only]"
            echo "  --skip-build   Deploy existing dist/ without rebuilding"
            echo "  --check-only   Verify deployed scripts, make no changes"
            exit 0 ;;
        *) echo "Unknown arg: $arg"; exit 2 ;;
    esac
done

if [[ -z "$KALI_HOST" ]]; then
    echo "FAIL  SPOKE_KALI_HOST not set."
    exit 2
fi

# ── Check-only mode ─────────────────────────────────────────────────────
if [[ "$CHECK_ONLY" == true ]]; then
    echo "=== Plugin Deploy Check ==="
    remote_scripts=$(ssh -o ConnectTimeout=10 -o BatchMode=yes kali \
        "ls -1 ${REMOTE_SCRIPTS_DIR}/tuoni_*.py 2>/dev/null" 2>/dev/null) || true

    if [[ -z "$remote_scripts" ]]; then
        echo "FAIL  No TSE scripts found in ${REMOTE_SCRIPTS_DIR}"
        exit 1
    fi

    count=$(echo "$remote_scripts" | wc -l)
    echo "OK    $count TSE scripts deployed:"
    echo "$remote_scripts" | sed 's|.*/||' | sort | sed 's/^/  /'

    EXPECTED=(
        tuoni_ad_enum.py
        tuoni_agent_watcher.py
        tuoni_collect_intel.py
        tuoni_cred_dump.py
        tuoni_exfil_stage.py
        tuoni_get_system.py
        tuoni_host_id.py
        tuoni_ioc_cleanup.py
        tuoni_lateral_move.py
        tuoni_lateral_wmi.py
        tuoni_log_clear.py
        tuoni_net_recon.py
        tuoni_payload_gen.py
        tuoni_persist_swarm.py
        tuoni_route_hijack.py
        tuoni_vuln_assess.py
    )

    missing=()
    for s in "${EXPECTED[@]}"; do
        echo "$remote_scripts" | grep -q "$s" || missing+=("$s")
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo ""
        echo "WARN  Missing expected scripts:"
        printf '  %s\n' "${missing[@]}"
    fi
    exit 0
fi

# ── SSH pre-check ───────────────────────────────────────────────────────
echo "=== Deploy Tuoni Plugins ==="
echo ""
if ! ssh -o ConnectTimeout=10 -o BatchMode=yes kali echo "SSH OK" 2>/dev/null; then
    echo "FAIL  Cannot SSH to kali ($KALI_HOST)"
    exit 1
fi

# ── Clone or update repo ───────────────────────────────────────────────
if [[ "$SKIP_BUILD" == false ]]; then
    echo "--- Clone/Update ---"
    if [[ -d "$PLUGINS_DIR/.git" ]]; then
        echo "Updating existing clone at $PLUGINS_DIR"
        git -C "$PLUGINS_DIR" fetch origin "$PLUGINS_BRANCH" 2>&1
        git -C "$PLUGINS_DIR" checkout "$PLUGINS_BRANCH" 2>&1
        git -C "$PLUGINS_DIR" reset --hard "origin/$PLUGINS_BRANCH" 2>&1
    else
        echo "Cloning $PLUGINS_REPO ($PLUGINS_BRANCH)"
        mkdir -p "$(dirname "$PLUGINS_DIR")"
        git clone --branch "$PLUGINS_BRANCH" --single-branch "$PLUGINS_REPO" "$PLUGINS_DIR" 2>&1
    fi

    # ── Build (inline shared code) ─────────────────────────────────────
    echo ""
    echo "--- Build ---"
    if [[ ! -f "$PLUGINS_DIR/build_scripts.py" ]]; then
        echo "FAIL  build_scripts.py not found in $PLUGINS_DIR"
        echo "      Repo structure may have changed. Check tuoni-plugins README."
        exit 1
    fi

    cd "$PLUGINS_DIR"
    python3 -I build_scripts.py 2>&1
    cd "$PROJECT_DIR"

    dist_count=$(find "$PLUGINS_DIR/dist" -name "tuoni_*.py" 2>/dev/null | wc -l)
    if [[ "$dist_count" -eq 0 ]]; then
        echo "FAIL  Build produced no scripts in dist/"
        exit 1
    fi
    echo "Built $dist_count scripts in dist/"
fi

# ── Locate dist/ ───────────────────────────────────────────────────────
DIST_DIR="$PLUGINS_DIR/dist"
if [[ ! -d "$DIST_DIR" ]]; then
    echo "FAIL  dist/ not found at $DIST_DIR"
    echo "      Run without --skip-build to clone and build first."
    exit 1
fi

deploy_files=$(find "$DIST_DIR" -name "tuoni_*.py" -type f)
deploy_count=$(echo "$deploy_files" | wc -l)

if [[ "$deploy_count" -eq 0 ]]; then
    echo "FAIL  No tuoni_*.py files in $DIST_DIR"
    exit 1
fi

echo ""
echo "--- Deploy ($deploy_count scripts) ---"

# ── Backup existing scripts on Kali ────────────────────────────────────
backup_dir="${REMOTE_SCRIPTS_DIR}.bak.$(date +%Y%m%d-%H%M%S)"
echo "Backing up existing scripts to $backup_dir"
ssh kali "sudo cp -a ${REMOTE_SCRIPTS_DIR} ${backup_dir} 2>/dev/null || true"

# ── SCP scripts to Kali ───────────────────────────────────────────────
# SCP to tmp first (rt user), then sudo mv into place
tmp_deploy="/tmp/tuoni-plugin-deploy-$$"
ssh kali "mkdir -p $tmp_deploy"
scp -q "$DIST_DIR"/tuoni_*.py "kali:$tmp_deploy/"

ssh kali "sudo cp ${tmp_deploy}/tuoni_*.py ${REMOTE_SCRIPTS_DIR}/ && \
          sudo chown root:root ${REMOTE_SCRIPTS_DIR}/tuoni_*.py && \
          sudo chmod 644 ${REMOTE_SCRIPTS_DIR}/tuoni_*.py && \
          rm -rf ${tmp_deploy}"

echo "Deployed $deploy_count scripts to ${REMOTE_SCRIPTS_DIR}"

# ── Restart tuoni-server ───────────────────────────────────────────────
echo ""
echo "--- Restart tuoni-server ---"
ssh kali "sudo docker restart tuoni-server" 2>&1

echo "Waiting for Tuoni API..."
for i in $(seq 1 30); do
    api_code=$(ssh -o ConnectTimeout=5 kali \
        "curl -sk --connect-timeout 3 -o /dev/null -w '%{http_code}' \
         https://localhost:${SPOKE_KALI_C2_WEB_PORT:-8443}/api/v1/auth/login" \
        2>/dev/null) || api_code="000"
    if [[ "$api_code" != "000" ]]; then
        echo "API responding (HTTP $api_code) after ${i}s"
        break
    fi
    sleep 1
done

if [[ "$api_code" == "000" ]]; then
    echo "WARN  API not responding after 30s — check tuoni-server logs:"
    echo "      ssh kali 'sudo docker logs --tail 50 tuoni-server'"
    exit 1
fi

# ── Verify ─────────────────────────────────────────────────────────────
echo ""
echo "--- Verify ---"
remote_count=$(ssh kali "ls -1 ${REMOTE_SCRIPTS_DIR}/tuoni_*.py 2>/dev/null | wc -l" 2>/dev/null || echo "0")
echo "Scripts on Kali: $remote_count"

if [[ "$remote_count" -ge "$deploy_count" ]]; then
    echo "OK    Deploy complete. $remote_count TSE scripts active."
    echo "      Backup at: $backup_dir"
else
    echo "WARN  Expected $deploy_count, found $remote_count on Kali"
fi

# ── Check for JAR version mismatch ─────────────────────────────────────
jar_check=$(ssh kali \
    "sudo docker exec tuoni-server ls /app/plugins/ 2>/dev/null" 2>/dev/null) || true
srv_ver=$(ssh kali \
    "sudo docker exec tuoni-server cat /app/cp/version.txt 2>/dev/null || true" 2>/dev/null) || true

if [[ -n "$jar_check" && -n "$srv_ver" ]]; then
    srv_ver="${srv_ver%%$'\n'*}"
    mismatch=false
    while IFS= read -r jar; do
        [[ -z "$jar" ]] && continue
        jv=$(echo "$jar" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)
        [[ -n "$jv" && "$jv" != "$srv_ver" ]] && mismatch=true
    done <<< "$jar_check"
    if [[ "$mismatch" == true ]]; then
        echo ""
        echo "WARN  Plugin JAR version mismatch detected (JARs != server $srv_ver)"
        echo "      Run: ssh kali 'cd /srv/tuoni && sudo SILENT=1 ./tuoni update'"
    fi
fi

echo ""
echo "=== Done ==="
