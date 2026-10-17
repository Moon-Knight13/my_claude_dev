#!/usr/bin/env bash
# `cond && ok … || bad …` is safe in this file: ok and bad always return 0.
# shellcheck disable=SC2015
# test-gate-cache.sh — verdict cache, rate limit, probe budget, query log, and
# no lookup endpoints (SP1a story 2.5, #108; AD-19, AD-20, FR-10, FR-13, FR-14).
# tier: ci — the real handler behind a real unix socket; the llama-server mock.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATE="$ROOT/scripts/lib/gate.sh"
PASS=0; FAIL=0
ok()   { echo "  OK  $1"; ((PASS++)) || true; }
bad()  { echo " FAIL $1"; ((FAIL++)) || true; }
check(){ if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }
hasnt(){ case "$2" in *"$3"*) bad "$1 ('$3' found)" ;; *) ok "$1" ;; esac; }

# shellcheck source=/dev/null
source "$ROOT/scripts/tests/gate-fixture.sh"
gf_setup
[[ -S "$SOCK" ]] || { echo " FAIL gate socket did not come up"; exit 1; }
PV1="$(printf '1%.0s' {1..64})"; PV2="$(printf '2%.0s' {1..64})"
CACHE="$STATE/gate-store/cache.jsonl"; QLOG="$STATE/gate-store/query.jsonl"

# dec <text> <pv> [layer set] [bypass] — gate_decide with the fixture policy;
# prints "<verdict> <reason> hit=<0|1> calls=<classifier calls made>"
dec() {
    printf '%s' "$1" > "$TMP/in"
    local b; b="$(gf_completions)"
    bash -c 'source "$1"; gate_cache_init "$2"; gate_policy_load "$3/gate-policy" "$4" || exit 9
             GATE_LAYER_SET="$7"; GATE_CACHE_BYPASS="$8"
             gate_decide "$5" "$6" "$9"; echo "$GATE_VERDICT $GATE_REASON hit=$GATE_CACHE_HIT"' \
        _ "$GATE" "$STATE" "$STATE" "$(id -un)" "$TMP/in" "$CONF/fleet.conf" "${3:-full}" "${4:-0}" "$2" 2>/dev/null | tail -1 \
        | tr '\n' ' '
    echo "calls=$(( $(gf_completions) - b ))"
}

# =============================================================================
echo "== key composition =="
key() { printf '%b' "$1" > "$TMP/k"; bash -c 'source "$1"; gate_cache_key "$2" "$3" "$4"' _ "$GATE" "$TMP/k" "$2" "$3"; }
K="$(key 'same text\n' "$PV1" full)"
[[ "$K" =~ ^[0-9a-f]{64}$ ]] && ok "a sha256 key" || bad "no key ($K)"
check "CRLF and trailing newlines normalised" "$(key 'same text\r\n\n\n' "$PV1" full)" "$K"
[[ "$(key 'same text, changed\n' "$PV1" full)" != "$K" ]] && ok "content is in the key" || bad "content not in the key"
[[ "$(key 'same text\n' "$PV2" full)" != "$K" ]] && ok "policy_version is in the key" || bad "policy_version not in the key"
[[ "$(key 'same text\n' "$PV1" floor-only)" != "$K" ]] && ok "layer set is in the key" || bad "layer set not in the key"

echo "== allow-only caching =="
check "first allow calls the classifier" "$(dec 'plain text one' "$PV1")" "allow  hit=0 calls=1"
check "second time: a cache hit, no classifier call" "$(dec 'plain text one' "$PV1")" "allow  hit=1 calls=0"
check "a classifier block" "$(dec 'ZZSENSITIVE text' "$PV1")" "block hit:classifier hit=0 calls=1"
check "a block is never cached: called again" "$(dec 'ZZSENSITIVE text' "$PV1")" "block hit:classifier hit=0 calls=1"
check "a floor block never reaches cache or classifier" "$(dec 'about zzalpha' "$PV1")" "block hit:floor hit=0 calls=0"
check "only allow entries in the cache" "$(wc -l < "$CACHE" | tr -d ' ')" 1
hasnt "the cache holds no content" "$(cat "$CACHE")" "plain text"
check "cache file 0600" "$(stat -c %a "$CACHE")" 600

echo "== floor-only isolation =="
check "floor-only: allow without classifier or cache" "$(dec 'floor only text' "$PV1" floor-only)" "allow  hit=0 calls=0"
check "a floor-only allow never serves a full request" "$(dec 'floor only text' "$PV1")" "allow  hit=0 calls=1"
check "floor-only never reads a full entry either" "$(dec 'plain text one' "$PV1" floor-only)" "allow  hit=0 calls=0"

echo "== bypass flag (eval, health) =="
check "bypass: classifier called despite a cached allow" "$(dec 'plain text one' "$PV1" full 1)" "allow  hit=0 calls=1"
check "bypass writes nothing" "$(wc -l < "$CACHE" | tr -d ' ')" 2
b="$(gf_completions)"
for i in 1 2 3; do gf_ask classifier "plain text one"; done
check "eval op: the classifier is called for every item" "$(( $(gf_completions) - b ))" 3
check "eval op: no cache entry written" "$(wc -l < "$CACHE" | tr -d ' ')" 2

echo "== policy invalidation =="
check "a new policy_version: classified again" "$(dec 'plain text one' "$PV2")" "allow  hit=0 calls=1"
check "entries under the earlier policy_version are purged" "$(jq -s 'map(select(.pv == "'"$PV1"'")) | length' "$CACHE")" 0
check "then cached under the new one" "$(dec 'plain text one' "$PV2")" "allow  hit=1 calls=0"

echo "== a broken cache blocks =="
cp "$CACHE" "$TMP/c.bak"; printf 'not json\n' >> "$CACHE"
check "corrupt cache: fault:store, never a miss" "$(dec 'plain text one' "$PV2")" "block fault:store hit=0 calls=0"
cp "$TMP/c.bak" "$CACHE"; chmod 000 "$CACHE"
check "unreadable cache: fault:store" "$(dec 'plain text one' "$PV2")" "block fault:store hit=0 calls=0"
chmod 600 "$CACHE"
( exec 7>>"$STATE/gate-store/.cache.lock"; flock 7; sleep 5 ) & HOLD=$!; sleep 0.3
check "cache lock wait over: fault:store" "$(dec 'plain text one' "$PV2")" "block fault:store hit=0 calls=0"
kill "$HOLD" 2>/dev/null; wait "$HOLD" 2>/dev/null

# =============================================================================
echo "== query log =="
: > "$QLOG"
gf_ask floor "a clear request"; gf_ask floor "zzbravo blocked"
check "one line per hub-socket request" "$(wc -l < "$QLOG" | tr -d ' ')" 2
check "fields: time, op, peer_uid, verdict, ref" "$(head -1 "$QLOG" | jq -c 'keys')" '["op","peer_uid","ref","time","verdict"]'
check "allow line" "$(head -1 "$QLOG" | jq -r '"\(.op) \(.peer_uid) \(.verdict) \(.ref)"')" "eval $(id -u) allow null"
check "block line carries its ref" "$(tail -1 "$QLOG" | jq -r .ref)" "$(jq -r .ref <<<"$RESP")"
hasnt "never content" "$(cat "$QLOG")" "zzbravo"
hasnt "never content (clear)" "$(cat "$QLOG")" "clear request"
check "query log 0600" "$(stat -c %a "$QLOG")" 600

echo "== no lookup endpoints =="
for op in lookup ref policy policy_version terms term_list list ls dump cache stats version query; do
    OUT="$(printf '{"v":1,"op":"%s"}\nx' "$op" | gf_raw raw)"
    check "op $op: block" "$(gf_reason_of "$OUT")" fault:protocol
done
for f in ref policy policy_version list terms cache; do
    OUT="$(printf '{"v":1,"op":"eval","layers":["floor"],"%s":true}\nx' "$f" | gf_raw raw)"
    check "eval with field $f: block" "$(gf_reason_of "$OUT")" fault:protocol
done
OUT="$(printf '{"v":1,"op":"health"}\n' | gf_raw raw)$(printf '{"v":1,"op":"eval","layers":["floor","classifier"]}\nhello' | gf_raw raw)"
for v in "$PV1" "$PV2"; do hasnt "no answer carries a policy_version" "$OUT" "$v"; done
hasnt "no answer carries a term" "$(tr '[:upper:]' '[:lower:]' <<<"$OUT")" "zzalpha"

# =============================================================================
echo "== rate limit =="
gf_conf "GATE_RATE_LIMIT=3" "GATE_RATE_WINDOW=60" "GATE_PROBE_BUDGET=50"
rm -rf "$STATE/gate-store/counters"; : > "$STATE/operator-log/gate.jsonl"
for i in 1 2 3; do gf_ask floor "request $i"; done
check "within the rate: allow" "$RC" 0
gf_ask floor "request 4"
check "over the rate: block probe" "$REASON" "probe"
check "probe written to the operator log" "$(tail -1 "$STATE/operator-log/gate.jsonl" | jq -r .reason_category)" probe
gf_ask floor "request 5"; check "still over until the window ends" "$REASON" "probe"
U="$STATE/gate-store/counters/$(id -u)"
jq '.w = 1' "$U" > "$U.t" && mv "$U.t" "$U"
gf_ask floor "after the window"; check "a new window: allowed again" "$RC" 0

echo "== probe budget =="
gf_conf "GATE_RATE_LIMIT=1000" "GATE_RATE_WINDOW=60" "GATE_PROBE_BUDGET=2"
rm -rf "$STATE/gate-store/counters"
gf_ask floor "zzalpha one"; gf_ask floor "zzbravo two"
gf_ask floor "a clear request now"
check "blocks over the budget: even clear text blocks with probe" "$REASON" "probe"

echo "== corrupt counters count as over the limit =="
gf_conf; rm -rf "$STATE/gate-store/counters"
gf_ask floor "seed"; printf 'garbage' > "$U"
gf_ask floor "after corruption"; check "corrupt counters: probe" "$REASON" "probe"
chmod 000 "$U"; gf_ask floor "unreadable"; check "unreadable counters: probe" "$REASON" "probe"; chmod 600 "$U"
rm -rf "$STATE/gate-store/counters"

echo "== notifier treats a probe as critical, coalesced =="
N="$TMP/notified"; mkdir -p "$TMP/nb"
printf '#!/usr/bin/env bash\nprintf "%%s|" "$@" >> "%s"; echo >> "%s"\n' "$N" "$N" > "$TMP/nb/notify-send"; chmod +x "$TMP/nb/notify-send"
PL="$(jq -nc '{time: "t", op: "unknown", origin: "hub", session: null, reason_category: "probe", ref: ("gr-" + ("a" * 32))}')"
printf 'O %s\nO %s\n' "$PL" "$PL" | PATH="$TMP/nb:$PATH" bash "$ROOT/scripts/hub/lane2-notify" --stdin --config-dir "$CONF" 2>/dev/null
check "one critical probe notification for two lines" "$(grep -c 'critical' "$N")" 1

echo "== config bounds stop the gate =="
cfg() { gf_conf "$@"; bash "$GF_HANDLER" --check-config "$CONF" >/dev/null 2>&1; echo $?; }
check "GATE_RATE_LIMIT=0 refused" "$(cfg GATE_RATE_LIMIT=0)" 4
check "GATE_RATE_WINDOW over a day refused" "$(cfg GATE_RATE_WINDOW=90000)" 4
check "GATE_PROBE_BUDGET=x refused" "$(cfg GATE_PROBE_BUDGET=x)" 4
gf_conf

echo
echo "gate-cache: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
