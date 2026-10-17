#!/usr/bin/env bash
# `cond && ok … || bad …` is safe in this file: ok and bad always return 0.
# shellcheck disable=SC2015
# test-gate-chunking-hub.sh — chunked classification latency on the hub (SP1a
# story 2.7, #110; NFR-1, AD-20).
# tier: hub — the real gate and classifier. Skips (exit 0) unless run on the hub
# as the operator with LANE2_HUB_TEST=1.
#
#   LANE2_HUB_TEST=1 bash scripts/tests/test-gate-chunking-hub.sh   (as the operator)
#
# Sends a synthetic ~20k-token request 20 times through the classifier layer and
# checks p95 stays inside GATE_DEADLINE.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok()   { echo "  OK  $1"; ((PASS++)) || true; }
bad()  { echo " FAIL $1"; ((FAIL++)) || true; }

# shellcheck source=/dev/null
source "$ROOT/scripts/lib/lane2.sh"
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/gate-client.sh"
if [[ "${LANE2_HUB_TEST:-}" != 1 ]] || lane2_in_container; then
    echo "  !!  skipped: hub tier — run on the hub with LANE2_HUB_TEST=1"
    exit 0
fi
SOCK="$(lane2_conf_file_get /etc/lane2/gate.conf GATE_HUB_SOCKET)"; SOCK="${SOCK:-/run/lane2/gate/hub.sock}"
DL="$(lane2_conf_file_get /etc/lane2/gate.conf GATE_DEADLINE)"; DL="${DL:-25}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# ~80k characters of ordinary synthetic text (~20k tokens).
for (( i = 0; i < 1600; i++ )); do printf 'The build finished and the report lists each step in order. '; done > "$TMP/big"
printf '%s chars\n' "$(wc -c < "$TMP/big" | tr -d ' ')"
T=()
for (( r = 0; r < 20; r++ )); do
    s=$(date +%s%N)
    gate_client "$SOCK" "$((DL + 3))" '{"v":1,"op":"eval","layers":["classifier"]}' < "$TMP/big" >/dev/null; rc=$?
    e=$(date +%s%N)
    T+=("$(( (e - s) / 1000000 ))")
    [[ "$rc" == 0 || "$rc" == 3 ]] || bad "run $r: no well-formed answer (rc $rc): $(jq -r '.detail.reason // empty' <<<"${GATE_CLIENT_RESPONSE:-null}")"
done
P95="$(printf '%s\n' "${T[@]}" | sort -n | awk '{ a[NR] = $1 } END { i = int(NR * 0.95 + 0.999); if (i > NR) i = NR; print a[i] }')"
echo "      p50 $(printf '%s\n' "${T[@]}" | sort -n | sed -n 10p) ms, p95 $P95 ms, deadline ${DL}000 ms"
(( P95 < DL * 1000 )) && ok "p95 inside the gate deadline" || bad "p95 $P95 ms is over the gate deadline"

echo
echo "gate-chunking-hub: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
