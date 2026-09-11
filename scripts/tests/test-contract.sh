#!/usr/bin/env bash
# test-contract.sh — the disclosure boundary (S3, issue #63).
#
# This is the control that lets Claude coordinate work it is never allowed to
# see. The invariant: implementation artifacts produced by the local executor
# never cross to the frontier tier — only a DECLARED INTERFACE does.
#
# The distinction these tests exist to hold is positive disclosure vs
# sanitisation. A filter fails OPEN: whatever the rewrite misses crosses. A
# contract fails CLOSED: undeclared content was never in the message, so there is
# nothing to miss. Every test below is a way of asking "did anything undeclared
# get out?"
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok()   { echo "  OK  $1"; ((PASS++)) || true; }
bad()  { echo " FAIL $1"; ((FAIL++)) || true; }
check(){ if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }
contains(){ if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1 (got '$2', want substring '$3')"; fi; }
lacks(){ if [[ "$2" != *"$3"* ]]; then ok "$1"; else bad "$1 (must not contain '$3', got '$2')"; fi; }
want() { if [[ "$1" == 0 ]]; then ok "$2"; else bad "$2"; fi; }
wantnot() { if [[ "$1" != 0 ]]; then ok "$2"; else bad "$2"; fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
H="$TMP/home"; mkdir -p "$H/.config/orchestrator" "$H/srv/customer/acme"
export HOME="$H"
export ORCH_LOG="$TMP/log.jsonl"

CONF="$TMP/ctp.conf"
printf 'CTP_SECRET_PATHS=%s/.ssh %s/.ssh/**\n' "$H" "$H" > "$CONF"
export CTP_BRIDGE_CONF="$CONF"
export CTP_BRIDGE_STATE="$TMP/state"

# shellcheck source=scripts/lib/contract.sh disable=SC1091
source "$ROOT/scripts/lib/contract.sh"
contract_init

ART="$H/srv/customer/acme/scoring/score_account.sh"
mkdir -p "$(dirname "$ART")"
cat > "$ART" <<'EOF'
#!/usr/bin/env bash
# ACME proprietary scoring — weights derived from the Northwind ledger
WEIGHT_LEDGER=0.71
EOF

# ===========================================================================
echo "== handles (E9 / R16) =="
h1="$(contract_handle "$ART")"
h2="$(contract_handle "$H/srv/customer/acme/other.sh")"
want "$([[ "$h1" =~ ^[0-9a-f]{16}$ ]] && echo 0 || echo 1)" "handle is a 16-hex opaque id"
wantnot "$([[ "$h1" == "$h2" ]] && echo 0 || echo 1)" "two artifacts get different handles"
lacks "handle carries no path"        "$h1" "/"
lacks "handle carries no client name" "$h1" acme
# R16: not sequential — a sequential handle would publish how many artifacts
# exist and how fast they are being produced.
wantnot "$([[ "$h1" == h1 || "$h1" == 1 || "$h1" == "0000000000000001" ]] && echo 0 || echo 1)" \
    "handle is not sequential"
# ...and not derivable from the path, so nobody who can guess a path can guess
# the handle for it.
h1b="$(ORCH_HANDLE_MAP="$TMP/other-map.tsv" contract_handle "$ART")"
wantnot "$([[ "$h1b" == "$h1" ]] && echo 0 || echo 1)" "handle is not derived from the path"

check "handle resolves locally" "$(contract_resolve "$h1")" "$ART"
check "unknown handle does not resolve" "$(contract_resolve deadbeefdeadbeef 2>/dev/null; echo "rc=$?")" "rc=1"
# Resolution is a local act. Doing it on behalf of a cloud-bound caller would
# hand over the very path the handle exists to hide.
check "resolution refused for a cloud caller" \
    "$(ORCH_CALLER=cloud contract_resolve "$h1" 2>/dev/null; echo "rc=$?")" "rc=2"

check "map is owner-only" "$(stat -c '%a' "$CONTRACT_MAP" 2>/dev/null)" 600
# The map is a list of real internal paths, so it is sensitive by construction.
# It lives under the always-guarded orchestrator config directory.
guard_stack_load hook
guard_stack_classify_path "$CONTRACT_MAP"
case "$GUARD_STACK_VERDICT" in deny:*) ok "map is C1-guarded from Claude" ;; *) bad "map is C1-guarded from Claude (got '$GUARD_STACK_VERDICT')" ;; esac

# ===========================================================================
echo "== validation: what may be declared =="
GOOD="$(jq -cn --arg h "$h1" '{
  name:"score_account", handle:$h,
  summary:"Scores one account and prints a number",
  invocation:"score_account <handle> --account-id ID",
  inputs:[{name:"account_id", type:"string", required:true}],
  outputs:[{name:"score", type:"number"}],
  exit_codes:[{code:0, meaning:"ok"},{code:2, meaning:"unknown account"}]}')"

contract_validate "$GOOD"; check "a well-formed contract validates" "$CONTRACT_ERR" ""

contract_validate "$(jq -cn '{handle:"aaaaaaaaaaaaaaaa", invocation:"x"}')"
contains "missing name rejected" "$CONTRACT_ERR" "name"

contract_validate "$(jq -cn --arg h "$h1" '{name:"x", handle:$h}')"
contains "missing invocation rejected" "$CONTRACT_ERR" "invocation"

contract_validate 'not json at all'
contains "non-JSON rejected" "$CONTRACT_ERR" "JSON"

contract_validate "$(jq -cn '{name:"x", handle:"nope", invocation:"x"}')"
contains "bad handle rejected" "$CONTRACT_ERR" "handle"

# A path is itself disclosure: it leaks org structure, client identity and
# codenames even when the file contents never cross.
contract_validate "$(jq -cn --arg h "$h1" --arg p "$ART" \
    '{name:"x", handle:$h, invocation:("bash " + $p)}')"
contains "path in invocation rejected" "$CONTRACT_ERR" "path"

contract_validate "$(jq -cn --arg h "$h1" \
    '{name:"x", handle:$h, invocation:"x", summary:"reads /srv/customer/acme/notes"}')"
contains "path in summary rejected" "$CONTRACT_ERR" "path"

contract_validate "$(jq -cn --arg h "$h1" \
    '{name:"x", handle:$h, invocation:"x", inputs:[{name:"cfg", type:"~/.config/acme/x"}]}')"
contains "path nested in inputs rejected" "$CONTRACT_ERR" "path"

# ===========================================================================
echo "== positive disclosure: only declared fields cross =="
SNEAKY="$(printf '%s' "$GOOD" | jq -c '. + {notes:"weights derived from the Northwind ledger", debug_log:"read /srv/customer/acme/scoring"}')"
PROJ="$(contract_project "$SNEAKY")"
lacks "undeclared field does not cross"   "$PROJ" "Northwind"
lacks "undeclared field path not crossed" "$PROJ" "/srv/customer"
contains "declared field survives"        "$PROJ" "score_account"
contains "declared handle survives"       "$PROJ" "$h1"

# ===========================================================================
echo "== the disclosure pipeline =="
# Stand-ins for the two judgement controls, so the tests drive the pipeline
# rather than a model. Both are replaced, not stubbed out: the real ones have the
# same contract.
APPROVE=yes
# shellcheck disable=SC2317  # called indirectly, from contract_disclose
# shellcheck disable=SC2317  # called indirectly, from contract_disclose
contract_approve() { CONTRACT_APPROVED_TEXT="$1"; [[ "$APPROVE" == yes ]]; }
BYPASS=no
# shellcheck disable=SC2317  # called indirectly, from contract_disclose
contract_bypass_prompt() { [[ "$BYPASS" == yes ]]; }

SAN_UP="$TMP/san-up.sh";   printf '#!/usr/bin/env bash\ntr "[:lower:]" "[:upper:]"\n' > "$SAN_UP"; chmod +x "$SAN_UP"
SAN_FAIL="$TMP/san-fail.sh"; printf '#!/usr/bin/env bash\nexit 1\n' > "$SAN_FAIL"; chmod +x "$SAN_FAIL"
SAN_PASS="$TMP/san-pass.sh"; printf '#!/usr/bin/env bash\ncat\n' > "$SAN_PASS"; chmod +x "$SAN_PASS"

FLOOR_LIST="$TMP/terms.txt"; echo "northwind" > "$FLOOR_LIST"
export ORCH_TERM_LIST="$FLOOR_LIST"

# --- happy path -------------------------------------------------------------
APPROVE=yes
ORCH_SANITISER="$SAN_UP" contract_disclose "$GOOD"
check "clean contract crosses"        "$CONTRACT_STATUS" disclosed
contains "sanitised text is what crossed" "$CONTRACT_OUT" "SCORE_ACCOUNT"
check "the owner approved exactly what crossed" "$CONTRACT_APPROVED_TEXT" "$CONTRACT_OUT"

# --- the owner is the gate, every time --------------------------------------
APPROVE=no
ORCH_SANITISER="$SAN_UP" contract_disclose "$GOOD"
check "refused approval blocks"       "$CONTRACT_STATUS" refused
check "refused approval discloses nothing" "$CONTRACT_OUT" ""

# Approving one contract does not approve the next: the gate is per contract.
APPROVE=yes; ORCH_SANITISER="$SAN_UP" contract_disclose "$GOOD"
check "first contract disclosed"      "$CONTRACT_STATUS" disclosed
APPROVE=no;  ORCH_SANITISER="$SAN_UP" contract_disclose "$GOOD"
check "second contract asked again"   "$CONTRACT_STATUS" refused

# No approval surface at all (no TTY, nothing to ask) fails closed.
APPROVE=yes
unset -f contract_approve
ORCH_SANITISER="$SAN_UP" contract_disclose "$GOOD" 2>/dev/null
check "no TTY means no approval means no disclosure" "$CONTRACT_STATUS" refused
# shellcheck disable=SC2317  # called indirectly, from contract_disclose
contract_approve() { CONTRACT_APPROVED_TEXT="$1"; [[ "$APPROVE" == yes ]]; }

# --- R2: the egress term floor is not bypassable -----------------------------
TERMED="$(printf '%s' "$GOOD" | jq -c '.summary = "scores one account against the northwind model"')"
APPROVE=yes; BYPASS=yes
ORCH_SANITISER="$SAN_UP" contract_disclose "$TERMED"
check "a listed term blocks the contract" "$CONTRACT_STATUS" floor
check "floor block discloses nothing"     "$CONTRACT_OUT"    ""
# The owner may override a fallible LLM control. Nobody overrides the
# deterministic one — that is the whole point of having it.
ORCH_SANITISER="$SAN_FAIL" contract_disclose "$TERMED"
check "bypass does not lift the floor"    "$CONTRACT_STATUS" floor

# A sanitiser that INTRODUCES a listed term must not slip through: the floor is
# checked on the text that actually crosses, not only the draft.
SAN_ADD="$TMP/san-add.sh"
cat > "$SAN_ADD" <<'EOF'
#!/usr/bin/env bash
cat; echo "northwind"
EOF
chmod +x "$SAN_ADD"
APPROVE=yes; BYPASS=no
ORCH_SANITISER="$SAN_ADD" contract_disclose "$GOOD"
check "floor checks the final text too"   "$CONTRACT_STATUS" floor

# --- R3: sanitiser failure blocks by default ---------------------------------
BYPASS=no; APPROVE=yes
ORCH_SANITISER="$SAN_FAIL" contract_disclose "$GOOD"
check "sanitiser failure blocks"          "$CONTRACT_STATUS" blocked
check "sanitiser failure discloses nothing" "$CONTRACT_OUT"   ""

# The bypass exists so a flaky local model cannot halt work permanently. It is
# per instance — there is no configuration that leaves it on.
BYPASS=yes; APPROVE=yes
ORCH_SANITISER="$SAN_FAIL" contract_disclose "$GOOD"
check "owner may bypass the sanitiser, once" "$CONTRACT_STATUS" disclosed
contains "bypassed text is the raw contract" "$CONTRACT_OUT" "score_account"
check "the bypass is logged" \
    "$(jq -rs '[.[] | select(.event=="disclosure" and .sanitiser=="bypassed")] | length' "$ORCH_LOG")" 1
# ...and the owner still approves it afterwards, seeing the unsanitised text.
BYPASS=yes; APPROVE=no
ORCH_SANITISER="$SAN_FAIL" contract_disclose "$GOOD"
check "bypass does not skip approval"     "$CONTRACT_STATUS" refused

# No sanitiser configured at all is not a quiet pass.
BYPASS=no; APPROVE=yes
ORCH_SANITISER="" contract_disclose "$GOOD"
check "no sanitiser configured blocks"    "$CONTRACT_STATUS" blocked

# --- the log says what happened, without saying what it was ------------------
LOGTXT="$(cat "$ORCH_LOG")"
lacks "log has no artifact path"     "$LOGTXT" "/srv/customer"
lacks "log has no contract body"     "$LOGTXT" "score_account"
lacks "log has no listed term"       "$LOGTXT" northwind

# ===========================================================================
echo "== R11: a stub cloud-bound caller receives only the interface =="
STUB_IN="$TMP/stub-received.txt"
APPROVE=yes; BYPASS=no
ORCH_SANITISER="$SAN_PASS" contract_disclose "$GOOD"
printf '%s' "$CONTRACT_OUT" > "$STUB_IN"
RECEIVED="$(cat "$STUB_IN")"
lacks "stub receives no artifact contents" "$RECEIVED" "WEIGHT_LEDGER"
lacks "stub receives no codename"          "$RECEIVED" "Northwind"
lacks "stub receives no filesystem path"   "$RECEIVED" "/srv/"
lacks "stub receives no home path"         "$RECEIVED" "$H"
want "$([[ "$RECEIVED" =~ /[A-Za-z0-9_.-]+/ ]] && echo 1 || echo 0)" "stub receives no path-shaped string at all"
contains "stub receives the handle"        "$RECEIVED" "$h1"
check "stub receives valid JSON"           "$(printf '%s' "$RECEIVED" | jq -e 'type=="object"' >/dev/null 2>&1; echo $?)" 0
# R4: a status, never raw diagnostics.
lacks "stub receives no stderr text"       "$RECEIVED" "Traceback"

echo
echo "contract: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
