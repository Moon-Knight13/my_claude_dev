#!/usr/bin/env bash
# ctp-deploy-range — deploy a test range in correct order, skip what's already up.
#
# "As a dev I want to deploy a test range in correct order without race issues."
#
# Usage:
#   ctp-deploy-range <team>              # status: what's deployed, what's pending
#   ctp-deploy-range <team> deploy       # deploy everything pending, in order
#   ctp-deploy-range <team> <stage>      # deploy one stage only
#
# Stages (in order):
#   infra        ISP routers, core routers, firewalls
#   dc           domain controllers (primary then secondary)
#   core         proxies, mail servers
#   services     app servers, sensors, OT, testing boxes
#   workstations ws*, soc-ws*, nato-ws*, kali, laptops
#
# How it works:
#   1. Fetches inventory from Providentia (all *_<team> hosts)
#   2. Checks vCenter for which VMs already exist (one bulk query)
#   3. Skips deployed hosts, deploys only what's missing
#   4. Infra/dc/core: sequential (few hosts, strict dependency order)
#   5. Services/workstations: two-phase (clone parallel, configure sequential)
#   6. On failure: stops and shows retry command
#
# Race protection:
#   - vCenter check sees VMs deployed by ANY developer, not just you
#   - Blocks if another ansible-playbook is already running in your container
#   - Ansible is idempotent: worst case two devs deploy same host = wasted time, not broken state
set -euo pipefail

TEAM="${1:-}"
ACTION="${2:-status}"

if [[ -z "$TEAM" ]]; then
    cat <<'USAGE'
Usage: ctp-deploy-range <team> [deploy|status|<stage>]

  ctp-deploy-range t10              show what's deployed vs pending
  ctp-deploy-range t10 deploy       deploy everything pending, in order
  ctp-deploy-range t10 infra        deploy just infra stage
USAGE
    exit 1
fi

CONTAINER="${CTP_CONTAINER:-catapult-$(id -un)}"
WORKDIR="/srv/inventories/dcm"

ALLOWED_TEAMS="t10"
if [[ " $ALLOWED_TEAMS " != *" $TEAM "* ]]; then
    echo "!! team '$TEAM' not allowed ($ALLOWED_TEAMS). Edit ALLOWED_TEAMS in $0 if approved." >&2
    exit 1
fi

STAGE_ORDER=(infra dc core services workstations)

declare -A STAGE_DESC=(
    [infra]="ISP routers, core routers, firewalls"
    [dc]="Domain controllers (primary then secondary)"
    [core]="Proxies, mail servers"
    [services]="App servers, sensors, OT, testing boxes"
    [workstations]="Workstations, kali, contractor laptops"
)

# --- classify host into stage ------------------------------------------------
classify() {
    local host="$1" name
    name="${host%_"${TEAM}"}"
    case "$name" in
        r-isp*|r[0-9]|r[0-9][0-9]|r-*) echo infra ;;
        fw1-*)                           echo infra ;;
        dc-*)                            echo dc ;;
        proxy-*|elastic-*|elastic_*)     echo core ;;
        mail-*)                          echo core ;;
        ws[0-9]*|ws-*|ws_*)             echo workstations ;;
        *-ws[0-9]*|*-ws_*)              echo workstations ;;
        soc-ws*|nato-ws*)               echo workstations ;;
        contractor-laptop*|kali-*|admin-ws*) echo workstations ;;
        *)                               echo services ;;
    esac
}

# --- sub-sort within a stage ------------------------------------------------
sort_stage() {
    local stage="$1"; shift; local hosts=("$@")
    case "$stage" in
        infra)
            local isps=() routers=() firewalls=()
            for h in "${hosts[@]}"; do
                case "${h%_"${TEAM}"}" in
                    r-isp*) isps+=("$h") ;; fw1-*) firewalls+=("$h") ;; *) routers+=("$h") ;;
                esac
            done
            printf '%s\n' "${isps[@]}" "${routers[@]}" "${firewalls[@]}" ;;
        dc)
            local primary=() secondary=()
            for h in "${hosts[@]}"; do
                case "${h%_"${TEAM}"}" in *_01) primary+=("$h") ;; *) secondary+=("$h") ;; esac
            done
            printf '%s\n' "${primary[@]}" "${secondary[@]}" ;;
        core)
            local proxies=() mail=()
            for h in "${hosts[@]}"; do
                case "${h%_"${TEAM}"}" in proxy-*|elastic-*) proxies+=("$h") ;; *) mail+=("$h") ;; esac
            done
            printf '%s\n' "${proxies[@]}" "${mail[@]}" ;;
        *)
            printf '%s\n' "${hosts[@]}" | sort ;;
    esac
}

# --- run ctp inside the container --------------------------------------------
ctp_exec() {
    docker exec -i -w "$WORKDIR" "$CONTAINER" zsh -c '
        _src() { [ -f "$1" ] && . "$1" >/dev/null 2>&1; }
        _src "$HOME/.local/bin/env"
        for _v in "$HOME"/*/.venv/bin/activate(N) "$HOME"/.venv/bin/activate(N); do _src "$_v" && break; done
        [ -f "$HOME/.vault/unlock-vault.sh" ] && export ANSIBLE_VAULT_PASSWORD_FILE="$HOME/.vault/unlock-vault.sh"
        _src "$HOME/autocomplete.zsh" || _src /home/builder/autocomplete.zsh
        ctp "$@"' _ "$@"
}

# --- inventory ---------------------------------------------------------------
get_hosts() {
    ctp_exec host list "*_${TEAM}" 2>/dev/null \
        | grep -oP '[a-zA-Z0-9_-]+_'"${TEAM}"'\b' \
        | sort -u
}

# --- vCenter VM existence check (bulk) ---------------------------------------
# Runs `ctp host ip` against all team hosts in one ansible run.
# Hosts where the VM exists show ok in PLAY RECAP; missing VMs show failed.
# This checks actual vCenter state — sees VMs deployed by ANY developer.
declare -A DEPLOYED_VMS

load_deployed_vms() {
    echo "-- Checking vCenter for deployed VMs..."
    local vm
    while IFS= read -r vm; do
        [[ -n "$vm" ]] && DEPLOYED_VMS["$vm"]=1
    done < <(
        ctp_exec host ip "*_${TEAM}" 2>&1 \
            | grep -E '^\S+_'"${TEAM}"'\s' \
            | grep -v 'unreachable=1' \
            | grep -v 'failed=1' \
            | awk '{print $1}'
    )
    echo "   ${#DEPLOYED_VMS[@]} already deployed"
}

is_deployed() { [[ -n "${DEPLOYED_VMS[$1]:-}" ]]; }

# --- deploy functions --------------------------------------------------------
deploy_sequential() {
    local stage="$1"; shift; local hosts=("$@")
    local ok=0 fail=0

    for h in "${hosts[@]}"; do
        printf "  >> %s..." "$h"
        if ctp_exec host deploy "$h" >/dev/null 2>&1; then
            printf " ok\n"
            ok=$((ok + 1))
        else
            printf " FAILED\n"
            fail=$((fail + 1))
            echo "     Retry later: ctp host deploy $h"
            echo "     Continuing with next host..."
        fi
    done
    printf "  -- %s: %d ok, %d failed\n" "$stage" "$ok" "$fail"
    [[ $fail -eq 0 ]]
}

deploy_twophase() {
    local stage="$1"; shift; local hosts=("$@")
    local host_pattern
    host_pattern=$(IFS=,; echo "${hosts[*]}")

    printf "  Phase 1: cloning %d VMs (deploy-until-configuration)...\n" "${#hosts[@]}"
    if ! ctp_exec host deploy-until-configuration "$host_pattern"; then
        echo "  !! Phase 1 had failures. Continuing to phase 2..."
    fi

    printf "  Phase 2: configuring %d VMs (deploy-from-configuration)...\n" "${#hosts[@]}"
    if ! ctp_exec host deploy-from-configuration "$host_pattern"; then
        echo "  !! Phase 2 had failures. Retry: ctp retry deploy-from-configuration"
        return 1
    fi
    printf "  -- %s done\n" "$stage"
}

deploy_stage() {
    local stage="$1"; shift; local all_hosts=("$@")

    # Filter already deployed
    local needed=() skipped=0
    for h in "${all_hosts[@]}"; do
        if is_deployed "$h"; then skipped=$((skipped + 1)); else needed+=("$h"); fi
    done

    local count=${#needed[@]}
    printf "\n=== %s === " "$stage"

    if [[ $count -eq 0 ]]; then
        printf "all %d deployed, nothing to do\n" "${#all_hosts[@]}"
        return 0
    fi
    if [[ $skipped -gt 0 ]]; then
        printf "%d deployed, %d pending\n" "$skipped" "$count"
    else
        printf "%d hosts\n" "$count"
    fi
    for h in "${needed[@]}"; do printf "    %s\n" "$h"; done

    case "$stage" in
        infra|dc|core)
            deploy_sequential "$stage" "${needed[@]}" ;;
        services|workstations)
            if [[ $count -le 5 ]]; then
                deploy_sequential "$stage" "${needed[@]}"
            else
                deploy_twophase "$stage" "${needed[@]}"
            fi ;;
    esac
}

# === main ====================================================================

# Preflight
if ! docker inspect -f '{{.State.Running}}' "$CONTAINER" >/dev/null 2>&1; then
    echo "!! container '$CONTAINER' not running — run 'make start' first" >&2
    exit 2
fi

echo "=== ctp-deploy-range: $TEAM ==="

# Fetch inventory
echo "-- Fetching ${TEAM} hosts..."
mapfile -t ALL_HOSTS < <(get_hosts)
if [[ ${#ALL_HOSTS[@]} -eq 0 ]]; then
    echo "!! no hosts found for team $TEAM" >&2
    exit 3
fi
echo "   ${#ALL_HOSTS[@]} hosts in inventory"

# Check vCenter
load_deployed_vms

# Bucket into stages
declare -A STAGE_HOSTS
for host in "${ALL_HOSTS[@]}"; do
    s=$(classify "$host")
    STAGE_HOSTS[$s]="${STAGE_HOSTS[$s]:-}${STAGE_HOSTS[$s]:+ }$host"
done

# --- status ------------------------------------------------------------------
if [[ "$ACTION" == "status" ]]; then
    echo ""
    echo "  Deploy chain:"
    echo ""

    printf "  "
    for i in "${!STAGE_ORDER[@]}"; do
        s="${STAGE_ORDER[$i]}"
        printf " %-13s" "$s"
        [[ $i -lt $(( ${#STAGE_ORDER[@]} - 1 )) ]] && printf " >"
    done
    echo ""

    printf "  "
    for i in "${!STAGE_ORDER[@]}"; do
        s="${STAGE_ORDER[$i]}"
        total=0; up=0; pending=0
        for h in ${STAGE_HOSTS[$s]:-}; do
            total=$((total + 1))
            if is_deployed "$h"; then up=$((up + 1)); else pending=$((pending + 1)); fi
        done
        if [[ $pending -eq 0 && $total -gt 0 ]]; then
            printf " %3d done     " "$total"
        elif [[ $up -eq 0 ]]; then
            printf " %3d pending  " "$total"
        else
            printf " %d/%d pending" "$pending" "$total"
        fi
        [[ $i -lt $(( ${#STAGE_ORDER[@]} - 1 )) ]] && printf " "
    done
    echo ""
    echo ""

    for s in "${STAGE_ORDER[@]}"; do
        read -ra hosts <<< "${STAGE_HOSTS[$s]:-}"
        [[ ${#hosts[@]} -eq 0 ]] && continue
        local_up=0; local_pending=0
        for h in "${hosts[@]}"; do
            if is_deployed "$h"; then local_up=$((local_up + 1)); else local_pending=$((local_pending + 1)); fi
        done
        printf "  [%s] %s  (%d deployed, %d pending)\n" "$s" "${STAGE_DESC[$s]}" "$local_up" "$local_pending"
        for h in "${hosts[@]}"; do
            if is_deployed "$h"; then
                printf "    + %s\n" "$h"
            else
                printf "    - %s\n" "$h"
            fi
        done
        echo ""
    done

    echo "  Deploy all pending:  ctp-deploy-range $TEAM deploy"
    echo "  Deploy one stage:    ctp-deploy-range $TEAM <stage>"
    echo "  Stages: ${STAGE_ORDER[*]}"
    exit 0
fi

# --- resolve what to deploy --------------------------------------------------
STAGES_TO_RUN=()
if [[ "$ACTION" == "deploy" || "$ACTION" == "all" ]]; then
    STAGES_TO_RUN=("${STAGE_ORDER[@]}")
else
    found=0
    for s in "${STAGE_ORDER[@]}"; do [[ "$s" == "$ACTION" ]] && found=1; done
    if [[ $found -eq 0 ]]; then
        echo "!! unknown: $ACTION" >&2
        echo "   use: deploy, status, or a stage name (${STAGE_ORDER[*]})" >&2
        exit 1
    fi
    STAGES_TO_RUN=("$ACTION")
fi

# Race check: block if ansible is already running in this container
if docker exec "$CONTAINER" pgrep -f 'ansible-playbook|ctp ' >/dev/null 2>&1; then
    echo "!! a deploy is already running in '$CONTAINER' — wait for it to finish" >&2
    exit 4
fi

# Count pending
total_pending=0
for s in "${STAGES_TO_RUN[@]}"; do
    read -ra _pending_hosts <<< "${STAGE_HOSTS[$s]:-}"
    for h in "${_pending_hosts[@]}"; do
        is_deployed "$h" || total_pending=$((total_pending + 1))
    done
done

if [[ $total_pending -eq 0 ]]; then
    echo ""
    echo "Nothing to deploy — all hosts are up."
    exit 0
fi

echo ""
echo "-- Deploying $total_pending pending hosts across ${#STAGES_TO_RUN[@]} stages..."
echo ""

for s in "${STAGES_TO_RUN[@]}"; do
    read -ra stage_hosts <<< "${STAGE_HOSTS[$s]:-}"
    [[ ${#stage_hosts[@]} -eq 0 ]] && continue
    mapfile -t sorted_hosts < <(sort_stage "$s" "${stage_hosts[@]}")
    deploy_stage "$s" "${sorted_hosts[@]}" || true
done

echo ""
echo "=== Done ==="
