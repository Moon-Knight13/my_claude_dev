#!/usr/bin/env bash
# `cond && ok … || bad …` is safe in this file: ok and bad always return 0.
# shellcheck disable=SC2015
# test-gate-hub.sh — the real gate on the hub (SP1a story 2.3, #106).
# tier: hub — real socket activation, real peer check, real classifier. Skips
# (exit 0) unless run as root on the hub with LANE2_HUB_TEST=1, after
# `lane2 install` and `lane2 policy update`.
#
#   sudo LANE2_HUB_TEST=1 bash scripts/tests/test-gate-hub.sh
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
SOCK="$(lane2_conf_file_get /etc/lane2/gate.conf GATE_HUB_SOCKET)"; SOCK="${SOCK:-/run/lane2/gate/hub.sock}"
LANE2=/opt/lane2/current/scripts/hub/lane2

echo "== socket activation =="
check "gate-hub.socket active" "$(systemctl is-active gate-hub.socket)" active
check "gate-hub.socket enabled at boot" "$(systemctl is-enabled gate-hub.socket)" enabled
[[ -S "$SOCK" ]] && ok "hub socket present" || bad "no socket at $SOCK"
for k in PrivateTmp=yes NoNewPrivileges=yes ProtectSystem=strict LimitCORE=0 RuntimeDirectoryMode=0700 User=lane2-gate; do
    grep -qx "$k" /etc/systemd/system/gate-hub@.service && ok "handler unit: $k" || bad "handler unit lacks $k"
done

echo "== real requests =="
OUT="$(printf 'hello, please format this list' | runuser -u "$OP" -- "$LANE2" check 2>&1)"; R=$?
[[ "$R" == 0 || "$R" == 3 ]] && ok "operator gets a well-formed verdict (exit $R)" || bad "lane2 check exit $R: $OUT"
OUT="$(printf 'x' | runuser -u nobody -- "$LANE2" check 2>&1)"; R=$?
check "a non-hub account is blocked" "$R" 3
case "$OUT" in *fault:peer*) ok "  reason fault:peer" ;; *) bad "  reason: $OUT" ;; esac
OUT="$(printf 'x' | runuser -u "$OP" -- "$LANE2" check --layers classifier 2>&1)"; R=$?
[[ "$R" == 0 || "$R" == 3 ]] && ok "the real classifier answers through fleet_call (exit $R)" || bad "classifier path: $OUT"

echo
echo "gate-hub: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
