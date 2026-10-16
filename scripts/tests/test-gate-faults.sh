#!/usr/bin/env bash
# `cond && ok … || bad …` is safe in this file: ok and bad always return 0.
# shellcheck disable=SC2015
# test-gate-faults.sh — every gate- and classifier-side FR-10 case blocks, the
# deadlines are validated, and gate_client fails closed (SP1a story 2.3, #106;
# AD-3, FR-10, SM-1).
# tier: ci — real handler behind a real unix socket; the classifier is the
# llama-server mock; synthetic terms only.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok()   { echo "  OK  $1"; ((PASS++)) || true; }
bad()  { echo " FAIL $1"; ((FAIL++)) || true; }
check(){ if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }

# shellcheck source=/dev/null
source "$ROOT/scripts/tests/gate-fixture.sh"
gf_setup
[[ -S "$SOCK" ]] || { echo " FAIL gate socket did not come up"; exit 1; }

blocks() { # blocks <label> <expected reason> [layers] [text]
    gf_ask "${3:-floor,classifier}" "${4:-plain text to classify}"
    check "$1: block" "$RC" 3
    check "$1: $2" "$REASON" "$2"
}

# =============================================================================
echo "== classifier-side faults =="
gf_mode loading;       blocks "classifier loading (503)" fault:classifier
gf_mode health500;     blocks "classifier error (500 on health)" fault:classifier
gf_mode malformed;     blocks "malformed answer" fault:classifier
gf_mode truncated;     blocks "partial / truncated answer" fault:classifier
gf_mode ok; printf 'not json at all' > "$MS/content"
blocks "unparseable answer" fault:classifier
printf '{"verdict":"maybe"}' > "$MS/content"
blocks "answer outside the enum" fault:classifier
rm -f "$MS/content"
gf_mode toolong;       blocks "content over the classifier context (interim, until 2.7)" fault:oversize
gf_mode oversize;      blocks "server exceed_context_size_error" fault:oversize
gf_mode ok
DEAD="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
gf_conf "FLEET_CLASSIFIER_ENDPOINT=http://127.0.0.1:$DEAD"
blocks "classifier unavailable" fault:classifier
gf_conf "FLEET_CLASSIFIER_ENDPOINT=http://192.0.2.10:8080"
blocks "non-local classifier endpoint" fault:classifier
gf_conf

echo "== deadline =="
gf_conf "GATE_DEADLINE=2"; gf_mode timeout
START=$(date +%s); blocks "gate deadline exceeded" fault:timeout; END=$(date +%s)
(( END - START < 6 )) && ok "answered before the caller's deadline ($((END - START)) s)" || bad "took $((END - START)) s"
gf_mode ok; gf_conf

echo "== policy faults =="
P="$STATE/gate-policy/current"
mv "$P/term-list.txt" "$TMP/tl"; blocks "missing term list" fault:policy; mv "$TMP/tl" "$P/term-list.txt"
chmod 000 "$P/term-list.txt"; blocks "unreadable term list" fault:policy; chmod 644 "$P/term-list.txt"
cp "$P/term-list.txt" "$TMP/tl"; : > "$P/term-list.txt"; blocks "empty term list" fault:policy; cp "$TMP/tl" "$P/term-list.txt"
mv "$P/classifier-prompt.md" "$TMP/cp"; blocks "missing classifier prompt" fault:policy; mv "$TMP/cp" "$P/classifier-prompt.md"
gf_conf "FLEET_CLASSIFIER_SHA256="; blocks "policy_version input missing (model checksum)" fault:policy
gf_conf
gf_ask floor,classifier "all restored"; check "restored policy allows again" "$RC" 0

echo "== handler faults =="
gf_conf "GATE_DEADLINE=29"; blocks "invalid deadlines at request time" fault:config; gf_conf
OUT="$(printf '{"v":1,"op":"eval","layers":["floor"]}\nx' | bash "$GF_HANDLER" "$CONF" 2>/dev/null)"
check "a peer that is not a socket (unknown uid): block" "$(jq -r .verdict <<<"$OUT")" block
check "  reason fault:peer" "$(jq -r .detail.reason <<<"$OUT")" "fault:peer"
PA() { bash -c 'source "$1"; gate_load "$2" >/dev/null; gate_peer_allowed "$3"' _ "$GF_HANDLER" "$CONF" "$1"; }
PA "$(id -u)" && ok "the operator is an allowed peer" || bad "operator refused"
PA 0 && bad "root accepted as a peer" || ok "root is not an allowed peer"
PA 65534 && bad "nobody accepted as a peer" || ok "another account is refused"
# Work that dies without writing a result: the child is a script that crashes.
CRASH="$TMP/crash.sh"; printf 'exit 1\n' > "$CRASH"
OUT="$(printf '{"v":1,"op":"eval","layers":["floor"]}\nx' | \
    bash -c 'source "$1"; gate_peer_uid() { id -u; }; GATE_HANDLER="$3"; gate_serve "$2"' _ "$GF_HANDLER" "$CONF" "$CRASH" 2>/dev/null)"
check "work crashes without an answer: fault:internal block" "$(jq -r '"\(.verdict) \(.detail.reason)"' <<<"$OUT")" "block fault:internal"

echo "== deadline validation at gate start =="
cfg() { gf_conf "$@"; bash "$GF_HANDLER" --check-config "$CONF" >/dev/null 2>&1; echo $?; }
check "valid deadlines start" "$(cfg)" 0
check "gate deadline not below shim timeout: refused" "$(cfg GATE_DEADLINE=28)" 4
check "margin under 2 s: refused" "$(cfg GATE_DEADLINE=27)" 4
check "shim timeout too close to the hook: refused" "$(cfg GATE_SHIM_TIMEOUT=29)" 4
check "hook timeout other than 30: refused" "$(cfg GATE_HOOK_TIMEOUT=60)" 4
check "non-numeric deadline: refused" "$(cfg GATE_DEADLINE=soon)" 4
check "zero GATE_MAX_REQUEST: refused" "$(cfg GATE_MAX_REQUEST=0)" 4
gf_conf

# =============================================================================
echo "== gate_client fails closed =="
FAKE="$TMP/fake.sock"; FAKEPID=""
fake() { # fake <shell command answering on stdout> [raw] — a server that answers as told
    [[ -n "$FAKEPID" ]] && kill "$FAKEPID" 2>/dev/null
    rm -f "$FAKE"
    local cmd="cat >/dev/null; $1"; [[ "${2:-}" == raw ]] && cmd="$1"
    python3 "$ROOT/scripts/tests/accept-socket.py" "$FAKE" bash -c "$cmd" & FAKEPID=$!
    GF_PIDS+=("$FAKEPID")
    local i; for (( i = 0; i < 50; i++ )); do [[ -S "$FAKE" ]] && break; sleep 0.1; done
}
cl() { local rc=0; gate_client "$FAKE" "${1:-5}" '{"v":1,"op":"eval","layers":["floor"]}' < <(printf x) || rc=$?; echo "$rc"; }
fake 'printf "{\"v\":1,\"verdict\":\"allow\"}\n"';           check "well-formed allow: 0" "$(cl)" 0
fake 'true';                                                  check "crash / no answer: block" "$(cl)" 3
fake 'printf "\n"';                                           check "empty line: block" "$(cl)" 3
fake 'printf "not json\n"';                                   check "malformed: block" "$(cl)" 3
fake 'printf "{\"v\":2,\"verdict\":\"allow\"}\n"';           check "unknown v: block" "$(cl)" 3
fake 'printf "{\"v\":\"1\",\"verdict\":\"allow\"}\n"';       check "v as a string: block" "$(cl)" 3
fake 'printf "{\"v\":1,\"verdict\":\"allow\",\"ref\":\"x\"}\n"'; check "allow with a ref: block" "$(cl)" 3
fake 'printf "{\"v\":1,\"verdict\":\"allow\"}"';             check "no newline (partial): block" "$(cl)" 3
fake 'printf "{\"v\":1,\"verdict\":\"allow\"}\nextra\n"';    check "trailing data: block" "$(cl)" 3
# The command runs in the fake server's shell, so it expands there.
# shellcheck disable=SC2016
fake 'printf "{\"v\":1,\"verdict\":\"allow\",\"detail\":\"%s\"}\n" "$(head -c 5000 /dev/zero | tr "\0" a)"'
check "oversized answer: block" "$(cl)" 3
fake 'sleep 8; printf "{\"v\":1,\"verdict\":\"allow\"}\n"';  check "answer after the deadline: block" "$(cl 2)" 3
fake 'printf "{\"v\":1,\"verdict\":\"block\",\"ref\":\"gr-0\"}\n"'; check "block: 3" "$(cl)" 3
rm -f "$TMP/none.sock"
RC=0; gate_client "$TMP/none.sock" 5 '{"v":1,"op":"eval","layers":["floor"]}' < <(printf x) || RC=$?
check "socket missing: block" "$RC" 3
RC=0; gate_client "$SOCK" 0 '{"v":1}' < <(printf x) || RC=$?
check "bad deadline: local fault (4)" "$RC" 4
SEEN="$TMP/seen"
fake "cat > '$SEEN'; printf '{\"v\":1,\"verdict\":\"block\",\"ref\":\"gr-0\"}\n'" raw
head -c 300000 /dev/zero | tr '\0' 'q' > "$TMP/big"
gate_client "$FAKE" 5 '{"v":1,"op":"eval","layers":["floor"]}' < "$TMP/big" >/dev/null; sleep 0.3
check "client never truncates its input (300 kB sent whole)" "$(( $(wc -c < "$SEEN") - $(head -1 "$SEEN" | wc -c) ))" 300000

echo
echo "gate-faults: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
