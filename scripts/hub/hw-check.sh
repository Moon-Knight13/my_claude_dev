#!/usr/bin/env bash
# hw-check.sh — host hardware check and model recommendation (SP1a story 1.6;
# FR-19, FR-20, FR-21, FR-22, FR-53, NFR-8).
#
# Reports what the host has (GPU, Vulkan/RADV, Mesa, usable GPU memory, system
# memory, driver readiness), compares it with the stated minimum, and on a pass
# recommends which orchestrator and classifier models to download. The stated
# minimum and the recommendation table live in one versioned file,
# scripts/hub/hw-floor.json. They are PROVISIONAL until the story 1.5 bake-off
# records exist (PRD OQ-4); the check says so on every run.
#
# Usage: hw-check.sh [--table FILE]
#   --table FILE   stated minimum and recommendation table (default: hw-floor.json
#                  next to this script)
#
# Runs on the host, where the GPU and memory are visible. Inside a container it
# refuses without reporting any value. Detection lives in scripts/lib/hw.sh.
#
# Result: written to $XDG_STATE_HOME/lane2/hw-check.txt (default
# ~/.local/state/lane2/hw-check.txt, mode 0600) for scripts/setup-day0.sh to
# print in its next steps. It is never written into a repository and never
# reaches a container.
#
# Exit: 0 pass, 2 usage, 3 below floor (including any value that could not be
# read: an unknown value never passes), >=4 fault (container, bad table, result
# not saved). Callers treat anything but 0 as "below floor".
set -euo pipefail

HWCHECK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/hw.sh disable=SC1091
source "$HWCHECK_DIR/../lib/hw.sh"

HWCHECK_REPORT=()
say()  { HWCHECK_REPORT+=("$1"); printf '%s\n' "$1"; }
die()  { printf ' FAIL %s\n' "$2" >&2; exit "$1"; }

# hwcheck_validate_table <file> — the table must be well formed and every
# threshold and model row must cite a bake-off record digest, or be explicitly
# provisional with a stated basis. Each role needs a row that fits at the floor.
hwcheck_validate_table() {
    jq -e '
      def cited: (.record | type == "string" and test("^sha256:[0-9a-f]{64}$"))
                 or (.record == null and .provisional == true
                     and (.basis | type == "string" and length > 0));
      def pos: type == "number" and . > 0;
      def str: type == "string" and length > 0;
      .version == 1
      and (.floor | type == "object")
      and ((.floor | keys) == ["gpu_mem_gb", "mesa", "sys_mem_gb", "vulkan_radv"])
      and (.floor.vulkan_radv.value == true)
      and (.floor.mesa.value | type == "string" and test("^[0-9]+(\\.[0-9]+){0,2}$"))
      and (.floor.gpu_mem_gb.value | pos)
      and (.floor.sys_mem_gb.value | pos)
      and ([.floor[] | cited] | all)
      and (.classes | type == "array" and length > 0)
      and ([.classes[] | (.name | str) and (.min_gpu_mem_gb | pos)] | all)
      and (.models | type == "array" and length > 0)
      and ([.models[] | (.role | IN("orchestrator", "classifier")) and (.model | str)
                        and (.quant | str) and (.need_gpu_mem_gb | pos) and cited] | all)
      and (.floor.gpu_mem_gb.value as $f | .models as $m
           | ["orchestrator", "classifier"]
           | all(. as $r | [$m[] | select(.role == $r) | .need_gpu_mem_gb]
                 | length > 0 and min <= $f))
    ' "$1" >/dev/null 2>&1
}

# hwcheck_ge <a> <b> — numeric a >= b (decimals allowed).
hwcheck_ge() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 >= b + 0) }'; }

# hwcheck_save — write the report for setup next-steps, owner-only.
hwcheck_save() {
    local f dir tmp
    f="$(hw_result_file)"; dir="${f%/*}"
    [[ -L "$f" || -L "$dir" ]] && return 1
    ( umask 077; mkdir -p "$dir" ) 2>/dev/null || return 1
    chmod 700 "$dir" 2>/dev/null || return 1
    tmp="$(umask 077; mktemp "$dir/.hw-check.XXXXXX" 2>/dev/null)" || return 1
    if ! { printf 'checked %s by scripts/hub/hw-check.sh\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
           printf '%s\n' "${HWCHECK_REPORT[@]}"; } > "$tmp" 2>/dev/null \
        || ! chmod 600 "$tmp" || ! mv -f "$tmp" "$f"; then
        rm -f "$tmp"
        return 1
    fi
}

hwcheck_main() {
    local table="$HWCHECK_DIR/hw-floor.json" reasons=() T
    local f_gpu f_sys f_mesa gtt_gb mem_gb name rc line r
    while (( $# )); do
        case "$1" in
            --table) table="${2:-}"; shift 2 || die 2 "usage: hw-check.sh [--table FILE]"
                     [[ -n "$table" ]] || die 2 "usage: hw-check.sh [--table FILE]" ;;
            -h|--help) sed -n '2,27p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; return 0 ;;
            *) die 2 "usage: hw-check.sh [--table FILE]" ;;
        esac
    done

    if hw_in_container; then
        printf ' FAIL run on the host: the hardware check must see the host GPU and memory\n'
        exit 4
    fi
    command -v jq >/dev/null || die 4 "jq not installed"
    [[ -f "$table" && -r "$table" ]] || die 4 "stated minimum table unreadable: $table"
    hwcheck_validate_table "$table" || die 4 "stated minimum table malformed or uncited: $table"
    T="$(head -c 65536 "$table")"
    f_gpu="$(jq -r '.floor.gpu_mem_gb.value' <<<"$T")"
    f_sys="$(jq -r '.floor.sys_mem_gb.value' <<<"$T")"
    f_mesa="$(jq -r '.floor.mesa.value' <<<"$T")"

    hw_detect_all

    say "== hardware check =="
    # GPU model
    if [[ -n "$HW_GPU_ERR" ]]; then
        say "  !!  GPU: unknown ($HW_GPU_ERR)"; reasons+=("GPU unknown: $HW_GPU_ERR")
    elif [[ -z "$HW_GPU_CARD" ]]; then
        say " FAIL GPU: none found"; reasons+=("no GPU found")
    else
        name="${HW_VK_NAME:-PCI device}"
        say "  OK  GPU: $name [$HW_GPU_ID]"
    fi
    # Vulkan / RADV
    case "$HW_VK_STATE" in
        ok)   say "  OK  Vulkan/RADV: $HW_VK_TEXT" ;;
        fail) say " FAIL Vulkan/RADV: $HW_VK_TEXT"; reasons+=("Vulkan/RADV not available: $HW_VK_TEXT") ;;
        *)    say "  !!  Vulkan/RADV: unknown ($HW_VK_TEXT)"; reasons+=("Vulkan/RADV unknown: $HW_VK_TEXT") ;;
    esac
    # Mesa
    if [[ -z "$HW_MESA_VERSION" ]]; then
        say "  !!  Mesa: ${HW_MESA_ERR:-unknown}"; reasons+=("Mesa version ${HW_MESA_ERR:-unknown}")
    elif hw_version_ge "$HW_MESA_VERSION" "$f_mesa"; then
        say "  OK  Mesa: $HW_MESA_VERSION (floor >= $f_mesa)"
    else
        say " FAIL Mesa: $HW_MESA_VERSION, below floor $f_mesa"; reasons+=("Mesa $HW_MESA_VERSION below $f_mesa")
    fi
    # Usable GPU memory (GTT)
    gtt_gb=""
    if [[ -z "$HW_GTT_BYTES" ]]; then
        # shellcheck disable=SC2153 # set by hw_detect_gtt in scripts/lib/hw.sh
        say "  !!  usable GPU memory (GTT): unknown ($HW_GTT_ERR)"; reasons+=("usable GPU memory unknown: $HW_GTT_ERR")
    else
        gtt_gb="$(hw_gb "$HW_GTT_BYTES")"
        if hwcheck_ge "$gtt_gb" "$f_gpu"; then
            say "  OK  usable GPU memory (GTT, ttm.pages_limit): $gtt_gb GB (floor >= $f_gpu GB)"
        else
            say " FAIL usable GPU memory (GTT, ttm.pages_limit): $gtt_gb GB, below floor $f_gpu GB"
            reasons+=("usable GPU memory $gtt_gb GB below $f_gpu GB")
        fi
    fi
    # System memory
    if [[ -z "$HW_MEM_BYTES" ]]; then
        say "  !!  system memory: unknown ($HW_MEM_ERR)"; reasons+=("system memory unknown: $HW_MEM_ERR")
    else
        mem_gb="$(hw_gb "$HW_MEM_BYTES")"
        if hwcheck_ge "$mem_gb" "$f_sys"; then
            say "  OK  system memory: $mem_gb GB (floor >= $f_sys GB)"
        else
            say " FAIL system memory: $mem_gb GB, below floor $f_sys GB"; reasons+=("system memory $mem_gb GB below $f_sys GB")
        fi
    fi
    # Driver readiness
    case "$HW_DRV_STATE" in
        ok)   say "  OK  driver readiness: $HW_DRV_TEXT" ;;
        fail) say " FAIL driver readiness: $HW_DRV_TEXT"; reasons+=("driver not ready: $HW_DRV_TEXT") ;;
        *)    say "  !!  driver readiness: unknown ($HW_DRV_TEXT)"; reasons+=("driver readiness unknown: $HW_DRV_TEXT") ;;
    esac

    # Where each threshold came from.
    say ""
    say "stated minimum (scripts/hub/hw-floor.json, version $(jq -r .version <<<"$T")):"
    while IFS= read -r line; do say "$line"; done < <(jq -r '
        .floor | to_entries[] | .key as $k | .value
        | "  - \({vulkan_radv: "Vulkan/RADV available", mesa: "Mesa >= \(.value)",
                  gpu_mem_gb: "usable GPU memory >= \(.value) GB",
                  sys_mem_gb: "system memory >= \(.value) GB"}[$k]): "
          + (if .record then "bake-off record \(.record)"
             else "provisional, no bake-off record yet (\(.basis))" end)' <<<"$T")
    if jq -e '[.floor[], .models[]] | any(.record == null)' <<<"$T" >/dev/null; then
        say "  !!  the stated minimum and recommendation table are provisional until the bake-off (PRD OQ-4)"
    fi

    say ""
    if (( ${#reasons[@]} > 0 )); then
        say " FAIL result: below floor"
        for r in "${reasons[@]}"; do say "      - $r"; done
        say "The local classifier cannot run on this host, so gated Lane 2 sessions are"
        say "available only as declared floor-only sessions (lane2 up --floor-only)."
        say "No model download is recommended for this host."
        rc=3
    else
        say "  OK  result: pass"
        say "memory class: $(jq -r --argjson g "$gtt_gb" \
            '[.classes[] | select(.min_gpu_mem_gb <= $g)] | max_by(.min_gpu_mem_gb)
             | "\(.name) (>= \(.min_gpu_mem_gb) GB usable GPU memory)"' <<<"$T")"
        say "recommended downloads:"
        while IFS= read -r line; do say "$line"; done < <(jq -r --argjson g "$gtt_gb" '
            . as $t
            | ("orchestrator", "classifier") as $r
            | [$t.models[] | select(.role == $r)] as $rows
            | ([$rows[] | select(.need_gpu_mem_gb <= $g)] | max_by(.need_gpu_mem_gb)) as $pick
            | "  OK  \($r): \($pick.model) \($pick.quant) (needs \($pick.need_gpu_mem_gb) GB"
              + (if $pick.record == null then ", provisional)" else ")" end),
              ($rows[] | select(.need_gpu_mem_gb > $g)
               | "      not recommended: \($r) \(.model) \(.quant) needs \(.need_gpu_mem_gb) GB, this host has \($g) GB")
            ' <<<"$T")
        rc=0
    fi

    if hwcheck_save; then
        printf 'result saved to %s (shown in setup next steps)\n' "$(hw_result_file)"
    else
        printf '  !!  result not saved to %s\n' "$(hw_result_file)" >&2
        exit 4
    fi
    return "$rc"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    hwcheck_main "$@"
fi
