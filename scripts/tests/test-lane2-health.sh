#!/usr/bin/env bash
# `cond && ok … || bad …` is safe in this file: ok and bad always return 0.
# shellcheck disable=SC2015,SC2016,SC2153
# test-lane2-health.sh — `lane2 health` and the gate's `health` op (SP1a story
# 2.6, #109; FR-23, AD-3, AD-9, AD-19, AD-22).
# tier: ci — the real gate handler behind a real unix socket (gate-fixture.sh),
# the llama-server mock as both fleet members, PATH stubs for ss and systemctl,
# and synthetic hardware, swap, policy, and probes. No real hub, GPU, or term.
#
# Pins: each health line's pass and fail; probe hits floor (so the floor alone
# never passes); classifier down names the classifier; probes leave no cache,
# retained payload, or operator log line; removal count shown as a count only,
# acknowledged with --ack-removals (logged); a FAIL exits 3 and logs a
# health_failure event naming parts only.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LANE2="$ROOT/scripts/hub/lane2"
PASS=0; FAIL=0
ok()   { echo "  OK  $1"; ((PASS++)) || true; }
bad()  { echo " FAIL $1"; ((FAIL++)) || true; }
check(){ if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (no '$3' in output)"; printf '%s\n' "$2" | sed 's/^/      | /' ;; esac; }
hasnt(){ case "$2" in *"$3"*) bad "$1 ('$3' found)" ;; *) ok "$1" ;; esac; }

# shellcheck source=/dev/null
source "$ROOT/scripts/tests/gate-fixture.sh"
gf_setup
[[ -S "$SOCK" ]] || { echo " FAIL gate socket did not come up"; exit 1; }

# --- the rest of a synthetic hub ----------------------------------------------
POL="$STATE/gate-policy/trees/p1"
printf 'ZZSENSITIVE probe for the health check\n' > "$POL/health-probe-sensitive.txt"
printf 'a plain probe about formatting a list\n' > "$POL/health-probe-negative.txt"
mkdir -p "$STATE/events" "$STATE/fleet" "$STATE/gate-store" "$STATE/operator-log" "$TMP/stub"
HCONF=("GATE_HUB_SOCKET=$SOCK" "FLEET_ORCHESTRATOR_ENDPOINT=http://127.0.0.1:$PORT" "FLEET_ORCHESTRATOR_MODEL=orch-test")
hconf() { gf_conf "${HCONF[@]}" "$@"; }
hconf

# Stubs: ss lists listeners from a file; systemctl answers from a file.
printf '#!/bin/sh\ncat "%s"\n' "$TMP/stub/ss.out" > "$TMP/stub/ss"
printf '#!/bin/sh\n[ "$(cat "%s")" = active ]\n' "$TMP/stub/notify" > "$TMP/stub/systemctl"
chmod +x "$TMP/stub/ss" "$TMP/stub/systemctl"
listen() { printf 'LISTEN 0 4096 %s:%s 0.0.0.0:*\n' "${1:-127.0.0.1}" "$PORT" > "$TMP/stub/ss.out"; }
listen; echo active > "$TMP/stub/notify"

# Hardware (for the selection line): an amdgpu card with an in-tree driver.
HW="$TMP/hw"; dev="$HW/sys/devices/pci0000:00/0000:00:01.0"
mkdir -p "$dev/drm/renderD128" "$HW/sys/class/drm/card0" "$HW/sys/bus/pci/drivers/amdgpu" "$HW/proc/sys/kernel"
echo 0x1002 > "$dev/vendor"; echo 0x1900 > "$dev/device"
ln -s "../../../bus/pci/drivers/amdgpu" "$dev/driver"
ln -s "../../../devices/pci0000:00/0000:00:01.0" "$HW/sys/class/drm/card0/device"
echo "6.8.0-41-generic" > "$HW/proc/sys/kernel/osrelease"
printf 'Filename\tType\tSize\tUsed\tPriority\n' > "$HW/proc/swaps"

# Run lane2 as on the hub: the container check stubbed, probes pointed at the
# synthetic trees, the stubs first on PATH.
L() {
    bash -c 'source "$1"; h="$2"; stub="$3"; shift 3
        lane2_in_container() { return 1; }
        HW_SYSFS="$h/sys"; HW_PROC="$h/proc"; LANE2_HEALTH_PROC="$h/proc"; LANE2_HEALTH_SYS="$h/sys"
        PATH="$stub:$PATH"
        lane2_main "$@"' _ "$LANE2" "$HW" "$TMP/stub" --config-dir "$CONF" "$@"
}
run() { OUT="$(L health "$@" 2>&1)"; RC=$?; }

# The install record, policy state, and selection record, as lane2 install,
# lane2 policy update, and the bake-off would leave them.
GATE_DIGEST() { bash -c 'source "$1"; lane2_tree_digest "$2" "${LANE2_GATE_CODE[@]}"' _ "$ROOT/scripts/lib/lane2.sh" "$PREFIX/current"; }
install_record() {
    jq -nc --arg d "$(bash -c 'source "$1"; lane2_tree_digest "$2"' _ "$ROOT/scripts/lib/lane2.sh" "$PREFIX/c1")" \
        '{commit: "c1", installed_code_digest: $d}' > "$PREFIX/c1/.lane2-install.json"
}
PV="$(bash -c 'source "$1"; lane2_load_config "$2/lane2.conf"; CONFDIR="$2"; STATE="$3"; policy_version_now "$4"' \
    _ "$LANE2" "$CONF" "$STATE" "$(GATE_DIGEST)")"
[[ "$PV" =~ ^[0-9a-f]{64}$ ]] || { echo " FAIL fixture policy_version did not compute"; exit 1; }
pstate() { # pstate <commit> <removed> [policy_version]
    jq -nc --arg c "$1" --argjson r "$2" --arg pv "${3-$PV}" \
        '{commit: $c, policy_version: (if $pv == "" then null else $pv end), terms: 2, rejected_short: 0, removed_since_previous: $r}' \
        > "$STATE/gate-policy/state.json"
}
selection() { # selection [key=value to override]
    jq -nc --arg m "$GF_SHA" --arg p "$(sha256sum < "$POL/classifier-prompt.md" | cut -d' ' -f1)" \
        '{model_sha256: $m, prompt_sha256: $p, runtime_build: "b1234", driver_version: "in-tree 6.8.0-41-generic"}' \
        | jq -c "${1:-.}" > "$STATE/fleet/selection.json"
}
imgstat() { # imgstat [ok|fail] — what the last root image check (story 3.1) found
    jq -nc --arg ok "${1:-ok}" '{checked_at: "2026-10-16T00:00:00Z",
        image_id: ("sha256:" + ("1" * 64)), ok: ($ok == "ok"),
        reason: (if $ok == "ok" then "" else "userns-remap: userns-remap not in effect" end)}' \
        > "$STATE/events/image-status.json"
}
install_record; pstate p1 0; selection; imgstat
LINE() { grep -E "^( FAIL |  OK  |  !!  )$1" <<<"$OUT" | head -1; }

# =============================================================================
echo "== healthy hub: every line OK =="
run
check "healthy: exit 0" "$RC" 0
for p in "gate: hub socket answers the health op" "classifier: /health answers; listens on loopback only" \
         "orchestrator: /health answers" "policy: checkout present, policy_version current" \
         "removals: none unacknowledged" "notifier: lane2-notify.service active" \
         "install: installed-code digest matches" "image: sha256:" "selection: record matches" "swap: off" "health: every part passes"; do
    has "  OK  $p" "$OUT" "  OK  $p"
done
hasnt "no policy_version printed" "$OUT" "$PV"
[[ ! -s "$STATE/events/health.jsonl" ]] && ok "a healthy run logs no failure" || bad "healthy run logged: $(cat "$STATE/events/health.jsonl")"

echo "== the health op on the hub socket =="
hop() { RC=0; gate_client "$SOCK" 20 "$1" < <(printf '%s' "${2:-}") || RC=$?; RESP="$GATE_CLIENT_RESPONSE"; }
hop '{"v":1,"op":"health"}'
check "health op: allow" "$RC" 0
check "per-probe detail" "$(jq -c .detail.probes <<<"$RESP")" '{"sensitive":"ok","negative":"ok"}'
hop '{"v":1,"op":"health","layers":["floor"]}'
check "extra header field: block" "$(jq -r .detail.reason <<<"$RESP")" fault:protocol
hop '{"v":1,"op":"health"}' "some payload"
check "a payload on the health op: block" "$(jq -r .detail.reason <<<"$RESP")" fault:protocol

echo "== probes: no cache entry, retained payload, or operator log line =="
# Only the query log and per-peer counters (Story 2.5, metadata) are written.
GSX() { find "$STATE/gate-store" "$STATE/operator-log" -mindepth 1 -not -name query.jsonl -not -name '.counters.lock' \
          -not -path "$STATE/gate-store/counters" -not -path "$STATE/gate-store/counters/*" | wc -l | tr -d ' '; }
check "gate store: no cache entry, retained payload, or operator log line" "$(GSX)" 0
check "operator log untouched" "$(find "$STATE/operator-log" -mindepth 1 | wc -l | tr -d ' ')" 0

# =============================================================================
echo "== gate line: failures =="
gate_fail() { # gate_fail <label> <want text> [part]
    run
    check "$1: exit 3" "$RC" 3
    has "$1: FAIL names the part" "$OUT" " FAIL ${3:-gate}: "
    has "$1: says why" "$OUT" "$2"
}
cp "$POL/health-probe-sensitive.txt" "$TMP/probe.s"; cp "$POL/health-probe-negative.txt" "$TMP/probe.n"
printf 'ZZSENSITIVE probe mentioning zzalpha\n' > "$POL/health-probe-sensitive.txt"
gate_fail "sensitive probe hits the floor" "sensitive probe: probe hits floor"
hasnt "never names the term" "$(tr '[:upper:]' '[:lower:]' <<<"$OUT")" zzalpha
cp "$TMP/probe.s" "$POL/health-probe-sensitive.txt"
printf 'plain words and zzbravo\n' > "$POL/health-probe-negative.txt"
gate_fail "negative probe hits the floor" "negative probe: probe hits floor"
cp "$TMP/probe.n" "$POL/health-probe-negative.txt"
printf 'a sensitive probe the classifier misses\n' > "$POL/health-probe-sensitive.txt"
gate_fail "sensitive probe allowed" "sensitive probe: classifier gave the wrong verdict" classifier
cp "$TMP/probe.s" "$POL/health-probe-sensitive.txt"
printf 'ZZSENSITIVE in the negative probe\n' > "$POL/health-probe-negative.txt"
gate_fail "negative probe blocked" "negative probe: classifier gave the wrong verdict" classifier
cp "$TMP/probe.n" "$POL/health-probe-negative.txt"
rm "$POL/health-probe-negative.txt"
gate_fail "probe missing" "negative probe: probe missing from the policy repository"
cp "$TMP/probe.n" "$POL/health-probe-negative.txt"

gf_mode health500
gate_fail "classifier down" "sensitive probe: classifier fault" classifier
has "classifier member line fails too" "$OUT" " FAIL classifier: /health does not answer 200"
gf_mode ok
gf_mode malformed
gate_fail "classifier malformed answer" "classifier fault" classifier
gf_mode ok
check "no cache, retained payload, or log after failing probes" "$(GSX)" 0

hconf "GATE_HUB_SOCKET=$TMP/no-such.sock"
gate_fail "socket missing: callers block" "no answer on the hub socket"
hconf
mv "$STATE/gate-policy/current" "$STATE/gate-policy/current.off"
run
check "policy missing: exit 3" "$RC" 3
has "policy missing: the health op names the policy" "$OUT" " FAIL policy: health op blocked"
has "policy line fails too" "$OUT" " FAIL policy: no policy checkout"
mv "$STATE/gate-policy/current.off" "$STATE/gate-policy/current"

echo "== failure event: part names only =="
EV="$STATE/events/health.jsonl"
jq -se 'map(select(.event == "health_failure") | .failed[]) | index("gate") != null' "$EV" >/dev/null 2>&1 \
    && ok "health_failure event names the gate" || bad "no health_failure event naming the gate"
check "event keys: time, event, failed" "$(jq -sc 'map(keys) | unique' "$EV")" '[["event","failed","time"]]'
hasnt "event log has no term" "$(tr '[:upper:]' '[:lower:]' < "$EV")" zzalpha
hasnt "event log has no probe text" "$(cat "$EV")" "ZZSENSITIVE"
hasnt "event log has no policy_version" "$(cat "$EV")" "$PV"

# =============================================================================
echo "== fleet members =="
hconf "FLEET_ORCHESTRATOR_ENDPOINT=http://127.0.0.1:1"
run; check "orchestrator down: exit 3" "$RC" 3
has "orchestrator named" "$(LINE orchestrator)" " FAIL orchestrator: /health does not answer 200"
hconf "FLEET_ORCHESTRATOR_ENDPOINT=http://example.invalid:80"
run; has "non-loopback endpoint refused" "$(LINE orchestrator)" " FAIL orchestrator: endpoint missing or not loopback"
hconf
listen 0.0.0.0
run; check "non-loopback bind: exit 3" "$RC" 3
has "classifier bind named" "$(LINE classifier)" " FAIL classifier: listens on a non-loopback address"
listen '[::1]'; run; has "[::1] bind passes" "$(LINE classifier)" "  OK  classifier"
: > "$TMP/stub/ss.out"; run; has "no listener" "$(LINE classifier)" " FAIL classifier: no listener found"
listen

echo "== policy =="
pstate p1 0 ""; run
check "policy_version not computed: exit 3" "$RC" 3
has "names it" "$(LINE policy)" " FAIL policy: policy_version not computed"
pstate p1 0 "$(printf 'b%.0s' {1..64})"; run
has "stale policy_version" "$(LINE policy)" " FAIL policy: policy_version is stale"
pstate p1 0

echo "== removals: a count, acknowledged =="
pstate p1 2; run
check "removals alone do not fail health" "$RC" 0
has "count with !!" "$(LINE removals)" "  !!  removals: 2 term-list entr(y/ies) removed"
run --ack-removals
check "ack: exit 0" "$RC" 0
has "ack reported" "$OUT" "  OK  removals: 2 acknowledged (logged)"
jq -e 'select(.event == "removals_acknowledged") | .count == 2' "$EV" >/dev/null 2>&1 \
    && ok "acknowledgement logged with the count" || bad "acknowledgement not logged"
run; has "count reset after ack" "$(LINE removals)" "  OK  removals: none unacknowledged"
pstate p2 1; run
has "a new snapshot's removals show again" "$(LINE removals)" "  !!  removals: 1 term-list"
pstate p1 0
run --bogus; check "unknown flag: exit 2" "$RC" 2

echo "== notifier, install, selection, swap =="
echo inactive > "$TMP/stub/notify"; run
check "notifier down: exit 3" "$RC" 3
has "notifier named" "$(LINE notifier)" " FAIL notifier: lane2-notify.service not active"
echo active > "$TMP/stub/notify"

printf '# tampered\n' >> "$PREFIX/c1/scripts/lib/gate.sh"; run
has "tampered install" "$(LINE install)" " FAIL install: installed-code digest does not match"
has "tampered gate code also makes policy_version stale" "$(LINE policy)" " FAIL policy: policy_version is stale"
cp "$ROOT/scripts/lib/gate.sh" "$PREFIX/c1/scripts/lib/gate.sh"
install_record
rm "$PREFIX/c1/.lane2-install.json"; run
has "no install record" "$(LINE install)" " FAIL install: no installed tree or install record"
install_record

rm "$STATE/events/image-status.json"; run
has "image never checked" "$(LINE image)" " FAIL image: not checked yet (run sudo lane2 install --verify)"
imgstat fail; run
has "image check failed: FAIL names the image and why" "$(LINE image)" \
    " FAIL image: sha256:1111111111111111111111111111111111111111111111111111111111111111: userns-remap: userns-remap not in effect"
imgstat

rm "$STATE/fleet/selection.json"; run
has "no selection record" "$(LINE selection)" " FAIL selection: no selection record"
selection '.runtime_build = "b9999"'; run
has "runtime changed: re-selection" "$(LINE selection)" " FAIL selection: re-selection required: runtime_build"
selection '.driver_version = "in-tree 6.9.0"'; run
has "driver changed: re-selection" "$(LINE selection)" "re-selection required: driver_version"
selection '.prompt_sha256 = "0"'; run
has "prompt changed: re-selection" "$(LINE selection)" "re-selection required: prompt_sha256"
selection

printf '/dev/sda2 partition 1 0 -2\n' >> "$HW/proc/swaps"; run
check "plain swap: exit 3" "$RC" 3
has "plain swap named" "$(LINE swap)" " FAIL swap: 1 swap device(s) neither encrypted nor memory-only"
printf 'Filename\tType\tSize\tUsed\tPriority\n/dev/dm-0 partition 1 0 -2\n/dev/zram0 partition 1 0 100\n' > "$HW/proc/swaps"
mkdir -p "$HW/sys/block/dm-0/dm"; echo "CRYPT-LUKS2-0000-swap" > "$HW/sys/block/dm-0/dm/uuid"
run; has "dm-crypt and zram pass" "$(LINE swap)" "  OK  swap: encrypted or memory-only (2 device(s))"
echo "LVM-plain" > "$HW/sys/block/dm-0/dm/uuid"
run; has "unencrypted dm device fails" "$(LINE swap)" " FAIL swap: 1 swap device(s)"
printf 'Filename\tType\tSize\tUsed\tPriority\n' > "$HW/proc/swaps"

run
check "all restored: exit 0" "$RC" 0; [[ "$RC" == 0 ]] || printf "%s\n" "$OUT"

echo
echo "lane2-health: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
