#!/usr/bin/env bash
# `cond && ok … || bad …` is safe in this file: ok and bad always return 0.
# shellcheck disable=SC2015
# test-lane2-health-hub.sh — health check v1, restarts, and gate latency on the
# real hub (SP1a story 2.6, #109; FR-23, AD-3, AD-22, NFR-1, SM-5).
# tier: hub — real socket activation, real classifier and orchestrator, the
# operator's real probes. Skips (exit 0) unless run as root on the hub with
# LANE2_HUB_TEST=1, after `lane2 install`, `lane2 policy update` (with the two
# health probes in the policy repository), and the fleet units are installed.
#
#   sudo LANE2_HUB_TEST=1 bash scripts/tests/test-lane2-health-hub.sh
#
# Pins: live probes pass through the real gate; a killed gate handler and a
# killed fleet member are restarted by systemd (Restart=on-failure), health
# names the member while it is down, and callers block meanwhile; the latency
# step through the hub socket writes a record with p50, p95, and max.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok()   { echo "  OK  $1"; ((PASS++)) || true; }
bad()  { echo " FAIL $1"; ((FAIL++)) || true; }
check(){ if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }

# shellcheck source=/dev/null
source "$ROOT/scripts/lib/lane2.sh"
if [[ "${LANE2_HUB_TEST:-}" != 1 ]] || ! lane2_is_root || lane2_in_container; then
    echo "  !!  skipped: hub tier — run as root on the hub with LANE2_HUB_TEST=1"
    exit 0
fi
lane2_load_config /etc/lane2/lane2.conf
OP="$(lane2_conf LANE2_OPERATOR)"
CUR="$(lane2_conf LANE2_PREFIX /opt/lane2)/current"
LANE2="$CUR/scripts/hub/lane2"
EVALH="$CUR/scripts/hub/eval-harness.sh"
asop() { runuser -u "$OP" -- "$@"; }
health() { OUT="$(asop "$LANE2" health 2>&1)"; RC=$?; }
check_ok() { printf 'plain words about formatting a list' | asop "$LANE2" check >/dev/null 2>&1; }

echo "== live probes =="
health
check "lane2 health passes on the installed hub" "$RC" 0
case "$OUT" in *"  OK  gate: hub socket answers the health op"*) ok "the real gate ran both probes" ;; *) bad "gate line: $OUT" ;; esac

echo "== a killed gate handler: the caller blocks, the socket serves again =="
SOCK="$(lane2_conf_file_get /etc/lane2/gate.conf GATE_HUB_SOCKET)"; SOCK="${SOCK:-/run/lane2/gate/hub.sock}"
# A request that never half-closes keeps its handler alive until we kill it.
( { printf '{"v":1,"op":"eval","layers":["floor"]}\n'; sleep 20; } | asop socat -t 30 - "UNIX-CONNECT:$SOCK" > /tmp/lane2-hub-test.answer 2>/dev/null ) &
CLIENT=$!
sleep 2
UNIT="$(systemctl list-units --plain --no-legend 'gate-hub@*.service' | awk '{print $1}' | head -1)"
if [[ -n "$UNIT" ]]; then
    systemctl kill -s KILL "$UNIT"; wait "$CLIENT" 2>/dev/null
    [[ -s /tmp/lane2-hub-test.answer ]] && bad "a killed handler still answered" || ok "a killed handler gives no answer: the caller blocks (AD-3)"
else
    bad "no running gate handler found"
fi
rm -f /tmp/lane2-hub-test.answer
check "gate-hub.socket still active" "$(systemctl is-active gate-hub.socket)" active
check_ok; R=$?; [[ "$R" == 0 || "$R" == 3 ]] && ok "the next request is served (exit $R)" || bad "no answer after the kill (exit $R)"

echo "== a killed fleet member: health names it, systemd restarts it =="
for m in classifier orchestrator; do
    U="fleet-$m.service"
    if ! systemctl cat "$U" >/dev/null 2>&1; then bad "$U not installed"; continue; fi
    grep -qx 'Restart=on-failure' <(systemctl cat "$U") && ok "$U has Restart=on-failure" || bad "$U lacks Restart=on-failure"
    systemctl kill -s KILL "$U"
    sleep 1
    health
    check "$m down: health fails" "$RC" 3
    case "$OUT" in *" FAIL $m:"*) ok "health names the $m" ;; *) bad "health did not name the $m: $OUT" ;; esac
    if [[ "$m" == classifier ]]; then
        printf 'plain words' | asop "$LANE2" check >/dev/null 2>&1; R=$?
        check "callers block while the classifier is down" "$R" 3
    fi
    for _ in $(seq 120); do health; (( RC == 0 )) && break; sleep 2; done
    check "$m restarted by systemd; health passes again" "$RC" 0
done

echo "== latency through the hub socket (NFR-1, SM-5) =="
OUT="$(asop "$EVALH" latency --runs 5 2>&1)"; R=$?
check "latency step exits 0" "$R" 0
case "$OUT" in *"latency record written"*) ok "latency record written" ;; *) bad "no latency record: $OUT" ;; esac
printf '%s\n' "$OUT" | grep -E '^( FAIL |  OK  )(nfr1|gate_deadline)' | sed 's/^/      /'

echo
echo "lane2-health-hub: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
