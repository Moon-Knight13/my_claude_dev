#!/usr/bin/env bash
# hw.sh — host hardware detection for the SP1a hardware check (story 1.6;
# FR-19..22). Sourced by scripts/hub/hw-check.sh and scripts/setup-day0.sh.
#
# Every probe reads from a root held in a global, so tests point the probes at
# fixture trees and PATH stubs instead of real hardware:
#   HW_SYSFS       sysfs root            (/sys)
#   HW_PROC        procfs root           (/proc)
#   HW_DEV         device root           (/dev)
#   HW_VULKANINFO  vulkaninfo command    (vulkaninfo)
#   HW_GETCONF     getconf command       (getconf)
# These are test seams set by sourcing code, not settings: the hub tool never
# reads them from the environment (architecture conventions).
#
# Each hw_detect_* function sets its HW_* result globals and never exits. A
# value that cannot be read is left empty with the reason in a *_ERR global, so
# the caller can mark that line "  !!  " and refuse to pass on it.
#
# Function prefix: hw_ (architecture conventions, shared code).
#
# Results are returned through HW_* globals, read by the sourcing script.
# shellcheck disable=SC2034

HW_SYSFS=/sys
HW_PROC=/proc
HW_DEV=/dev
HW_VULKANINFO="vulkaninfo"
HW_GETCONF="getconf"
HW_MAX_READ=262144      # bytes read from any probe output or sysfs file
HW_PROBE_TIMEOUT=30     # seconds a probe command may run

# hw_in_container — true when running inside a container. The hardware check
# must see the host's GPU and memory, so a container is a fault, not a result.
hw_in_container() {
    [[ -f /.dockerenv || -f /run/.containerenv ]] && return 0
    [[ -n "${DEVCONTAINER:-}${REMOTE_CONTAINERS:-}${CODESPACES:-}${container:-}" ]] && return 0
    grep -qE 'docker|containerd|kubepods|lxc|libpod' /proc/1/cgroup 2>/dev/null && return 0
    return 1
}

# hw_read <file> — print the first line of a small file, bounded. Returns 1 when
# the file is missing or unreadable.
hw_read() {
    [[ -f "$1" && -r "$1" ]] || return 1
    head -c 4096 "$1" 2>/dev/null | head -n 1 | tr -d '\r'
}

# hw_clean <text> — strip control characters and cap the length, so a probe's
# output can be printed safely.
hw_clean() {
    printf '%s' "$1" | tr -d '\000-\037\177' | cut -c1-96
}

# hw_gb <bytes> — decimal gigabytes with one decimal place.
hw_gb() {
    awk -v b="$1" 'BEGIN { printf "%.1f", b / 1000000000 }'
}

# hw_version_ge <have> <want> — true when dotted version have >= want.
hw_version_ge() {
    awk -v a="$1" -v b="$2" 'BEGIN {
        na = split(a, x, "."); nb = split(b, y, ".")
        n = (na > nb) ? na : nb
        for (i = 1; i <= n; i++) {
            p = (i <= na) ? x[i] + 0 : 0; q = (i <= nb) ? y[i] + 0 : 0
            if (p > q) exit 0
            if (p < q) exit 1
        }
        exit 0
    }'
}

# --- GPU and driver (sysfs) --------------------------------------------------

# hw_detect_gpu — finds the DRM card to check, preferring an AMD one.
# Sets HW_GPU_CARD (sysfs path or empty), HW_GPU_ID ("vvvv:dddd"),
# HW_GPU_VENDOR ("0x1002"), HW_GPU_DRIVER (kernel driver name or empty),
# HW_GPU_RENDER (render node name or empty), HW_GPU_ERR (why unknown).
hw_detect_gpu() {
    local drm="$HW_SYSFS/class/drm" d v pick="" first=""
    HW_GPU_CARD=""; HW_GPU_ID=""; HW_GPU_VENDOR=""; HW_GPU_DRIVER=""
    HW_GPU_RENDER=""; HW_GPU_ERR=""
    if [[ ! -d "$drm" || ! -r "$drm" || ! -x "$drm" ]]; then
        HW_GPU_ERR="cannot read $drm"
        return 0
    fi
    for d in "$drm"/card*; do
        [[ "${d##*/}" =~ ^card[0-9]+$ && -d "$d/device" ]] || continue
        [[ -n "$first" ]] || first="$d"
        v="$(hw_read "$d/device/vendor" || true)"
        if [[ "$v" == 0x1002 ]]; then pick="$d"; break; fi
    done
    [[ -n "$pick" ]] || pick="$first"
    [[ -n "$pick" ]] || return 0              # no GPU: card stays empty
    HW_GPU_CARD="$pick"
    HW_GPU_VENDOR="$(hw_read "$pick/device/vendor" || true)"
    v="$(hw_read "$pick/device/device" || true)"
    HW_GPU_ID="${HW_GPU_VENDOR#0x}:${v#0x}"
    if [[ -L "$pick/device/driver" ]]; then
        HW_GPU_DRIVER="$(readlink "$pick/device/driver")"
        HW_GPU_DRIVER="$(hw_clean "${HW_GPU_DRIVER##*/}")"
    fi
    for d in "$pick"/device/drm/renderD*; do
        [[ -e "$d" ]] || continue
        HW_GPU_RENDER="${d##*/}"
        break
    done
}

# hw_detect_driver — driver readiness for Vulkan compute on the picked card.
# Needs hw_detect_gpu first. Sets HW_DRV_STATE (ok|fail|unknown), HW_DRV_TEXT.
hw_detect_driver() {
    local node
    if [[ -n "$HW_GPU_ERR" ]]; then
        HW_DRV_STATE=unknown; HW_DRV_TEXT="$HW_GPU_ERR"; return 0
    fi
    if [[ -z "$HW_GPU_CARD" ]]; then
        HW_DRV_STATE=fail; HW_DRV_TEXT="no GPU found"; return 0
    fi
    if [[ -z "$HW_GPU_DRIVER" ]]; then
        HW_DRV_STATE=fail; HW_DRV_TEXT="no kernel driver bound to the GPU"; return 0
    fi
    if [[ "$HW_GPU_DRIVER" != amdgpu ]]; then
        HW_DRV_STATE=fail; HW_DRV_TEXT="kernel driver is $HW_GPU_DRIVER, RADV needs amdgpu"; return 0
    fi
    if [[ -z "$HW_GPU_RENDER" ]]; then
        HW_DRV_STATE=fail; HW_DRV_TEXT="amdgpu bound but the GPU has no render node"; return 0
    fi
    node="$HW_DEV/dri/$HW_GPU_RENDER"
    if [[ ! -e "$node" ]]; then
        HW_DRV_STATE=fail; HW_DRV_TEXT="render node $HW_GPU_RENDER missing from the device directory"
    elif [[ ! -r "$node" || ! -w "$node" ]]; then
        HW_DRV_STATE=fail; HW_DRV_TEXT="render node $HW_GPU_RENDER not usable by this user (add the user to the render group)"
    else
        HW_DRV_STATE=ok; HW_DRV_TEXT="amdgpu bound, render node $HW_GPU_RENDER usable"
    fi
}

# --- Vulkan / RADV / Mesa (vulkaninfo) ----------------------------------------

# hw_detect_vulkan — runs `vulkaninfo --summary` and looks for a RADV device.
# Sets HW_VK_STATE (ok|fail|unknown), HW_VK_TEXT, HW_VK_NAME (RADV device name),
# HW_MESA_VERSION (from the RADV device's driverInfo, or empty), HW_MESA_ERR.
hw_detect_vulkan() {
    local out rc=0 parsed name info others
    HW_VK_STATE=unknown; HW_VK_TEXT=""; HW_VK_NAME=""; HW_MESA_VERSION=""; HW_MESA_ERR=""
    if ! command -v "$HW_VULKANINFO" >/dev/null 2>&1; then
        HW_VK_TEXT="vulkaninfo not installed (install vulkan-tools)"
        HW_MESA_ERR="unknown: vulkaninfo not installed"
        return 0
    fi
    out="$(timeout "$HW_PROBE_TIMEOUT" "$HW_VULKANINFO" --summary 2>/dev/null | head -c "$HW_MAX_READ")" \
        || rc=$?
    # One line per device: driverID<TAB>driverName<TAB>deviceName<TAB>driverInfo
    parsed="$(awk '
        function flush() { if (have) print id "\t" drv "\t" name "\t" info; have = 0; id = drv = name = info = "" }
        /^GPU[0-9]+:/ { flush(); have = 1; next }
        have && /=/ {
            k = $0; sub(/=.*/, "", k); gsub(/[[:space:]]/, "", k)
            v = $0; sub(/^[^=]*=[[:space:]]*/, "", v); sub(/[[:space:]]+$/, "", v)
            if (k == "driverID") id = v
            else if (k == "driverName") drv = v
            else if (k == "deviceName") name = v
            else if (k == "driverInfo") info = v
        }
        END { flush() }' <<<"$out")"
    if [[ -z "$parsed" ]]; then
        HW_VK_STATE=fail
        if (( rc != 0 )); then
            HW_VK_TEXT="vulkaninfo found no Vulkan device (exit $rc)"
        else
            HW_VK_TEXT="vulkaninfo listed no Vulkan device"
        fi
        HW_MESA_ERR="unknown: no RADV device to read the Mesa version from"
        return 0
    fi
    IFS=$'\t' read -r _ _ name info < <(awk -F'\t' '$1 == "DRIVER_ID_MESA_RADV" || $2 == "radv" { print; exit }' <<<"$parsed") || true
    if [[ -z "${name:-}" ]]; then
        others="$(cut -f3 <<<"$parsed" | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
        HW_VK_STATE=fail
        HW_VK_TEXT="Vulkan present but no RADV device (found: $(hw_clean "$others"))"
        HW_MESA_ERR="unknown: no RADV device to read the Mesa version from"
        return 0
    fi
    HW_VK_NAME="$(hw_clean "$name")"
    HW_VK_STATE=ok
    HW_VK_TEXT="RADV device available"
    if [[ "$info" =~ Mesa[[:space:]]+([0-9]+\.[0-9]+(\.[0-9]+)?) ]]; then
        HW_MESA_VERSION="${BASH_REMATCH[1]}"
    else
        HW_MESA_ERR="unknown: RADV driverInfo has no Mesa version"
    fi
}

# --- memory -------------------------------------------------------------------

# hw_detect_gtt — usable GPU memory: the GTT limit from ttm.pages_limit times
# the page size. Sets HW_GTT_BYTES (or empty) and HW_GTT_ERR.
hw_detect_gtt() {
    local f="$HW_SYSFS/module/ttm/parameters/pages_limit" pages psz
    HW_GTT_BYTES=""; HW_GTT_ERR=""
    if ! pages="$(hw_read "$f")"; then
        HW_GTT_ERR="ttm.pages_limit unreadable ($f)"; return 0
    fi
    if ! [[ "$pages" =~ ^[0-9]{1,15}$ ]] || (( pages == 0 )); then
        HW_GTT_ERR="ttm.pages_limit is not a positive page count"; return 0
    fi
    psz="$("$HW_GETCONF" PAGESIZE 2>/dev/null | head -c 32 || true)"
    if ! [[ "$psz" =~ ^[0-9]{1,9}$ ]] || (( psz == 0 )); then
        HW_GTT_ERR="page size unknown (getconf PAGESIZE failed)"; return 0
    fi
    HW_GTT_BYTES=$(( pages * psz ))
}

# hw_detect_sysmem — system memory from MemTotal. Sets HW_MEM_BYTES, HW_MEM_ERR.
hw_detect_sysmem() {
    local f="$HW_PROC/meminfo" kb
    HW_MEM_BYTES=""; HW_MEM_ERR=""
    if [[ ! -r "$f" ]]; then
        HW_MEM_ERR="cannot read $f"; return 0
    fi
    kb="$(head -c 8192 "$f" 2>/dev/null | awk '$1 == "MemTotal:" && $3 == "kB" { print $2; exit }')"
    if ! [[ "$kb" =~ ^[0-9]{1,15}$ ]] || (( kb == 0 )); then
        HW_MEM_ERR="no MemTotal in $f"; return 0
    fi
    HW_MEM_BYTES=$(( kb * 1024 ))
}

# hw_detect_all — run every probe.
hw_detect_all() {
    hw_detect_gpu
    hw_detect_driver
    hw_detect_vulkan
    hw_detect_gtt
    hw_detect_sysmem
}

# --- result hand-off ----------------------------------------------------------

# hw_result_file — where the check writes its result on the host, outside any
# repository and never mounted into a container. setup-day0.sh reads it.
hw_result_file() {
    printf '%s/lane2/hw-check.txt' "${XDG_STATE_HOME:-${HOME:-/nonexistent}/.local/state}"
}

# hw_next_steps — the setup next-steps block for the hardware check. Prints the
# host's saved result, or how to produce it. Prints nothing in a container: the
# check runs on the host only, and its result never reaches a container.
hw_next_steps() {
    local f
    hw_in_container && return 0
    f="$(hw_result_file)"
    echo "Hardware check (this host):"
    if [[ -f "$f" && ! -L "$f" && -r "$f" ]]; then
        head -c 8192 "$f" | tr -d '\000-\010\013-\037\177' | sed 's/^/  /'
    else
        echo "  not run yet on this host: bash scripts/hub/hw-check.sh"
    fi
}
