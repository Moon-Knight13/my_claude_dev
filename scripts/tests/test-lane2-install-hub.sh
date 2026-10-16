#!/usr/bin/env bash
# `cond && ok … || bad …` is safe in this file: ok and bad always return 0.
# shellcheck disable=SC2015
# test-lane2-install-hub.sh — the real `lane2 install` on the hub (SP1a story
# 2.1, #104; AD-7, AD-18, AD-21, AD-22, NFR-6).
# tier: hub — real install, real service identities, real units. Skips (exit 0)
# unless run as root on the hub with LANE2_HUB_TEST=1, so CI stays green.
#
#   sudo LANE2_HUB_TEST=1 LANE2_HUB_TEST_COMMIT=<40-hex merged commit> \
#        bash scripts/tests/test-lane2-install-hub.sh
#
# It installs that commit with the hub config in /etc/lane2, then checks the
# result. Run it before an SP1a release.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LANE2="$ROOT/scripts/hub/lane2"
LIB="$ROOT/scripts/lib/lane2.sh"
PASS=0; FAIL=0
ok()   { echo "  OK  $1"; ((PASS++)) || true; }
bad()  { echo " FAIL $1"; ((FAIL++)) || true; }
check(){ if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }

# shellcheck source=/dev/null
source "$LIB"
if [[ "${LANE2_HUB_TEST:-}" != 1 ]] || ! lane2_is_root || lane2_in_container; then
    echo "  !!  skipped: hub tier — run as root on the hub with LANE2_HUB_TEST=1"
    exit 0
fi
COMMIT="${LANE2_HUB_TEST_COMMIT:-}"
[[ "$COMMIT" =~ ^[0-9a-f]{40}$ ]] || { echo " FAIL set LANE2_HUB_TEST_COMMIT to a full merged commit id"; exit 1; }

echo "== real install =="
OUT="$(bash "$LANE2" install "$COMMIT" 2>&1)"; RC=$?
printf '%s\n' "$OUT" | sed 's/^/      | /'
check "lane2 install exits 0" "$RC" 0
lane2_load_config /etc/lane2/lane2.conf
PREFIX="$(lane2_conf LANE2_PREFIX /opt/lane2)"; STATE="$(lane2_conf LANE2_STATE_ROOT /var/lib/lane2)"
UNIT_DIR="$(lane2_conf LANE2_UNIT_DIR /etc/systemd/system)"
check "current -> commit" "$(readlink "$PREFIX/current")" "$COMMIT"
OUT="$(bash "$LANE2" install --verify 2>&1)"; RC=$?
check "--verify passes" "$RC" 0
check "install tree root-owned" "$(find "$PREFIX/$COMMIT" ! -uid 0 -print -quit)" ""

echo "== service identities =="
for n in "${LANE2_SERVICE_IDENTITIES[@]}"; do
    lane2_check_identity "$n" && ok "$n: non-root, no login shell, not the operator" || bad "$n is not a proper service identity"
done
check "identities have distinct uids" \
    "$(for n in "${LANE2_SERVICE_IDENTITIES[@]}"; do getent passwd "$n" | cut -d: -f3; done | sort | uniq -d)" ""

echo "== stores =="
while read -r name owner group mode; do
    want="$(lane2_uid "$owner") $(lane2_gid "$group") ${mode#0}"
    check "store $name owner/group/mode" "$(stat -c '%u %g %a' "$STATE/$name")" "$want"
done < <(lane2_stores)
check "gate cannot write the policy checkout" \
    "$(runuser -u lane2-gate -- test -w "$STATE/gate-policy" && echo writable || echo no)" no
check "gate can write the gate store" \
    "$(runuser -u lane2-gate -- test -w "$STATE/gate-store" && echo writable || echo no)" writable

echo "== units =="
while IFS= read -r u; do
    [[ -n "$u" ]] || continue
    en="$(systemctl is-enabled "$u" 2>/dev/null || true)"
    if lane2_boot_allowed "$u"; then
        ok "$u allowed at boot ($en)"
    else
        [[ "$en" != enabled ]] && ok "$u not enabled at boot" || bad "$u enabled at boot"
    fi
    [[ "$u" == fleet-*.service ]] || continue
    systemctl start "$u" && sleep 2
    check "$u starts" "$(systemctl is-active "$u")" active
done < "$STATE/install/units.list"
grep -lE '(/home/|/workspace)' "$UNIT_DIR"/gate-* "$UNIT_DIR"/fleet-* "$UNIT_DIR"/lane2* 2>/dev/null \
    && bad "an installed unit references a home or workspace path" || ok "no installed unit references a home or workspace path"

echo
echo "lane2-install-hub: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
