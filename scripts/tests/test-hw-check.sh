#!/usr/bin/env bash
# `cond && ok … || bad …` is safe in this file: ok and bad always return 0.
# shellcheck disable=SC2015
# test-hw-check.sh — host hardware check and model recommendation
# (SP1a story 1.6, #102; FR-19, FR-20, FR-21, FR-22, NFR-8).
# tier: ci — fixture hosts only: synthetic sysfs/procfs/dev trees built below,
# vulkaninfo and getconf as stubs. No real hardware is read.
#
# Pins: every fixture class (passing, above floor but below a model's need,
# below floor on memory, no Vulkan, old Mesa, unknown GTT, driver not ready);
# the missing-tool "  !!  " path; the container refusal; the exit codes; the
# table citation rule; and the setup next-steps hand-off.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HC="$ROOT/scripts/hub/hw-check.sh"
LIB="$ROOT/scripts/lib/hw.sh"
TABLE="$ROOT/scripts/hub/hw-floor.json"
PASS=0; FAIL=0
ok()   { echo "  OK  $1"; ((PASS++)) || true; }
bad()  { echo " FAIL $1"; ((FAIL++)) || true; }
check(){ if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (no '$3' in output)"; printf '%s\n' "$2" | sed 's/^/      | /' ;; esac; }
hasnt(){ case "$2" in *"$3"*) bad "$1 ('$3' in output)"; printf '%s\n' "$2" | sed 's/^/      | /' ;; *) ok "$1" ;; esac; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# --- fixture hosts ------------------------------------------------------------
# mkhost <name> [key=value ...] — build a synthetic host under $TMP/<name>.
# Keys (defaults give a passing host):
#   pages=16777216   ttm.pages_limit (x 4096-byte pages = 68.7 GB); "none" = absent
#   memkb=97000000   MemTotal in kB (99.3 GB)
#   vk=radv          radv | llvmpipe (no RADV) | fail (vulkaninfo errors) | missing
#   mesa=25.3.1      Mesa version in the RADV driverInfo
#   driver=amdgpu    kernel driver bound to the card; "none" = unbound
#   render=rw        rw | ro (not usable by this user) | none (no render node)
#   gpu=yes          yes | no (no DRM card at all)
# Everything is synthetic: no hostname, serial, account, or real device UUID.
mkhost() {
    local h="$TMP/$1"; shift
    local pages=16777216 memkb=97000000 vk=radv mesa=25.3.1 driver=amdgpu render=rw gpu=yes kv
    for kv in "$@"; do
        case "$kv" in
            pages=*) pages="${kv#*=}" ;; memkb=*) memkb="${kv#*=}" ;;
            vk=*) vk="${kv#*=}" ;; mesa=*) mesa="${kv#*=}" ;;
            driver=*) driver="${kv#*=}" ;; render=*) render="${kv#*=}" ;;
            gpu=*) gpu="${kv#*=}" ;;
        esac
    done
    rm -rf "$h"; mkdir -p "$h/sys/class/drm" "$h/sys/module/ttm/parameters" \
        "$h/proc" "$h/dev/dri" "$h/bin" "$h/sys/bus/pci/drivers/$driver" "$h/state"
    if [[ "$gpu" == yes ]]; then
        local dev="$h/sys/devices/pci0000:00/0000:00:01.0"
        mkdir -p "$dev"
        echo 0x1002 > "$dev/vendor"; echo 0x1900 > "$dev/device"
        [[ "$driver" != none ]] && ln -s "../../../bus/pci/drivers/$driver" "$dev/driver"
        mkdir -p "$h/sys/class/drm/card0"
        ln -s "../../../devices/pci0000:00/0000:00:01.0" "$h/sys/class/drm/card0/device"
        mkdir -p "$h/sys/class/drm/card0-eDP-1"     # a connector, not a card
        if [[ "$render" != none ]]; then
            mkdir -p "$dev/drm/renderD128"
            : > "$h/dev/dri/renderD128"
            if [[ "$render" == rw ]]; then chmod 600 "$h/dev/dri/renderD128"
            else chmod 400 "$h/dev/dri/renderD128"; fi
        fi
    fi
    [[ "$pages" != none ]] && echo "$pages" > "$h/sys/module/ttm/parameters/pages_limit"
    printf 'MemTotal:       %s kB\nMemFree:         1000000 kB\n' "$memkb" > "$h/proc/meminfo"
    printf '#!/bin/sh\necho 4096\n' > "$h/bin/getconf"; chmod +x "$h/bin/getconf"

    local radv llvm
    radv="GPU0:
	apiVersion         = 1.4.318
	driverVersion      = $mesa
	vendorID           = 0x1002
	deviceID           = 0x1900
	deviceType         = PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU
	deviceName         = AMD Radeon Graphics (RADV TEST)
	driverID           = DRIVER_ID_MESA_RADV
	driverName         = radv
	driverInfo         = Mesa $mesa-0test1
	conformanceVersion = 1.4.0.0
	deviceUUID         = 00000000-0000-0000-0000-zzdeviceuuid"
    llvm="GPU1:
	apiVersion         = 1.4.318
	deviceType         = PHYSICAL_DEVICE_TYPE_CPU
	deviceName         = llvmpipe (LLVM 20.1.2, 256 bits)
	driverID           = DRIVER_ID_MESA_LLVMPIPE
	driverName         = llvmpipe
	driverInfo         = Mesa $mesa-0test1 (LLVM 20.1.2)"
    case "$vk" in
        radv)     printf '==========\nVULKANINFO\n==========\n\nDevices:\n========\n%s\n%s\n' "$radv" "$llvm" > "$h/vk.txt" ;;
        llvmpipe) printf '==========\nVULKANINFO\n==========\n\nDevices:\n========\n%s\n' "${llvm/GPU1:/GPU0:}" > "$h/vk.txt" ;;
        fail)     : > "$h/vk.txt" ;;
    esac
    case "$vk" in
        radv|llvmpipe) printf '#!/bin/sh\ncat "%s"\n' "$h/vk.txt" > "$h/bin/vulkaninfo"; chmod +x "$h/bin/vulkaninfo" ;;
        fail) printf '#!/bin/sh\necho "ERROR_INITIALIZATION_FAILED" >&2\nexit 1\n' > "$h/bin/vulkaninfo"; chmod +x "$h/bin/vulkaninfo" ;;
    esac
}

# hwc <name> [args] — run the check as on that host. The suite runs in a dev
# container, so the container check is stubbed here and tested for real below.
hwc() {
    local h="$TMP/$1"; shift
    XDG_STATE_HOME="$h/state" bash -c '
        source "$1"; h="$2"; shift 2
        hw_in_container() { return 1; }
        HW_SYSFS="$h/sys"; HW_PROC="$h/proc"; HW_DEV="$h/dev"
        HW_VULKANINFO="$h/bin/vulkaninfo"; HW_GETCONF="$h/bin/getconf"
        hwcheck_main "$@"' _ "$HC" "$h" "$@"
}
run() { OUT="$(hwc "$@" 2>&1)"; RC=$?; }

# =============================================================================
echo "== passing host =="
mkhost pass
run pass
check "pass exits 0" "$RC" 0
has "reports the GPU model" "$OUT" "  OK  GPU: AMD Radeon Graphics (RADV TEST) [1002:1900]"
has "reports Vulkan/RADV" "$OUT" "  OK  Vulkan/RADV: RADV device available"
has "reports the Mesa version" "$OUT" "  OK  Mesa: 25.3.1 (floor >= 25.3)"
has "reports GTT from ttm.pages_limit" "$OUT" "  OK  usable GPU memory (GTT, ttm.pages_limit): 68.7 GB (floor >= 40 GB)"
has "reports system memory" "$OUT" "  OK  system memory: 99.3 GB (floor >= 48 GB)"
has "reports driver readiness" "$OUT" "  OK  driver readiness: amdgpu bound, render node renderD128 usable"
has "says pass" "$OUT" "  OK  result: pass"
has "names the memory class" "$OUT" "memory class: reference (>= 64 GB usable GPU memory)"
has "recommends an orchestrator" "$OUT" "  OK  orchestrator: Qwen3-30B-A3B Q5_K_M (needs 43.3 GB, provisional)"
has "recommends a classifier" "$OUT" "  OK  classifier: 4B-class (chosen by the bake-off) Q4_K_M (needs 40 GB, provisional)"
hasnt "no FAIL lines" "$OUT" " FAIL "
hasnt "no device UUID printed" "$OUT" "zzdeviceuuid"
has "flags the table as provisional" "$OUT" "  !!  the stated minimum and recommendation table are provisional"
has "cites each threshold's source" "$OUT" "  - usable GPU memory >= 40 GB: provisional, no bake-off record yet (PRD addendum A4"
check "one line per signal (6 marked lines before the table)" \
    "$(sed -n '/^== hardware check ==$/,/^$/p' <<<"$OUT" | grep -cE '^(  OK  | FAIL |  !!  )')" 6

echo "== above the floor, below a model's measured need =="
mkhost tight pages=10009766            # 41.0 GB GTT
run tight
check "tight host passes" "$RC" 0
has "class is minimum" "$OUT" "memory class: minimum (>= 40 GB usable GPU memory)"
has "gets the model it fits" "$OUT" "  OK  orchestrator: Qwen3-30B-A3B Q4_K_M (needs 40 GB"
has "is not recommended the larger one" "$OUT" "not recommended: orchestrator Qwen3-30B-A3B Q5_K_M needs 43.3 GB, this host has 41 GB"
hasnt "Q5_K_M never offered as a download" "$OUT" "  OK  orchestrator: Qwen3-30B-A3B Q5_K_M"

# below-floor helper: exit 3, a named reason, the floor-only consequence, no download
below() { # below <label> <expected reason text>
    check "$1: exits 3" "$RC" 3
    has "$1: says below floor" "$OUT" " FAIL result: below floor"
    has "$1: names the reason" "$OUT" "$2"
    has "$1: classifier cannot run" "$OUT" "The local classifier cannot run on this host"
    has "$1: floor-only sessions only" "$OUT" "available only as declared floor-only sessions"
    has "$1: no download recommended" "$OUT" "No model download is recommended for this host."
    hasnt "$1: recommends nothing" "$OUT" "recommended downloads"
    hasnt "$1: never says pass" "$OUT" "result: pass"
}

echo "== below floor on memory =="
mkhost lowmem pages=1953125 memkb=16000000   # 8.0 GB GTT, 16.4 GB RAM
run lowmem
below "low memory" "usable GPU memory 8.0 GB below 40 GB"
has "low memory: names every failing reason" "$OUT" "system memory 16.4 GB below 48 GB"
has "low memory: GTT line FAIL" "$OUT" " FAIL usable GPU memory (GTT, ttm.pages_limit): 8.0 GB, below floor 40 GB"

echo "== no Vulkan (llvmpipe only) =="
mkhost novk vk=llvmpipe
run novk
below "no Vulkan" "Vulkan/RADV not available: Vulkan present but no RADV device (found: llvmpipe"
has "no Vulkan: Mesa unknown, not guessed" "$OUT" "  !!  Mesa: unknown: no RADV device"

echo "== vulkaninfo errors =="
mkhost vkfail vk=fail
run vkfail
below "vulkaninfo error" "Vulkan/RADV not available: vulkaninfo found no Vulkan device (exit 1)"

echo "== old Mesa =="
mkhost oldmesa mesa=25.2.4
run oldmesa
below "old Mesa" "Mesa 25.2.4 below 25.3"
has "old Mesa: Mesa line FAIL" "$OUT" " FAIL Mesa: 25.2.4, below floor 25.3"
mkhost newmesa mesa=26.0.1
run newmesa
check "Mesa 26.0.1 passes the 25.3 floor" "$RC" 0

echo "== unknown GTT =="
mkhost nogtt pages=none
run nogtt
below "unknown GTT" "usable GPU memory unknown: ttm.pages_limit unreadable"
has "unknown GTT: line is !! with the reason" "$OUT" "  !!  usable GPU memory (GTT): unknown (ttm.pages_limit unreadable"
mkhost zerogtt pages=0
run zerogtt
below "zero GTT" "usable GPU memory unknown: ttm.pages_limit is not a positive page count"

echo "== missing tool (vulkaninfo) =="
mkhost notool vk=missing
run notool
below "missing vulkaninfo" "Vulkan/RADV unknown: vulkaninfo not installed"
has "missing tool: line is !! with the reason" "$OUT" "  !!  Vulkan/RADV: unknown (vulkaninfo not installed (install vulkan-tools))"
has "missing tool: GPU still reported from sysfs" "$OUT" "  OK  GPU: PCI device [1002:1900]"

echo "== unreadable sysfs =="
mkhost nosys
rm -rf "$TMP/nosys/sys/class/drm"
run nosys
below "unreadable sysfs" "GPU unknown: cannot read"
has "unreadable sysfs: driver line is !!" "$OUT" "  !!  driver readiness: unknown"

echo "== driver not ready =="
mkhost nodrv driver=none
run nodrv
below "unbound driver" "driver not ready: no kernel driver bound to the GPU"
mkhost otherdrv driver=radeon
run otherdrv
below "wrong driver" "driver not ready: kernel driver is radeon, RADV needs amdgpu"
mkhost norender render=none
run norender
below "no render node" "driver not ready: amdgpu bound but the GPU has no render node"
if [[ "$(id -u)" != 0 ]]; then
    mkhost rorender render=ro
    run rorender
    below "render node not usable" "render node renderD128 not usable by this user"
else
    ok "render node permission case skipped (running as root)"
fi
mkhost nogpu gpu=no
run nogpu
below "no GPU" "no GPU found"

# =============================================================================
echo "== container refusal =="
mkhost ctr
OUT="$(XDG_STATE_HOME="$TMP/ctr/state" DEVCONTAINER=true bash "$HC" 2>&1)"; RC=$?
(( RC >= 4 )) && ok "container: exits >= 4 (got $RC)" || bad "container: exit $RC"
has "container: says run on the host" "$OUT" " FAIL run on the host"
hasnt "container: reports no GPU value" "$OUT" "GPU:"
hasnt "container: reports no memory value" "$OUT" " GB"
hasnt "container: no result" "$OUT" "result:"
check "container: writes no result file" "$(find "$TMP/ctr/state" -type f | wc -l | tr -d ' ')" 0
# The real check: this suite itself runs in a dev container in CI and locally.
if bash -c 'source "$1"; hw_in_container' _ "$LIB"; then
    OUT="$(bash "$HC" 2>&1)"; RC=$?
    (( RC >= 4 )) && [[ "$OUT" == *" FAIL run on the host"* ]] \
        && ok "unstubbed check refuses in this container" || bad "unstubbed check ran (exit $RC)"
fi

# =============================================================================
echo "== usage and table faults =="
run pass --bogus
check "unknown flag exits 2" "$RC" 2
run pass --table
check "--table without a file exits 2" "$RC" 2
run pass --table "$TMP/none.json"
check "missing table exits 4" "$RC" 4
jq '.floor.gpu_mem_gb.basis = ""' "$TABLE" > "$TMP/uncited.json"
run pass --table "$TMP/uncited.json"
check "threshold with no record and no basis exits 4" "$RC" 4
has "names the table problem" "$OUT" "malformed or uncited"
jq '.floor.mesa.record = "sha256:abc"' "$TABLE" > "$TMP/badrec.json"
run pass --table "$TMP/badrec.json"
check "malformed record digest exits 4" "$RC" 4
jq 'del(.floor.sys_mem_gb)' "$TABLE" > "$TMP/nosys.json"
run pass --table "$TMP/nosys.json"
check "table missing a threshold exits 4" "$RC" 4
jq '.models |= map(select(.role != "classifier"))' "$TABLE" > "$TMP/norole.json"
run pass --table "$TMP/norole.json"
check "table with no classifier row exits 4" "$RC" 4
jq '.models |= map(if .role == "classifier" then .need_gpu_mem_gb = 99 else . end)' "$TABLE" > "$TMP/nofit.json"
run pass --table "$TMP/nofit.json"
check "table whose classifier cannot fit at the floor exits 4" "$RC" 4
DIG="sha256:$(printf 'synthetic-record' | sha256sum | cut -d' ' -f1)"
jq --arg d "$DIG" '(.floor[], .models[]) |= (.record = $d | .provisional = false)' "$TABLE" > "$TMP/cited.json"
run pass --table "$TMP/cited.json"
check "fully cited table passes" "$RC" 0
has "cites the bake-off record digest" "$OUT" "  - usable GPU memory >= 40 GB: bake-off record $DIG"
hasnt "cited table is not flagged provisional" "$OUT" "are provisional until the bake-off"
check "shipped table is valid" "$(bash -c 'source "$1"; hwcheck_validate_table "$2" && echo yes' _ "$HC" "$TABLE")" yes
check "shipped table is marked provisional" "$(jq -r .status "$TABLE")" provisional

# =============================================================================
echo "== next-steps hand-off =="
RES="$TMP/pass/state/lane2/hw-check.txt"
mkhost pass; run pass
[[ -f "$RES" ]] && ok "result written host-side" || bad "no result file at $RES"
check "result file is 0600" "$(stat -c %a "$RES" 2>/dev/null)" 600
check "result dir is 0700" "$(stat -c %a "${RES%/*}" 2>/dev/null)" 700
has "run prints where it saved" "$OUT" "result saved to $RES"
NS="$(XDG_STATE_HOME="$TMP/pass/state" bash -c 'source "$1"; hw_in_container() { return 1; }; hw_next_steps' _ "$LIB")"
has "next steps print the saved result" "$NS" "  OK  result: pass"
has "next steps print the recommendation" "$NS" "orchestrator: Qwen3-30B-A3B Q5_K_M"
mkhost lowmem pages=1953125 memkb=16000000; run lowmem
NS="$(XDG_STATE_HOME="$TMP/lowmem/state" bash -c 'source "$1"; hw_in_container() { return 1; }; hw_next_steps' _ "$LIB")"
has "next steps print a below-floor result" "$NS" "floor-only sessions"
NS="$(XDG_STATE_HOME="$TMP/never" bash -c 'source "$1"; hw_in_container() { return 1; }; hw_next_steps' _ "$LIB")"
has "next steps say how to run it when absent" "$NS" "not run yet on this host: bash scripts/hub/hw-check.sh"
NS="$(XDG_STATE_HOME="$TMP/pass/state" DEVCONTAINER=true bash -c 'source "$1"; hw_next_steps' _ "$LIB")"
check "next steps print nothing in a container" "$NS" ""
grep -qF 'lib/hw.sh"' "$ROOT/scripts/setup-day0.sh" \
    && grep -q 'hw_next_steps' "$ROOT/scripts/setup-day0.sh" \
    && ok "setup-day0.sh next steps call hw_next_steps" || bad "setup-day0.sh does not print the hardware result"
mkhost ro
: > "$TMP/ro/state/lane2"                 # a file where the result dir should be
run ro
check "unwritable result location exits 4" "$RC" 4
has "says the result was not saved" "$OUT" "result not saved"
mkhost link
mkdir -p "$TMP/elsewhere"
ln -s "$TMP/elsewhere" "$TMP/link/state/lane2"
run link
check "symlinked result dir is refused (exit 4)" "$RC" 4
check "nothing written through the symlink" "$(find "$TMP/elsewhere" -type f | wc -l | tr -d ' ')" 0
case "$RES" in "$ROOT"/*) bad "result path is inside the repository" ;; *) ok "result path is outside the repository" ;; esac
check "default result path is outside any checkout" \
    "$(HOME=/home/op XDG_STATE_HOME='' bash -c 'source "$1"; unset XDG_STATE_HOME; hw_result_file' _ "$LIB")" \
    /home/op/.local/state/lane2/hw-check.txt

# =============================================================================
echo "== public-repo hygiene =="
HN="$(hostname 2>/dev/null || true)"; ME="$(id -un 2>/dev/null || true)"
# The table and every generated fixture file (not the check's own reports).
FIXFILES=("$TABLE")
while IFS= read -r f; do FIXFILES+=("$f"); done < <(find "$TMP" -path '*/state' -prune -o -type f -print)
HITS_HN=""; HITS_ME=""
for f in "${FIXFILES[@]}"; do
    [[ -n "$HN" && ${#HN} -ge 4 ]] && grep -qiF -- "$HN" "$f" && HITS_HN+="$f "
    [[ -n "$ME" && ${#ME} -ge 4 ]] && grep -qwF -- "$ME" "$f" && HITS_ME+="$f "
done
check "no fixture or table file holds this hostname" "$HITS_HN" ""
check "no fixture or table file holds this account" "$HITS_ME" ""
hasnt "fixture hosts carry no serial number" "$(find "$TMP" -name '*serial*' 2>/dev/null)" "serial"
hasnt "table has no serial or UUID" "$(cat "$TABLE")" "serial"
TRACKED="$(git -C "$ROOT" ls-files)"
check "no hardware result tracked" "$(grep -E '(^|/)hw-check\.txt$' <<<"$TRACKED" || true)" ""

echo
echo "hw-check: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
