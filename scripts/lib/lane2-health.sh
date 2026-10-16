#!/usr/bin/env bash
# lane2-health.sh — `lane2 health`, health check v1 (SP1a story 2.6; FR-23,
# AD-3, AD-9, AD-19, AD-22). Sourced by scripts/hub/lane2, which provides ok,
# fail, the parsed hub config, CONFDIR, STATE, PREFIX, policy_version_now, and
# gate_client.
#
# One line per part, each `  OK  `, ` FAIL `, or `  !!  `:
#   gate          the hub socket answers the `health` op: the operator's
#                 sensitive probe blocks through the classifier, the negative
#                 probe allows, and neither hits the floor
#   classifier    fleet member /health answers, and it listens on loopback only
#   orchestrator  the same
#   policy        policy checkout present; its policy_version is computed and
#                 current (equal to one recomputed from today's inputs)
#   removals      term-list entries removed since the previous snapshot, as a
#                 count, until acknowledged with --ack-removals (`  !!  `)
#   notifier      lane2-notify.service active
#   install       installed-code digest matches the install record
#   selection     a selection record for the installed classifier model,
#                 prompt, runtime build, and GPU driver
#   swap          swap off, encrypted (dm-crypt), or memory-only (zram)
# Any ` FAIL ` names its part, writes a health_failure event (part names only)
# to <state>/events/health.jsonl, and the command exits 3. Nothing printed or
# logged names a term, a probe, or a prompt line.
#
# API (sourced lib; prefix lane2_health_):
#   lane2_health_run [--ack-removals]   prints the lines; rc 0 healthy, 3 not
#
# Test seams (set by sourcing code, never read from the environment):
#   LANE2_HEALTH_PROC, LANE2_HEALTH_SYS   procfs and sysfs roots for the swap line
#   HW_* (scripts/lib/hw.sh)              the GPU driver for the selection line

LANE2_HEALTH_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$LANE2_HEALTH_LIB/fleet.sh"
# shellcheck source=/dev/null
source "$LANE2_HEALTH_LIB/hw.sh"

LANE2_HEALTH_PROC=/proc
LANE2_HEALTH_SYS=/sys
LANE2_HEALTH_FAILED=()

lane2_health_ok()   { printf '  OK  %s\n' "$1"; }
lane2_health_warn() { printf '  !!  %s\n' "$1"; }
lane2_health_fail() { printf ' FAIL %s: %s\n' "$1" "$2"; LANE2_HEALTH_FAILED+=("$1"); }

# Lane2 event log, one file per writer (AD-4, AD-7). Metadata only.
lane2_health_event() { # lane2_health_event <jq-object-expression> [jq args...]
    local expr="$1"; shift
    ( umask 077
      jq -nc --arg time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$@" "{time: \$time} + ($expr)" \
          >> "$STATE/events/health.jsonl" ) 2>/dev/null || true
}

# --- gate --------------------------------------------------------------------

lane2_health_probe_text() {
    case "$1" in
        ok) printf 'ok' ;;
        hits-floor) printf 'probe hits floor' ;;
        missing) printf 'probe missing from the policy repository' ;;
        non-text) printf 'probe is not text' ;;
        classifier-fault) printf 'classifier fault' ;;
        oversize) printf 'probe over the classifier context' ;;
        wrong-verdict) printf 'classifier gave the wrong verdict' ;;
        *) printf 'unknown result' ;;
    esac
}

lane2_health_gate() {
    local sock dl rc=0 s n why
    sock="$(lane2_conf_file_get "$CONFDIR/gate.conf" GATE_HUB_SOCKET)"; sock="${sock:-/run/lane2/gate/hub.sock}"
    dl="$(lane2_conf_file_get "$CONFDIR/gate.conf" GATE_SHIM_TIMEOUT)"; dl="${dl:-28}"
    gate_client "$sock" "$dl" '{"v":1,"op":"health"}' < /dev/null || rc=$?
    if (( rc == 0 )); then
        lane2_health_ok "gate: hub socket answers the health op; sensitive probe blocked by the classifier, negative probe allowed"
        return 0
    fi
    if (( rc == 4 )) || [[ -z "$GATE_CLIENT_RESPONSE" ]] \
        || ! jq -e '.v == 1 and .verdict == "block"' <<<"$GATE_CLIENT_RESPONSE" >/dev/null 2>&1; then
        lane2_health_fail gate "no answer on the hub socket (gate down, socket missing, or local fault)"
        return 0
    fi
    s="$(jq -r '.detail.probes.sensitive // ""' <<<"$GATE_CLIENT_RESPONSE")"
    n="$(jq -r '.detail.probes.negative // ""' <<<"$GATE_CLIENT_RESPONSE")"
    why="$(jq -r '.detail.reason // "block"' <<<"$GATE_CLIENT_RESPONSE")"
    if [[ -n "$s" && -n "$n" ]]; then
        local part=gate
        [[ "$why" == fault:classifier ]] && part=classifier
        lane2_health_fail "$part" "health op: sensitive probe: $(lane2_health_probe_text "$s"); negative probe: $(lane2_health_probe_text "$n")"
    else
        case "$why" in
            fault:policy) lane2_health_fail policy "health op blocked: gate policy missing or policy_version not computable" ;;
            fault:classifier|fault:oversize) lane2_health_fail classifier "health op blocked: $why" ;;
            *) lane2_health_fail gate "health op blocked: $why" ;;
        esac
    fi
}

# --- fleet members -----------------------------------------------------------

# lane2_health_binds — rc 0 when every listener on the member's port is on
# loopback. A unix-socket member has no network bind.
lane2_health_binds() {
    local port addrs a
    [[ -n "$FLEET_EP_SOCK" ]] && return 0
    port="${FLEET_EP_BASE##*:}"
    command -v ss >/dev/null 2>&1 || return 2
    addrs="$(ss -Hltn 2>/dev/null | awk -v p=":$port" '{ a = $4; if (substr(a, length(a) - length(p) + 1) == p) print a }')"
    [[ -n "$addrs" ]] || return 3
    while IFS= read -r a; do
        [[ "$a" == 127.* || "$a" == "[::1]:"* ]] || return 1
    done <<<"$addrs"
    return 0
}

lane2_health_member() { # lane2_health_member <member>
    local m="$1" rc=0
    fleet_use_config "$CONFDIR/fleet.conf"
    if ! fleet_load_config || ! fleet_member_endpoint "$m"; then
        lane2_health_fail "$m" "endpoint missing or not loopback / hub socket in fleet.conf"
        return 0
    fi
    fleet_health "$m" || rc=$?
    if (( rc != 0 )); then
        lane2_health_fail "$m" "/health does not answer 200 (down, loading, or unreachable)"
        return 0
    fi
    rc=0; lane2_health_binds || rc=$?
    case "$rc" in
        0) lane2_health_ok "$m: /health answers; listens on loopback only" ;;
        1) lane2_health_fail "$m" "listens on a non-loopback address" ;;
        2) lane2_health_fail "$m" "cannot check its binds (ss missing)" ;;
        *) lane2_health_fail "$m" "no listener found on its port" ;;
    esac
}

# --- policy and removals -----------------------------------------------------

lane2_health_policy() {
    local st="$STATE/gate-policy/state.json" have now
    if [[ ! -r "$STATE/gate-policy/current/term-list.txt" || ! -r "$st" ]]; then
        lane2_health_fail policy "no policy checkout (run lane2 policy update)"
        return 0
    fi
    have="$(jq -r '.policy_version // ""' "$st" 2>/dev/null)" || have=""
    now="$(policy_version_now "$(lane2_tree_digest "$PREFIX/current" "${LANE2_GATE_CODE[@]}" 2>/dev/null)" 2>/dev/null)" || now=""
    if [[ -z "$have" ]]; then
        lane2_health_fail policy "policy_version not computed (${POLICY_MISSING:-an input is missing}); run lane2 policy update"
    elif [[ -z "$now" ]]; then
        lane2_health_fail policy "policy_version cannot be computed now: ${POLICY_MISSING:-an input is missing}"
    elif [[ "$have" != "$now" ]]; then
        lane2_health_fail policy "policy_version is stale (an input changed); run lane2 policy update"
    else
        lane2_health_ok "policy: checkout present, policy_version current (kept on the hub only)"
    fi
}

# Removed entries are counted by `lane2 policy update` (never listed). The count
# stays until the operator acknowledges the snapshot it belongs to.
lane2_health_removals_state() { # sets LANE2_HEALTH_COMMIT and LANE2_HEALTH_REMOVED
    local st="$STATE/gate-policy/state.json" ack="$STATE/events/health-ack.json" acked
    LANE2_HEALTH_COMMIT="$(jq -r '.commit // ""' "$st" 2>/dev/null)" || LANE2_HEALTH_COMMIT=""
    LANE2_HEALTH_REMOVED="$(jq -r '.removed_since_previous // 0' "$st" 2>/dev/null)" || LANE2_HEALTH_REMOVED=0
    [[ "$LANE2_HEALTH_REMOVED" =~ ^[0-9]+$ ]] || LANE2_HEALTH_REMOVED=0
    LANE2_HEALTH_REMOVED=$((10#$LANE2_HEALTH_REMOVED))
    acked="$(jq -r '.commit // ""' "$ack" 2>/dev/null)" || acked=""
    [[ -n "$LANE2_HEALTH_COMMIT" && "$acked" == "$LANE2_HEALTH_COMMIT" ]] && LANE2_HEALTH_REMOVED=0
    return 0
}

lane2_health_ack() {
    lane2_health_removals_state
    [[ -n "$LANE2_HEALTH_COMMIT" ]] || { lane2_health_fail removals "no policy snapshot to acknowledge"; return 0; }
    ( umask 077
      jq -nc --arg c "$LANE2_HEALTH_COMMIT" --arg time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
          --argjson n "$LANE2_HEALTH_REMOVED" '{commit: $c, acknowledged_at: $time, count: $n}' \
          > "$STATE/events/health-ack.json.tmp" \
      && mv -f "$STATE/events/health-ack.json.tmp" "$STATE/events/health-ack.json" ) \
        || { lane2_health_fail removals "cannot record the acknowledgement"; return 0; }
    # shellcheck disable=SC2016  # $n is a jq variable
    lane2_health_event '{event: "removals_acknowledged", count: $n}' --argjson n "$LANE2_HEALTH_REMOVED"
    lane2_health_ok "removals: $LANE2_HEALTH_REMOVED acknowledged (logged)"
}

lane2_health_removals() {
    lane2_health_removals_state
    if (( LANE2_HEALTH_REMOVED > 0 )); then
        lane2_health_warn "removals: $LANE2_HEALTH_REMOVED term-list entr(y/ies) removed since the previous snapshot; acknowledge with lane2 health --ack-removals"
    else
        lane2_health_ok "removals: none unacknowledged"
    fi
}

# --- notifier, install, selection, swap --------------------------------------

lane2_health_notifier() {
    if systemctl is-active --quiet lane2-notify.service 2>/dev/null \
        || systemctl --user is-active --quiet lane2-notify.service 2>/dev/null; then
        lane2_health_ok "notifier: lane2-notify.service active"
    else
        lane2_health_fail notifier "lane2-notify.service not active"
    fi
}

lane2_health_install() {
    local rec="$PREFIX/current/.lane2-install.json" want have root_rec="$STATE/install/manifest.json"
    if [[ ! -d "$PREFIX/current" || ! -r "$rec" ]]; then
        lane2_health_fail install "no installed tree or install record (run lane2 install)"
        return 0
    fi
    want="$(jq -r '.installed_code_digest // ""' "$rec" 2>/dev/null)" || want=""
    have="$(lane2_tree_digest "$PREFIX/current/")"
    if [[ -z "$want" || "$want" != "$have" ]]; then
        lane2_health_fail install "installed-code digest does not match the pin manifest record"
        return 0
    fi
    # The install store is root-only; when this runs as root it is checked too.
    if [[ -r "$root_rec" && "$(jq -r '.installed_code_digest // ""' "$root_rec" 2>/dev/null)" != "$have" ]]; then
        lane2_health_fail install "installed-code digest does not match the install store's record"
        return 0
    fi
    lane2_health_ok "install: installed-code digest matches the pin manifest record"
}

# The Lane 2 image (Story 3.1). Docker needs root and health runs as the
# operator, so this reads what the last `lane2 install` or `install --verify`
# (root) found: <state>/events/image-status.json.
lane2_health_image() {
    local f="$STATE/events/image-status.json" st img why
    if [[ ! -r "$f" ]] || ! st="$(jq -c . "$f" 2>/dev/null)"; then
        lane2_health_fail image "not checked yet (run sudo lane2 install --verify)"
        return 0
    fi
    img="$(jq -r '.image_id // ""' <<<"$st")"; why="$(jq -r '.reason // ""' <<<"$st")"
    if [[ "$(jq -r .ok <<<"$st")" == true && -n "$img" ]]; then
        lane2_health_ok "image: $img pinned, claude at or above the floor, userns-remap in effect (checked $(jq -r .checked_at <<<"$st"))"
    else
        lane2_health_fail image "${img:-Lane 2 image}: ${why:-check failed}"
    fi
}

# The selection record (Story 1.5 bake-off) is keyed to the classifier model
# checksum, the prompt checksum, the runtime build, and the GPU driver version:
# <state>/fleet/selection.json {model_sha256, prompt_sha256, runtime_build,
# driver_version}. Any of them changed: re-selection is required (AD-22).
lane2_health_selection() {
    local rec="$STATE/fleet/selection.json" fleet="$CONFDIR/fleet.conf" prompt k want have changed=()
    if [[ ! -r "$rec" ]] || ! jq -e 'type == "object"' "$rec" >/dev/null 2>&1; then
        lane2_health_fail selection "no selection record for the installed model, prompt, runtime, and driver (run the bake-off)"
        return 0
    fi
    prompt="$STATE/gate-policy/current/classifier-prompt.md"
    hw_driver_version
    for k in model_sha256 prompt_sha256 runtime_build driver_version; do
        want="$(jq -r --arg k "$k" '.[$k] // ""' "$rec")"
        case "$k" in
            model_sha256) have="$(lane2_conf_file_get "$fleet" FLEET_CLASSIFIER_SHA256 | tr 'A-F' 'a-f')" ;;
            prompt_sha256) have=""; [[ -r "$prompt" ]] && have="$(sha256sum < "$prompt" | cut -d' ' -f1)" ;;
            runtime_build) have="$(lane2_conf_file_get "$fleet" FLEET_RUNTIME_BUILD)" ;;
            driver_version) have="$HW_DRIVER_VERSION" ;;
        esac
        [[ -n "$have" && "$want" == "$have" ]] || changed+=("$k")
    done
    if (( ${#changed[@]} > 0 )); then
        lane2_health_fail selection "re-selection required: ${changed[*]} changed or unreadable"
    else
        lane2_health_ok "selection: record matches the installed model, prompt, runtime, and driver"
    fi
}

lane2_health_swap() {
    local swaps="$LANE2_HEALTH_PROC/swaps" name dev uuid n=0 plain=0
    if [[ ! -r "$swaps" ]]; then
        lane2_health_fail swap "cannot read the swap table"
        return 0
    fi
    while read -r name _; do
        [[ -n "$name" && "$name" != Filename ]] || continue
        n=$((n + 1))
        dev="${name##*/}"
        case "$name" in
            /dev/zram*) continue ;;
            /dev/dm-*|/dev/mapper/*)
                [[ "$name" == /dev/mapper/* && -L "$name" ]] && dev="$(basename "$(readlink -f "$name")")"
                uuid="$(head -c 256 "$LANE2_HEALTH_SYS/block/$dev/dm/uuid" 2>/dev/null)" || uuid=""
                [[ "$uuid" == CRYPT-* ]] && continue ;;
        esac
        plain=$((plain + 1))
    done < "$swaps"
    if (( n == 0 )); then
        lane2_health_ok "swap: off"
    elif (( plain == 0 )); then
        lane2_health_ok "swap: encrypted or memory-only ($n device(s))"
    else
        lane2_health_fail swap "$plain swap device(s) neither encrypted nor memory-only"
    fi
}

# --- the command -------------------------------------------------------------

lane2_health_run() {
    local ack=0
    case "${1:-}" in
        "") ;;
        --ack-removals) ack=1 ;;
        *) printf ' FAIL usage: lane2 health [--ack-removals]\n'; return 2 ;;
    esac
    LANE2_HEALTH_FAILED=()
    echo "== lane2 health =="
    (( ack )) && lane2_health_ack
    lane2_health_gate
    lane2_health_member classifier
    lane2_health_member orchestrator
    lane2_health_policy
    (( ack )) || lane2_health_removals
    lane2_health_notifier
    lane2_health_install
    lane2_health_image
    lane2_health_selection
    lane2_health_swap
    if (( ${#LANE2_HEALTH_FAILED[@]} > 0 )); then
        local parts
        parts="$(printf '%s\n' "${LANE2_HEALTH_FAILED[@]}" | jq -R . | jq -sc 'unique')"
        # shellcheck disable=SC2016  # $p is a jq variable
        lane2_health_event '{event: "health_failure", failed: $p}' --argjson p "$parts"
        printf ' FAIL health: %s failing; Lane 2 is not safe to start\n' "$(jq -r 'join(", ")' <<<"$parts")"
        return 3
    fi
    lane2_health_ok "health: every part passes"
}
