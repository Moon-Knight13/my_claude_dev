#!/usr/bin/env bash
# test-ctp-bridge.sh — refusal and decision tests for the ctp tool bridge.
#
# Three groups: the shared guard (pure functions), the wrapper (with a mocked
# docker so nothing real runs), and the PreToolUse hook (fed tool-call JSON).
# The point of these tests is the REFUSALS: the bridge is only as good as what it
# will not do.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok()   { echo "  OK  $1"; ((PASS++)) || true; }
bad()  { echo " FAIL $1"; ((FAIL++)) || true; }
check(){ if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

CONF="$TMP/.ctp-bridge.conf"
cat > "$CONF" <<EOF
CTP_ALLOWED_TARGET=trainbox
CTP_ALLOWED_VERBS=deploy deploy-role
CTP_CONTAINER=catapult-tester
CTP_SECRET_PATHS=/var/tmp/vlt_pf ~/.ssh/id_* ~/.zsh_history ~/.bash_history **/.env
EOF

# ============================================================================
echo "== guard (pure classification) =="
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/ctp-guard.sh"
ctp_load_config "$CONF"
export CTP_TARGET_HOME="/home/tester"

cls() { ctp_classify "$@" >/dev/null 2>&1 && echo confirm || echo refuse; }
check "deploy allowed target -> confirm"      "$(cls host deploy trainbox)"      confirm
check "deploy-role allowed target -> confirm" "$(cls host deploy-role trainbox)" confirm
check "deploy other target -> refuse"         "$(cls host deploy otherbox)"      refuse
check "glob in target -> refuse"              "$(cls host deploy 'train*')"      refuse
check "deploy no target -> refuse"            "$(cls host deploy)"               refuse
check "list -> refuse (not reachable)"        "$(cls host list)"                 refuse
check "vars -> refuse (not reachable)"        "$(cls host vars trainbox)"        refuse
check "redeploy -> refuse"                    "$(cls host redeploy trainbox)"    refuse
check "remove -> refuse"                      "$(cls host remove trainbox)"      refuse
check "secrets -> refuse"                     "$(cls secrets edit)"              refuse
check "make -> refuse"                        "$(cls make start)"               refuse
check "unknown verb -> refuse"                "$(cls frobnicate all)"            refuse

sec() { ctp_is_secret_path "$1" && echo secret || echo ok; }
check "vault file is secret"        "$(sec /var/tmp/vlt_pf)"            secret
check "ssh key is secret"           "$(sec /home/tester/.ssh/id_ed25519)" secret
check ".env anywhere is secret"     "$(sec /workspace/app/.env)"       secret
check "zsh_history is secret"       "$(sec /home/tester/.zsh_history)"  secret
check ".env.example is NOT secret"  "$(sec /workspace/.env.example)"   ok
check "ssh config is NOT secret"    "$(sec /home/tester/.ssh/config)"  ok
check "README is NOT secret"        "$(sec /workspace/README.md)"      ok

# ============================================================================
echo "== wrapper (mocked docker) =="
BIN="$TMP/bin"; mkdir -p "$BIN"
# Mock docker: behaviour tuned by env the MOCK reads (not the wrapper's gates).
cat > "$BIN/docker" <<'MOCK'
#!/usr/bin/env bash
case "$1 $2" in
  "inspect -f")  echo true; exit 0 ;;   # container running
esac
if [[ "$1" == "exec" ]]; then
  shift
  # drop -i and container name
  [[ "$1" == "-i" ]] && shift
  shift
  if [[ "$1" == "test" && "$2" == "-e" ]]; then
    [[ "${MOCK_VAULT_LOCKED:-0}" == "1" ]] && exit 1 || exit 0
  fi
  if [[ "$1" == "pgrep" || "$*" == *pgrep* ]]; then
    [[ "${MOCK_BUSY:-0}" == "1" ]] && exit 0 || exit 1
  fi
  # the real run: echo the ctp argv so a test can inspect it
  echo "RAN: $*"
  exit "${MOCK_RUN_RC:-0}"
fi
exit 0
MOCK
chmod +x "$BIN/docker"

run_wrap() { # run_wrap <stdin> -- args...   ; prints nothing, sets RC
    local input="$1"; shift; [[ "$1" == "--" ]] && shift
    PATH="$BIN:$PATH" CTP_BRIDGE_CONF="$CONF" CTP_BRIDGE_LOG="$TMP/count.log" \
        bash "$ROOT/scripts/ctp-bridge.sh" "$@" <<<"$input" >/dev/null 2>&1
    RC=$?
}

run_wrap "" -- host deploy trainbox;  check "non-interactive deploy refused (no auto-yes)" "$RC" 5
ASSUME_YES=1 PATH="$BIN:$PATH" CTP_BRIDGE_CONF="$CONF" bash "$ROOT/scripts/ctp-bridge.sh" host deploy trainbox </dev/null >/dev/null 2>&1
check "ASSUME_YES refused" "$?" 5
run_wrap "" -- secrets edit;          check "refused verb exits before docker (3)" "$RC" 3
run_wrap "" -- host deploy otherbox;  check "wrong target refused (3)" "$RC" 3
MOCK_VAULT_LOCKED=1 PATH="$BIN:$PATH" CTP_BRIDGE_CONF="$CONF" bash "$ROOT/scripts/ctp-bridge.sh" host deploy trainbox </dev/null >/dev/null 2>&1
check "vault locked refused (4)" "$?" 4
MOCK_BUSY=1 PATH="$BIN:$PATH" CTP_BRIDGE_CONF="$CONF" bash "$ROOT/scripts/ctp-bridge.sh" host deploy trainbox </dev/null >/dev/null 2>&1
check "busy refused (4)" "$?" 4
PATH="$BIN:$PATH" CTP_BRIDGE_CONF="$TMP/nope.conf" bash "$ROOT/scripts/ctp-bridge.sh" host deploy trainbox </dev/null >/dev/null 2>&1
check "missing config refused (2)" "$?" 2

# Run path needs a tty (the gate refuses non-interactive by design). Use script(1)
# to allocate one; skip honestly if unavailable.
if command -v script >/dev/null 2>&1; then
    rm -f "$TMP/count.log"
    script -qec "PATH='$BIN:$PATH' CTP_BRIDGE_CONF='$CONF' CTP_BRIDGE_LOG='$TMP/count.log' bash '$ROOT/scripts/ctp-bridge.sh' host deploy-role trainbox" /dev/null <<<"y" >"$TMP/run.out" 2>&1
    # The mock echoes the full docker-exec argv; the ctp args must arrive as
    # trailing positional params (…_ host deploy-role trainbox), never a string.
    if grep -Fq '_ host deploy-role trainbox' "$TMP/run.out"; then
        ok "confirm 'y' runs the exact positional argv"
    else bad "confirm 'y' runs the exact positional argv ($(grep RAN: "$TMP/run.out" | head -1))"; fi
    if [[ -f "$TMP/count.log" ]] && grep -q "host_deploy-role" "$TMP/count.log" && ! grep -q "trainbox" "$TMP/count.log"; then
        ok "count log records verb+outcome, not the target"
    else bad "count log records verb+outcome, not the target"; fi
else
    echo "  --  script(1) unavailable; skipping run-path tests"
fi

# ============================================================================
echo "== hook (decision on tool-call JSON) =="
HOOK="$ROOT/.claude/hooks/pretooluse-ctp.sh"
if ! command -v jq >/dev/null 2>&1; then
    echo "  --  jq unavailable; skipping hook tests"
else
decide() { # decide <json> -> prints allow|deny|ask|none
    local out
    out="$(CTP_BRIDGE_CONF="$CONF" CTP_TARGET_USER=tester CTP_TARGET_HOME=/home/tester \
        HOME=/home/tester bash "$HOOK" <<<"$1" 2>/dev/null)"
    if [[ -z "$out" ]]; then echo none
    else printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null || echo parse-error
    fi
}
read_json()  { printf '{"tool_name":"Read","tool_input":{"file_path":"%s"}}' "$1"; }
bash_json()  { printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(jq -Rn --arg c "$1" '$c')"; }

check "Read vault file -> deny"           "$(decide "$(read_json /var/tmp/vlt_pf)")"                 deny
check "Read ssh key -> deny"              "$(decide "$(read_json /home/tester/.ssh/id_ed25519)")"    deny
check "Read normal file -> none"          "$(decide "$(read_json /workspace/README.md)")"            none
check "Bash cat vault -> deny"            "$(decide "$(bash_json 'cat /var/tmp/vlt_pf')")"           deny
check "Bash cat ssh key (~) -> deny"      "$(decide "$(bash_json 'cat ~/.ssh/id_ed25519')")"        deny
check "Bash docker exec bypass -> deny"   "$(decide "$(bash_json 'docker exec catapult-tester zsh -c ctp')")" deny
check "Bash bare ctp -> deny"             "$(decide "$(bash_json 'ctp host deploy trainbox')")"      deny
check "Bash make start -> deny"           "$(decide "$(bash_json 'make start')")"                    deny
check "Bash wrapper allowed -> ask"       "$(decide "$(bash_json "bash $ROOT/scripts/ctp-bridge.sh host deploy trainbox")")" ask
check "Bash wrapper refused verb -> deny" "$(decide "$(bash_json "bash $ROOT/scripts/ctp-bridge.sh host remove trainbox")")" deny
check "env cannot override config -> deny" "$(decide "$(bash_json "CTP_ALLOWED_TARGET=evil bash $ROOT/scripts/ctp-bridge.sh host deploy evil")")" deny
check "prose mentioning ctp -> none"      "$(decide "$(bash_json 'echo use ctp later to deploy')")"  none
check "unrelated bash -> none"            "$(decide "$(bash_json 'ls -la /workspace')")"             none
fi

# ============================================================================
echo ""
echo "Result: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
