#!/usr/bin/env bash
# `cond && ok … || bad …` is safe in this file: ok and bad always return 0.
# shellcheck disable=SC2015
# test-mount-scan-hub.sh — mark and scan against the real gate on the hub (SP1a
# story 3.2, #112).
# tier: hub — skips (exit 0) unless run on the hub as the operator with
# LANE2_HUB_TEST=1, after lane2 install and lane2 policy update.
#
#   LANE2_HUB_TEST=1 bash scripts/tests/test-mount-scan-hub.sh
#   LANE2_HUB_TEST=1 LANE2_HUB_TEST_TERM=<one of your terms> bash …   (also tests a real hit)
#
# The optional term is typed at run time and never written to the repo; the
# test workspace holding it is removed at the end.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok()   { echo "  OK  $1"; ((PASS++)) || true; }
bad()  { echo " FAIL $1"; ((FAIL++)) || true; }
check(){ if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }

# shellcheck source=/dev/null
source "$ROOT/scripts/lib/lane2.sh"
if [[ "${LANE2_HUB_TEST:-}" != 1 ]] || lane2_in_container; then
    echo "  !!  skipped: hub tier — run on the hub as the operator with LANE2_HUB_TEST=1"
    exit 0
fi
LANE2=/opt/lane2/current/scripts/hub/lane2
TMP="$(mktemp -d "$HOME/.lane2-hubtest.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
G() { git -c user.name=t -c user.email=t@example.invalid -c init.defaultBranch=main "$@"; }

R="$TMP/clean"; mkdir -p "$R"; G init -q "$R"; echo "hello" > "$R/README.md"; G -C "$R" add -A; G -C "$R" commit -qm i
"$LANE2" mark "$R" mountable >/dev/null; check "mark mountable" "$?" 0
OUT="$("$LANE2" scan "$R" 2>&1)"; check "real gate: a clean workspace scans clean" "$?" 0

R="$TMP/esc"; mkdir -p "$R"; G init -q "$R"; ln -s /etc/hostname "$R/h"
"$LANE2" mark "$R" mountable >/dev/null
"$LANE2" scan "$R" >/dev/null 2>&1; RC=$?
(( RC >= 4 )) && ok "an escaping symlink is a fault" || bad "escape: exit $RC"

if [[ -n "${LANE2_HUB_TEST_TERM:-}" ]]; then
    R="$TMP/hit"; mkdir -p "$R"; G init -q "$R"
    printf 'notes: %s\n' "$LANE2_HUB_TEST_TERM" > "$R/n.txt"
    "$LANE2" mark "$R" mountable >/dev/null
    OUT="$("$LANE2" scan "$R" 2>/dev/null)"; RC=$?
    check "a real term: blocked (exit 3)" "$RC" 3
    [[ "$OUT" =~ ^gr-[0-9a-f]{32}$ ]] && ok "prints only the ref" || bad "output was not a bare ref"
else
    echo "  !!  no LANE2_HUB_TEST_TERM: real-hit case skipped"
fi

echo
echo "mount-scan-hub: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
