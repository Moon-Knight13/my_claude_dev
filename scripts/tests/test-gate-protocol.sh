#!/usr/bin/env bash
# `cond && ok … || bad …` is safe in this file: ok and bad always return 0.
# shellcheck disable=SC2015
# test-gate-protocol.sh — gate protocol v1 on the hub socket, floor OR
# classifier, lane2 check, and the shipped units (SP1a story 2.3, #106; AD-1,
# AD-2, AD-20, FR-4, FR-5, FR-11, FR-12).
# tier: ci — real handler behind a real unix socket; the classifier is the
# llama-server mock; synthetic terms only (zzalpha, zzbravo).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
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

# =============================================================================
echo "== allow and block =="
gf_ask floor,classifier "please refactor the parser"
check "clear text: allow" "$RC" 0
check "answer is exactly v/verdict/detail" "$(jq -c 'keys' <<<"$RESP")" '["detail","v","verdict"]'
check "per-layer detail on the hub socket" "$(jq -c .detail.layers <<<"$RESP")" '{"floor":"clear","classifier":"clear"}'
hasnt "no ref on allow" "$RESP" '"ref"'

BEFORE="$(gf_completions)"
gf_ask floor "notes about ZZALPHA rollout"
check "floor hit (case-insensitive): block" "$RC" 3
check "reason hit:floor" "$REASON" "hit:floor"
jq -r .ref <<<"$RESP" | grep -qE '^gr-[0-9a-f]{32}$' && ok "block carries a gr- ref" || bad "bad ref: $RESP"
hasnt "never names the term" "$(tr '[:upper:]' '[:lower:]' <<<"$RESP")" "zzalpha"
check "floor-only layer made no classifier call" "$(gf_completions)" "$BEFORE"
gf_ask floor "zzalphabet soup"
check "word boundary: a longer word is not a hit" "$RC" 0

gf_ask floor,classifier "ZZSENSITIVE payroll numbers"
check "classifier sensitive: block" "$RC" 3
check "reason hit:classifier" "$REASON" "hit:classifier"
check "layers reported separately" "$(jq -c .detail.layers <<<"$RESP")" '{"floor":"clear","classifier":"hit"}'

echo "== floor OR classifier (gate_decide) =="
DEC="$TMP/dec.txt"
decide() { # decide <text> -> "<verdict> <reason> <completions before> <after>"
    printf '%s' "$1" > "$DEC"
    local b; b="$(gf_completions)"
    bash -c 'source "$1"; gate_policy_load "$2" "$3" || exit 9; gate_decide "$4" "$5"; echo "$GATE_VERDICT $GATE_REASON"' \
        _ "$ROOT/scripts/lib/gate.sh" "$STATE/gate-policy" "$(id -un)" "$DEC" "$CONF/fleet.conf" 2>/dev/null | tail -1
    echo "$b $(gf_completions)"
}
OUT="$(decide 'about zzbravo')"
check "floor hit blocks" "$(head -1 <<<"$OUT")" "block hit:floor"
read -r B A <<<"$(tail -1 <<<"$OUT")"
check "floor hit: classifier never called" "$A" "$B"
OUT="$(decide 'ZZSENSITIVE but no listed term')"
check "floor clear never turns classifier sensitive into allow" "$(head -1 <<<"$OUT")" "block hit:classifier"
OUT="$(decide 'plain words')"
check "both clear: allow" "$(head -1 <<<"$OUT")" "allow "

echo "== the classifier request is the production one =="
printf 'compare this body' > "$TMP/same.txt"
: > "$MS/requests.jsonl"
gf_ask classifier "compare this body"
GATE_BODY="$(jq -c 'select(.path == "/v1/chat/completions") | .body' "$MS/requests.jsonl" | tail -1)"
: > "$MS/requests.jsonl"
LOCAL_MODEL_API=openai ORCH_CLASSIFIER_PROMPT_FILE="$STATE/gate-policy/current/classifier-prompt.md" \
    bash "$ROOT/scripts/orchestrator/classify-sensitivity.sh" --fleet-config "$CONF/fleet.conf" < "$TMP/same.txt" >/dev/null 2>&1
PROD_BODY="$(jq -c 'select(.path == "/v1/chat/completions") | .body' "$MS/requests.jsonl" | tail -1)"
[[ -n "$GATE_BODY" ]] && ok "gate called the classifier" || bad "no gate classifier request"
check "gate request body equals classify-sensitivity's" "$GATE_BODY" "$PROD_BODY"
has "only through fleet_call to the loopback member" "$(jq -r 'select(.path == "/v1/chat/completions") | .path' "$MS/requests.jsonl" | head -1)" "/v1/chat/completions"

# =============================================================================
echo "== framing =="
proto() { # proto <label> <raw request bytes via printf %b>
    local out; out="$(printf '%b' "$2" | gf_raw raw)"
    check "$1: fault:protocol" "$(gf_reason_of "$out")" "fault:protocol"
}
proto "not JSON"           'hello\npayload'
proto "missing v"          '{"op":"eval","layers":["floor"]}\nx'
proto "unknown v"          '{"v":2,"op":"eval","layers":["floor"]}\nx'
proto "v as a string"      '{"v":"1","op":"eval","layers":["floor"]}\nx'
proto "unknown op"         '{"v":1,"op":"explode","layers":["floor"]}\nx'
for op in prompt expansion tool_input tool_result; do
    proto "container op $op on the hub socket" "{\"v\":1,\"op\":\"$op\"}\\nx"
done
for op in push git_text mount_scan rescan; do
    proto "op $op (not yet)" "{\"v\":1,\"op\":\"$op\",\"workspace\":\"w\"}\\nx"
done
proto "extra header field" '{"v":1,"op":"eval","layers":["floor"],"session":"s"}\nx'
proto "bad layers"         '{"v":1,"op":"eval","layers":["floor","floor"]}\nx'
proto "no newline after the header" '{"v":1,"op":"eval","layers":["floor"]}'
OUT="$( { head -c 5000 /dev/zero | tr '\0' 'a'; printf '\nx'; } | gf_raw raw)"
check "header over 4096 bytes: fault:protocol" "$(gf_reason_of "$OUT")" "fault:protocol"
OUT="$(printf '{"v":1,"op":"eval","layers":["floor"]}\nhello' | gf_raw twice)"
check "one answer line per connection" "$(head -1 <<<"$OUT" | jq -r .verdict)" "allow"
check "a second request on the same connection gets nothing" "$(tail -1 <<<"$OUT")" "closed"

echo "== limits and text =="
OUT="$( { printf '{"v":1,"op":"eval","layers":["floor"]}\n'; head -c 5000 /dev/zero | tr '\0' 'b'; } | gf_raw raw)"
check "payload over GATE_MAX_REQUEST: fault:oversize" "$(gf_reason_of "$OUT")" "fault:oversize"
OUT="$(printf '{"v":1,"op":"eval","layers":["floor"]}\nbad \xff\xfe bytes' | gf_raw raw)"
check "invalid UTF-8: fault:non-text" "$(gf_reason_of "$OUT")" "fault:non-text"
OUT="$(printf '{"v":1,"op":"eval","layers":["floor"]}\nnul\x00inside' | gf_raw raw)"
check "NUL byte: fault:non-text" "$(gf_reason_of "$OUT")" "fault:non-text"
gf_ask floor "naïve café — ünïcode is text"
check "valid UTF-8 is text" "$RC" 0

# =============================================================================
echo "== lane2 check =="
LC() { bash -c 'source "$1"; shift; lane2_in_container() { return 1; }; lane2_main "$@"' _ "$ROOT/scripts/hub/lane2" "$@"; }
printf 'GATE_HUB_SOCKET=%s\n' "$SOCK" >> "$CONF/gate.conf"
OUT="$(printf 'nothing listed here' | LC --config-dir "$CONF" check 2>&1)"; R=$?
check "lane2 check allow exits 0" "$R" 0
has "says allow" "$OUT" "  OK  allow"
OUT="$(printf 'zzbravo is in here' | LC --config-dir "$CONF" check --layers floor 2>&1)"; R=$?
check "lane2 check block exits 3" "$R" 3
has "says why, with the ref" "$OUT" " FAIL block: hit:floor (ref gr-"
has "per-layer line" "$OUT" "floor: hit"
hasnt "never prints the term" "$OUT" "zzbravo"
OUT="$(printf 'x' | DEVCONTAINER=true bash "$ROOT/scripts/hub/lane2" --config-dir "$CONF" check 2>&1)"; R=$?
check "lane2 check refuses inside a container" "$R" 4
has "says run on the hub" "$OUT" "run on the hub"

# =============================================================================
echo "== shipped units =="
UT="$TMP/units"; mkdir -p "$UT"
for f in "$ROOT"/scripts/hub/units/gate-*; do
    sed -e "s|@LANE2_CODE@|/opt/lane2/c|g" -e "s|@LANE2_CONFIG@|/etc/lane2|g" -e "s|@LANE2_STATE@|/var/lib/lane2|g" "$f" > "$UT/${f##*/}"
done
LINT="$(bash -c 'source "$1"; for f in "$2"/*; do lane2_lint_unit "$f"; done' _ "$ROOT/scripts/lib/lane2.sh" "$UT")"
check "gate units pass the install lint" "$LINT" ""
S="$(cat "$UT/gate-hub.socket")"; V="$(cat "$UT/gate-hub@.service")"
has "socket activation, one handler per connection" "$S" "Accept=yes"
has "invalid deadlines stop the gate" "$S" "ExecStartPre=/opt/lane2/c/scripts/hub/gate-handler --check-config /etc/lane2"
for k in "User=lane2-gate" "PrivateTmp=yes" "RuntimeDirectoryMode=0700" "NoNewPrivileges=yes" "ProtectSystem=strict" "LimitCORE=0" "StandardInput=socket"; do
    has "handler unit: $k" "$V" "$k"
done
bash -c 'source "$1"; lane2_boot_allowed gate-hub.socket' _ "$ROOT/scripts/lib/lane2.sh" && ok "gate-hub.socket is on the boot allowlist" || bad "gate-hub.socket not boot-allowed"

echo "== no sanitiser on the gate path (FR-11) =="
SAN="$(grep -rlE 'sanitise\.sh|ORCH_SANITISER|ORCH_SANITISE_ON_FAIL' "$ROOT/scripts/hub" "$ROOT"/scripts/lib/gate*.sh 2>/dev/null || true)"
check "nothing in scripts/hub or the gate libs sources or calls the sanitiser" "$SAN" ""
hasnt "the gate answers allow or block only" "$(grep -oE 'verdict: "[a-z]+"' "$ROOT/scripts/hub/gate-handler" | sort -u | tr '\n' ' ')" "edit"

echo
echo "gate-protocol: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
