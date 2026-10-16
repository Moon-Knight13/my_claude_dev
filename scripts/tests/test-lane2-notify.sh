#!/usr/bin/env bash
# `cond && ok … || bad …` is safe in this file: ok and bad always return 0.
# shellcheck disable=SC2015
# test-lane2-notify.sh — desktop notifications for gate blocks and lane2 events
# (SP1a story 2.4, #107; AD-4, FR-7).
# tier: ci — a notify-send stub and a fake clock.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NOTIFY="$ROOT/scripts/hub/lane2-notify"
PASS=0; FAIL=0
ok()   { echo "  OK  $1"; ((PASS++)) || true; }
bad()  { echo " FAIL $1"; ((FAIL++)) || true; }
check(){ if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (no '$3' in output)"; printf '%s\n' "$2" | sed 's/^/      | /' ;; esac; }
hasnt(){ case "$2" in *"$3"*) bad "$1 ('$3' found)" ;; *) ok "$1" ;; esac; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
N="$TMP/sent"; CLOCK="$TMP/clock"; echo 1000 > "$CLOCK"
mkdir -p "$TMP/bin" "$TMP/etc"
printf '#!/usr/bin/env bash\nprintf "%%s|" "$@" >> "%s"; echo >> "%s"\n' "$N" "$N" > "$TMP/bin/notify-send"
chmod +x "$TMP/bin/notify-send"
echo "LANE2_OPERATOR=$(id -un)" > "$TMP/etc/lane2.conf"
export PATH="$TMP/bin:$PATH" CLOCK N

line() { # line <origin> <category> <ref-char> [session]
    jq -nc --arg o "$1" --arg c "$2" --arg r "gr-$(printf "$3%.0s" {1..32})" --arg s "${4:-}" \
        '{time: "t", op: "push", origin: $o, session: (if $s == "" then null else $s end), reason_category: $c, ref: $r}'
}
# run <script> — notifier functions with the fake clock and a 60 s interval
run() { bash -c 'source "$1"; notify_now() { cat "$CLOCK"; }; N_INTERVAL=60; eval "$2"' _ "$NOTIFY" "$1"; }
sent() { cat "$N" 2>/dev/null; }

# =============================================================================
echo "== critical: a hit on a container-origin op =="
: > "$N"
L1="$(line container hit:floor a)"; L2="$(line container hit:classifier b)"
run "notify_line O '$L1'; notify_line O '$L2'"
check "each sent at once, never coalesced" "$(grep -c . "$N")" 2
has "critical urgency" "$(sent)" "-u|critical|"
has "fixed text, category, and ref" "$(head -1 "$N")" "blocked (hit:floor) · ref gr-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

echo "== coalesced per session per interval =="
: > "$N"
O1="$(line operator fault:classifier c s1)"; O2="$(line operator fault:classifier d s1)"
O3="$(line operator fault:classifier e s1)"; S2="$(line operator fault:policy f s2)"
run "notify_line O '$O1'; notify_line O '$O2'; notify_line O '$O3'; notify_line O '$S2'
     echo 1030 > \"\$CLOCK\"; notify_flush; echo 1061 > \"\$CLOCK\"; notify_flush"
check "first per session sent, the rest held, then one summary" "$(grep -c . "$N")" 3
has "normal urgency for coalesced lines" "$(head -1 "$N")" "-u|normal|"
has "the summary counts what it held" "$(tail -1 "$N")" "2 more: blocked (fault:classifier) · ref gr-eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
has "another session is not coalesced into the first" "$(sed -n 2p "$N")" "gr-ffffffffffffffffffffffffffffffff"
: > "$N"
H="$(line container fault:classifier 9 s9)"
run "notify_line O '$H'; notify_line O '$H'"
check "a container fault (not a hit) is coalesced" "$(grep -c . "$N")" 1

echo "== event log lines =="
: > "$N"
run "notify_line E '{\"time\":\"t\",\"event\":\"policy\",\"terms\":3}'"
has "event notified by name, counts never shown" "$(sent)" "lane2 event: policy"
hasnt "no event payload" "$(sent)" "terms"

echo "== malformed lines are counted and skipped, never shown =="
: > "$N"
OUT="$( { echo 'O not json ZZRAW1'
          echo "O $(line operator 'hit:<b>ZZRAW2</b>' a)"
          echo 'O {"reason_category":"hit:floor","ref":"gr-short","origin":"operator"}'
          echo 'E {"event":"ZZRAW3 <script>"}'
          echo 'X {"event":"policy"}'; } | bash "$NOTIFY" --stdin --config-dir "$TMP/etc" 2>&1 )"
check "nothing notified" "$(wc -l < "$N" | tr -d ' ')" 0
has "skipped lines counted" "$OUT" "malformed log lines skipped: 5"
for m in ZZRAW1 ZZRAW2 ZZRAW3; do hasnt "$m never shown" "$OUT $(sent)" "$m"; done

echo "== markup escaping =="
check "escapes & < >" "$(bash -c 'source "$1"; notify_escape "a<b>&c"' _ "$NOTIFY")" "a&lt;b&gt;&amp;c"

echo "== unit =="
mkdir -p "$TMP/units"; U="$TMP/units/lane2-notify.service"
sed -e "s|@LANE2_CODE@|/opt/lane2/c|g" -e "s|@LANE2_CONFIG@|/etc/lane2|g" "$ROOT/scripts/hub/units/user/lane2-notify.service" > "$U"
check "user unit passes the install lint" "$(bash -c 'source "$1"; lane2_lint_user_unit "$2"' _ "$ROOT/scripts/lib/lane2.sh" "$U")" ""
bash -c 'source "$1"; lane2_boot_allowed lane2-notify.service' _ "$ROOT/scripts/lib/lane2.sh" \
    && ok "lane2-notify is on the boot allowlist" || bad "lane2-notify not boot-allowed"
hasnt "runs as the operator (a user unit has no User=)" "$(cat "$U")" "User="
hasnt "the gate never depends on the notifier" "$(cat "$ROOT/scripts/hub/gate-handler" "$ROOT/scripts/lib/gate-store.sh")" "notify"

echo
echo "lane2-notify: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
