#!/usr/bin/env bash
# `cond && ok … || bad …` is safe in this file: ok and bad always return 0.
# shellcheck disable=SC2015
# test-gate-retention.sh — opaque refs, retained payloads, expiry and quotas,
# the operator log, and lane2 review show (SP1a story 2.4, #107; AD-4, AD-7,
# FR-7, FR-9, FR-10, NFR-7).
# tier: ci — the real handler behind a real unix socket; a fake clock for expiry.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STORELIB="$ROOT/scripts/lib/gate-store.sh"
PASS=0; FAIL=0
ok()   { echo "  OK  $1"; ((PASS++)) || true; }
bad()  { echo " FAIL $1"; ((FAIL++)) || true; }
check(){ if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }
hasnt(){ case "$2" in *"$3"*) bad "$1 ('$3' found)" ;; *) ok "$1" ;; esac; }

# shellcheck source=/dev/null
source "$ROOT/scripts/tests/gate-fixture.sh"
gf_setup
[[ -S "$SOCK" ]] || { echo " FAIL gate socket did not come up"; exit 1; }
PAY="$STATE/gate-store/payloads"; OPLOG="$STATE/operator-log/gate.jsonl"

# A block on a known op that is not served yet (push): the payload is read,
# retained, and logged.
push() { printf '{"v":1,"op":"push","workspace":"w"}\n%s' "$1" | gf_raw raw; }

# =============================================================================
echo "== refs =="
REFS="$(bash -c 'source "$1"; gate_store_init "$2"; for i in $(seq 200); do gate_new_ref; echo; done' _ "$STORELIB" "$TMP/none")"
check "200 refs, all gr- + 32 lowercase hex" "$(grep -cE '^gr-[0-9a-f]{32}$' <<<"$REFS")" 200
check "no ref repeats" "$(sort <<<"$REFS" | uniq -d | wc -l | tr -d ' ')" 0
R1="$(push 'same payload')"; R2="$(push 'same payload')"
[[ "$(jq -r .ref <<<"$R1")" != "$(jq -r .ref <<<"$R2")" ]] && ok "same content, different refs (not content-derived)" || bad "refs repeat for the same content"

echo "== opacity =="
check "hub-socket block: only v, verdict, ref, detail" "$(jq -c 'keys' <<<"$R1")" '["detail","ref","v","verdict"]'
check "detail holds only reason_category" "$(jq -c '.detail | keys' <<<"$R1")" '["reason_category"]'
CA="$(bash -c 'source "$1"; gate_container_answer gr-00000000000000000000000000000000' _ "$GF_HANDLER")"
check "container answer: only v, verdict, ref" "$(jq -c 'keys' <<<"$CA")" '["ref","v","verdict"]'
PAT="$ROOT/scripts/lib/gate-patterns.conf"
check "fixed block text lives in the public pattern file" \
    "$(bash -c 'source "$1"; lane2_conf_file_get "$2" GATE_BLOCK_TEXT' _ "$ROOT/scripts/lib/lane2.sh" "$PAT")" \
    "blocked by gate · ref <ref> · see hub notification"
check "ref format in the pattern file" \
    "$(bash -c 'source "$1"; lane2_conf_file_get "$2" GATE_REF_REGEX' _ "$ROOT/scripts/lib/lane2.sh" "$PAT")" '^gr-[0-9a-f]{32}$'

echo "== retained payload =="
REF="$(jq -r .ref <<<"$R1")"
[[ -f "$PAY/$REF" ]] && ok "payload file named by the ref" || bad "no payload file for $REF"
check "payload file is 0600" "$(stat -c %a "$PAY/$REF")" 600
check "payload directory is 0700" "$(stat -c %a "$PAY")" 700
check "payload kept exactly" "$(cat "$PAY/$REF")" "same payload"
check "index file is 0600" "$(stat -c %a "$PAY/index.jsonl")" 600
OUTSIDE="$(grep -rl 'same payload' "$STATE" "$CONF" "$TMP/handler.err" 2>/dev/null | grep -vF "$PAY/" || true)"
check "the payload is nowhere outside the payload directory" "$OUTSIDE" ""

echo "== operator log =="
L="$(tail -1 "$OPLOG")"
check "one line per block" "$(wc -l < "$OPLOG" | tr -d ' ')" 2
check "fields are exactly time, op, origin, session, reason_category, ref" "$(jq -c 'keys' <<<"$L")" \
    '["op","origin","reason_category","ref","session","time"]'
check "op and origin are gate-derived" "$(jq -r '"\(.op) \(.origin)"' <<<"$L")" "push container"
check "log is group-readable by the operator (0640)" "$(stat -c %a "$OPLOG")" 640
gf_ask floor "zzalpha here"
check "eval blocks write no log line" "$(wc -l < "$OPLOG" | tr -d ' ')" 2
check "eval blocks retain nothing" "$(find "$PAY" -name 'gr-*' | wc -l | tr -d ' ')" 2

echo "== marker scan =="
OUT="$(printf '{"v":1,"op":"ZZOPMARK","x":"ZZFIELDMARK"}\nZZPAYMARK one' | gf_raw raw)"
OUT2="$(printf '{"v":1,"op":"push","workspace":"ZZFIELDMARK2"}\nZZPAYMARK two' | gf_raw raw)"
check "unknown op logged as unknown" "$(tail -2 "$OPLOG" | head -1 | jq -r .op)" "unknown"
N="$TMP/notify.args"; mkdir -p "$TMP/nbin"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\n' "$N" > "$TMP/nbin/notify-send"; chmod +x "$TMP/nbin/notify-send"
sed 's/^/O /' "$OPLOG" | PATH="$TMP/nbin:$PATH" bash "$ROOT/scripts/hub/lane2-notify" --stdin --config-dir "$CONF" 2>/dev/null
for m in ZZOPMARK ZZFIELDMARK ZZPAYMARK; do
    hasnt "$m not in the operator log" "$(cat "$OPLOG")" "$m"
    hasnt "$m not in the responses" "$OUT $OUT2" "$m"
    hasnt "$m not in the journal (handler stderr)" "$(cat "$TMP/handler.err")" "$m"
    hasnt "$m not in a notification" "$(cat "$N" 2>/dev/null)" "$m"
done

# =============================================================================
echo "== expiry (fake clock) =="
EX="$TMP/ex"; mkdir -p "$EX/gate-store" "$EX/operator-log"; chmod 700 "$EX/gate-store"
printf 'payload-a' > "$TMP/pa"; printf 'payload-b' > "$TMP/pb"
st() { # st <clock> <commands...> — run against the expiry store at a fixed time
    local clock="$1"; shift
    bash -c 'source "$1"; clock="$2"; shift 2; gate_now() { echo "$clock"; }
             GATE_RETAIN_DAYS=7 GATE_STORE_MAX_BYTES=100000 GATE_QUOTA_OPERATOR_BYTES=50000 GATE_QUOTA_CONTAINER_BYTES=50000
             gate_store_init "$EX"; eval "$*"' _ "$STORELIB" "$clock" "$@"
}
export EX
T0=1800000000; D=86400
RA="gr-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"; RB="gr-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
st "$T0" "gate_retain $RA $TMP/pa operator"
st "$(( T0 + 5 * D ))" "gate_retain $RB $TMP/pb operator"
st "$(( T0 + 7 * D + 1 ))" "gate_purge"
[[ ! -e "$EX/gate-store/payloads/$RA" ]] && ok "expired payload removed" || bad "expired payload kept"
[[ -e "$EX/gate-store/payloads/$RB" ]] && ok "unexpired payload kept" || bad "unexpired payload removed"
check "review: expired ref says expired" "$(st "$(( T0 + 7 * D + 1 ))" "gate_review_state $RA")" expired
check "review: live ref is kept" "$(st "$(( T0 + 7 * D + 1 ))" "gate_review_state $RB")" kept
check "review: unknown ref" "$(st "$T0" "gate_review_state gr-cccccccccccccccccccccccccccccccc")" unknown

echo "== retention bounds stop the gate (never clamped) =="
cfg() { gf_conf "$@"; bash "$GF_HANDLER" --check-config "$CONF" >/dev/null 2>&1; echo $?; }
check "GATE_RETAIN_DAYS=30 is allowed" "$(cfg GATE_RETAIN_DAYS=30)" 0
check "GATE_RETAIN_DAYS=31 stops the gate" "$(cfg GATE_RETAIN_DAYS=31)" 4
check "GATE_RETAIN_DAYS=0 stops the gate" "$(cfg GATE_RETAIN_DAYS=0)" 4
check "GATE_RETAIN_DAYS=7.5 stops the gate" "$(cfg GATE_RETAIN_DAYS=7.5)" 4
check "a quota above the total stops the gate" "$(cfg GATE_STORE_MAX_BYTES=100 GATE_QUOTA_OPERATOR_BYTES=200)" 4
gf_conf

echo "== quotas, no eviction, full and broken stores =="
Q="$TMP/q"; mkdir -p "$Q/gate-store" "$Q/operator-log"; chmod 700 "$Q/gate-store"
head -c 600 /dev/zero | tr '\0' x > "$TMP/p600"
qs() { bash -c 'source "$1"; shift; gate_now() { echo 1800000000; }
                GATE_RETAIN_DAYS=7 GATE_STORE_MAX_BYTES=2000 GATE_QUOTA_OPERATOR_BYTES=1000 GATE_QUOTA_CONTAINER_BYTES=1000
                gate_store_init "$Q"; gate_retain "$@"; echo $?' _ "$STORELIB" "$@"; }
export Q
check "container payload within its quota" "$(qs gr-c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1 "$TMP/p600" container)" 0
check "container payload over its quota: store fault" "$(qs gr-c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2 "$TMP/p600" container)" 4
check "container volume cannot use the operator quota" "$(qs gr-01010101010101010101010101010101 "$TMP/p600" operator)" 0
check "operator quota then also full" "$(qs gr-02020202020202020202020202020202 "$TMP/p600" operator)" 4
[[ -f "$Q/gate-store/payloads/gr-c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1" && -f "$Q/gate-store/payloads/gr-01010101010101010101010101010101" ]] \
    && ok "nothing unexpired was evicted" || bad "a payload was evicted"
gf_conf "GATE_STORE_MAX_BYTES=10" "GATE_QUOTA_OPERATOR_BYTES=10" "GATE_QUOTA_CONTAINER_BYTES=10"
OUT="$(push 'a payload longer than ten bytes')"
check "full store: block fault:store" "$(jq -r '"\(.verdict) \(.detail.reason_category)"' <<<"$OUT")" "block fault:store"
check "full store: operator log line written" "$(tail -1 "$OPLOG" | jq -r .reason_category)" "fault:store"
gf_conf
cp "$PAY/index.jsonl" "$TMP/idx"; printf 'not json\n' >> "$PAY/index.jsonl"
OUT="$(push 'with a corrupt index')"
check "corrupt index counts as over the limit" "$(jq -r .detail.reason_category <<<"$OUT")" "fault:store"
cp "$TMP/idx" "$PAY/index.jsonl"; chmod 600 "$PAY/index.jsonl"
chmod 500 "$PAY"; OUT="$(push 'with an unwritable store')"; chmod 700 "$PAY"
check "unwritable store: block fault:store" "$(jq -r .detail.reason_category <<<"$OUT")" "fault:store"
( exec 9>>"$STATE/gate-store/.lock"; flock 9; sleep 6 ) & HOLD=$!; sleep 0.3
START=$(date +%s); OUT="$(push 'while the store is locked')"; END=$(date +%s)
kill "$HOLD" 2>/dev/null; wait "$HOLD" 2>/dev/null
check "lock wait over: block fault:store" "$(jq -r .detail.reason_category <<<"$OUT")" "fault:store"
(( END - START < 6 )) && ok "lock wait is bounded ($((END - START)) s)" || bad "lock wait took $((END - START)) s"

# =============================================================================
echo "== lane2 review show =="
RV() { bash -c 'source "$1"; shift; lane2_in_container() { return 1; }; lane2_is_root() { return 0; }; lane2_main "$@"' \
          _ "$ROOT/scripts/hub/lane2" --config-dir "$CONF" review show "$@"; }
OUT="$(RV "$REF" 2>&1)"; R=$?
check "a kept ref shows (exit 0)" "$R" 0
case "$OUT" in *"same payload"*) ok "shows the retained payload" ;; *) bad "payload not shown" ;; esac
case "$OUT" in *"origin: container"*) ok "shows the operator log metadata" ;; *) bad "metadata not shown: $OUT" ;; esac
OUT="$(RV gr-dddddddddddddddddddddddddddddddd 2>&1)"; R=$?
check "unknown ref: exit 3" "$R" 3
case "$OUT" in *"not found"*) ok "says not found" ;; *) bad "$OUT" ;; esac
printf '{"ref":"%s","t":1,"origin":"operator","bytes":1,"state":"expired"}\n' gr-eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee >> "$PAY/index.jsonl"
OUT="$(RV gr-eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee 2>&1)"; R=$?
check "expired ref: exit 3" "$R" 3
case "$OUT" in *"expired"*) ok "says expired" ;; *) bad "$OUT" ;; esac
RV "not-a-ref" >/dev/null 2>&1; check "bad ref format: exit 2" "$?" 2
OUT="$(DEVCONTAINER=true bash "$ROOT/scripts/hub/lane2" --config-dir "$CONF" review show "$REF" 2>&1)"; R=$?
check "review refuses inside a container" "$R" 4
OUT="$(bash -c 'source "$1"; shift; lane2_in_container() { return 1; }; lane2_is_root() { return 1; }; lane2_main "$@"' \
          _ "$ROOT/scripts/hub/lane2" --config-dir "$CONF" review show "$REF" 2>&1)"; R=$?
check "review needs root" "$R" 4

echo
echo "gate-retention: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
