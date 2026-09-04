#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2034,SC2016  # A&&B||C ok/bad idiom (ok never fails); config vars used via sourced guard; SC2016: single-quoted $( ) in test payloads is deliberately literal
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
CTP_ALLOWED_TARGET=trainbox_t02
CTP_ALLOWED_TEAM=t02
CTP_ALLOWED_VERBS=deploy deploy-role
CTP_CONTAINER=catapult-tester
CTP_PROJECT_DIR=/srv/inventories/dcm
CTP_SECRET_PATHS=/var/tmp/vlt_pf ~/.ssh/id_* ~/.zsh_history ~/.bash_history **/.env
CTP_PII_PATHS=~/org-data/** ~/cases/*.csv /srv/customer/** **/customer-list.csv
EOF

# ============================================================================
echo "== guard (pure classification) =="
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/ctp-guard.sh"
ctp_load_config "$CONF"
export CTP_TARGET_HOME="/home/tester"

cls() { ctp_classify "$@" >/dev/null 2>&1 && echo confirm || echo refuse; }
clsc() { ctp_classify "$@" 2>/dev/null | awk '{print $2}'; }   # the class token
check "deploy allowed box -> confirm"         "$(cls host deploy trainbox_t02)"      confirm
check "deploy-role allowed box -> confirm"    "$(cls host deploy-role trainbox_t02)" confirm
check "  ...class is mutating"                "$(clsc host deploy trainbox_t02)"     mutating
check "deploy other box (right team) -> refuse" "$(cls host deploy otherbox_t02)"    refuse
check "deploy right box WRONG TEAM -> refuse"   "$(cls host deploy trainbox_t05)"    refuse
check "deploy bare name (no team) -> refuse"    "$(cls host deploy trainbox)"        refuse
check "glob in target -> refuse"              "$(cls host deploy 'trainbox_t0*')"    refuse
check "deploy no target -> refuse"            "$(cls host deploy)"                   refuse
check "list <box> -> confirm (read)"          "$(cls host list trainbox_t02)"        confirm
check "  ...class is read"                    "$(clsc host list trainbox_t02)"       read
check "list any box (read, not team-gated)"   "$(cls host list otherbox_t05)"        confirm
check "list all -> refuse (no bulk dump)"     "$(cls host list all)"                 refuse
check "list no target -> refuse"              "$(cls host list)"                     refuse
check "list glob -> refuse"                   "$(cls host list 'train*')"            refuse
check "update-inventory -> confirm"           "$(cls project update-inventory)"      confirm
check "  ...class is inventory"               "$(clsc project update-inventory)"     inventory
check "project other subverb -> refuse"       "$(cls project nuke)"                  refuse
check "vars -> refuse (streams detail)"       "$(cls host vars trainbox_t02)"        refuse
check "redeploy -> refuse"                    "$(cls host redeploy trainbox_t02)"    refuse
check "remove -> refuse"                      "$(cls host remove trainbox_t02)"      refuse
check "secrets -> refuse"                     "$(cls secrets edit)"                  refuse
check "make -> refuse"                        "$(cls make start)"                    refuse
check "unknown verb -> refuse"                "$(cls frobnicate all)"                refuse
check "deploy with extra arg -> refuse"       "$(cls host deploy trainbox_t02 --danger)" refuse
check "list with extra arg -> refuse"         "$(cls host list trainbox_t02 extra)"      refuse

# team gate fails closed when unset
( CTP_ALLOWED_TEAM=""; check "no team configured -> mutating refused" "$(cls host deploy trainbox_t02)" refuse )

sec() { ctp_is_secret_path "$1" && echo secret || echo ok; }
check "vault file is secret"        "$(sec /var/tmp/vlt_pf)"            secret
check "ssh key is secret"           "$(sec /home/tester/.ssh/id_ed25519)" secret
check ".env anywhere is secret"     "$(sec /workspace/app/.env)"       secret
check "zsh_history is secret"       "$(sec /home/tester/.zsh_history)"  secret
check ".env.example is NOT secret"  "$(sec /workspace/.env.example)"   ok
check "ssh config is NOT secret"    "$(sec /home/tester/.ssh/config)"  ok
check "README is NOT secret"        "$(sec /workspace/README.md)"      ok

# C1 — PII/IP path matcher (separate list, separate verdict from secrets)
pii() { ctp_is_pii_path "$1" && echo pii || echo ok; }
check "org-data tree is pii"          "$(pii /home/tester/org-data/clients.csv)" pii
check "cases csv is pii"              "$(pii /home/tester/cases/report.csv)"     pii
check "customer tree is pii"          "$(pii /srv/customer/db.sql)"              pii
check "customer-list anywhere is pii" "$(pii /var/tmp/customer-list.csv)"        pii
check "notes file is NOT pii"         "$(pii /home/tester/notes/readme.md)"      ok
check "README is NOT pii"             "$(pii /workspace/README.md)"              ok
# the two lists are independent: a secret is not pii, a pii path is not secret
check "secret path is NOT pii"        "$(pii /var/tmp/vlt_pf)"                    ok
check "pii path is NOT secret"        "$(sec /home/tester/org-data/clients.csv)" ok
# empty list (the opt-in default) matches nothing
( CTP_PII_PATHS=""; check "empty pii list matches nothing" "$(pii /home/tester/org-data/clients.csv)" ok )

# ============================================================================
echo "== wrapper (mocked docker) =="
BIN="$TMP/bin"; mkdir -p "$BIN"
# Mock docker: behaviour tuned by env the MOCK reads (not the wrapper's gates).
cat > "$BIN/docker" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == "inspect" && "$2" == "-f" ]]; then
  # $3 is the go template: the Mounts query gets $MOCK_MOUNTS, else State.Running
  if [[ "$3" == *Mounts* ]]; then printf '%s\n' "${MOCK_MOUNTS:-}"; else echo true; fi
  exit 0
fi
# `docker exec [-i] [-w DIR] CONTAINER ...` — capture -w so a test can assert it
if [[ "$1" == "exec" ]]; then
  shift
  WDIR=""
  while [[ "${1:-}" == -* ]]; do
    if [[ "$1" == "-w" ]]; then WDIR="$2"; shift 2; continue; fi
    shift
  done
  shift   # container
  if [[ "$1" == "test" && "$2" == "-e" ]]; then
    [[ "${MOCK_VAULT_LOCKED:-0}" == "1" ]] && exit 1 || exit 0
  fi
  if [[ "$1" == "pgrep" || "$*" == *pgrep* ]]; then
    [[ "${MOCK_BUSY:-0}" == "1" ]] && exit 0 || exit 1
  fi
  echo "WDIR: $WDIR"
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

run_wrap "" -- host deploy trainbox_t02;  check "non-interactive deploy refused (no auto-yes)" "$RC" 5
ASSUME_YES=1 PATH="$BIN:$PATH" CTP_BRIDGE_CONF="$CONF" bash "$ROOT/scripts/ctp-bridge.sh" host deploy trainbox_t02 </dev/null >/dev/null 2>&1
check "ASSUME_YES refused" "$?" 5
run_wrap "" -- secrets edit;              check "refused verb exits before docker (3)" "$RC" 3
run_wrap "" -- host deploy trainbox_t05;  check "wrong-team deploy refused (3)" "$RC" 3
run_wrap "" -- host deploy otherbox_t02;  check "wrong-box deploy refused (3)" "$RC" 3
MOCK_VAULT_LOCKED=1 PATH="$BIN:$PATH" CTP_BRIDGE_CONF="$CONF" bash "$ROOT/scripts/ctp-bridge.sh" host deploy trainbox_t02 </dev/null >/dev/null 2>&1
check "vault locked refused (4)" "$?" 4
MOCK_VAULT_LOCKED=1 PATH="$BIN:$PATH" CTP_BRIDGE_CONF="$CONF" bash "$ROOT/scripts/ctp-bridge.sh" host list trainbox_t02 </dev/null >/dev/null 2>&1
check "vault locked refuses a read too (4)" "$?" 4
# update-inventory (inventory class) does NOT gate on vault -> passes the vault
# check and refuses later at the confirm gate (no token, non-interactive) = 5
MOCK_VAULT_LOCKED=1 PATH="$BIN:$PATH" CTP_BRIDGE_CONF="$CONF" bash "$ROOT/scripts/ctp-bridge.sh" project update-inventory </dev/null >/dev/null 2>&1
check "update-inventory skips the vault check (5, not 4)" "$?" 5
MOCK_BUSY=1 PATH="$BIN:$PATH" CTP_BRIDGE_CONF="$CONF" bash "$ROOT/scripts/ctp-bridge.sh" host deploy trainbox_t02 </dev/null >/dev/null 2>&1
check "busy refused (4)" "$?" 4
PATH="$BIN:$PATH" CTP_BRIDGE_CONF="$TMP/nope.conf" bash "$ROOT/scripts/ctp-bridge.sh" host deploy trainbox_t02 </dev/null >/dev/null 2>&1
check "missing config refused (2)" "$?" 2

# --- hook-approval token: the agent path (no TTY) runs iff a valid token exists
STATE="$TMP/state"; mkdir -p "$STATE"; APPROVAL="$STATE/approval"
_mktoken() { printf '%s\t%s\n' "$1" "$2" > "$APPROVAL"; }   # <expiry-epoch> <argv>
NOW="$(date +%s)"; FUTURE=$((NOW + 120)); PAST=$((NOW - 5))

_mktoken "$FUTURE" "host list trainbox_t02"
PATH="$BIN:$PATH" CTP_BRIDGE_CONF="$CONF" CTP_BRIDGE_STATE="$STATE" CTP_BRIDGE_LOG="$TMP/c2.log" \
    bash "$ROOT/scripts/ctp-bridge.sh" host list trainbox_t02 </dev/null >/dev/null 2>&1
check "valid token: non-interactive run proceeds (0)" "$?" 0
[[ ! -f "$APPROVAL" ]] && ok "token consumed (single-use)" || bad "token consumed (single-use)"

_mktoken "$FUTURE" "host list SOMETHINGELSE_t02"
PATH="$BIN:$PATH" CTP_BRIDGE_CONF="$CONF" CTP_BRIDGE_STATE="$STATE" \
    bash "$ROOT/scripts/ctp-bridge.sh" host list trainbox_t02 </dev/null >/dev/null 2>&1
check "token for other argv: refused (5)" "$?" 5

_mktoken "$PAST" "host list trainbox_t02"
PATH="$BIN:$PATH" CTP_BRIDGE_CONF="$CONF" CTP_BRIDGE_STATE="$STATE" \
    bash "$ROOT/scripts/ctp-bridge.sh" host list trainbox_t02 </dev/null >/dev/null 2>&1
check "expired token: refused (5)" "$?" 5

# --- working directory: CTP_PROJECT_DIR unset -> translate CWD via bind mount -
CONF2="$TMP/noproj.conf"; grep -v '^CTP_PROJECT_DIR=' "$CONF" > "$CONF2"
HOSTPROJ="$TMP/host/proj"; mkdir -p "$HOSTPROJ/inventories/dcm"
printf '%s\t%s\n' "$FUTURE" "host list trainbox_t02" > "$STATE/approval"
out="$(cd "$HOSTPROJ/inventories/dcm" && PATH="$BIN:$PATH" CTP_BRIDGE_CONF="$CONF2" \
    CTP_BRIDGE_STATE="$STATE" MOCK_MOUNTS="$HOSTPROJ"$'\t'"/srv" \
    bash "$ROOT/scripts/ctp-bridge.sh" host list trainbox_t02 </dev/null 2>&1)"
if printf '%s' "$out" | grep -Fq 'WDIR: /srv/inventories/dcm'; then
    ok "CWD translated through bind mount to container path"
else bad "CWD translated through bind mount ($(printf '%s' "$out" | grep WDIR: | head -1))"; fi
# CWD outside any mount, no override -> refuse (4), never guess
( cd "$TMP" && PATH="$BIN:$PATH" CTP_BRIDGE_CONF="$CONF2" CTP_BRIDGE_STATE="$STATE" \
    MOCK_MOUNTS="$HOSTPROJ"$'\t'"/srv" bash "$ROOT/scripts/ctp-bridge.sh" host list trainbox_t02 </dev/null >/dev/null 2>&1 )
check "CWD outside the mount -> refuse (4)" "$?" 4

# --- exec prelude survives a box with no venv (zsh NOMATCH would abort) -------
check "wrapper venv glob uses (N) NULL_GLOB" \
    "$(grep -o '\.venv/bin/activate(N)' "$ROOT/scripts/ctp-bridge.sh" | wc -l | tr -d ' ')" 2
if command -v zsh >/dev/null 2>&1; then
    EMPTYH="$TMP/emptyhome"; mkdir -p "$EMPTYH"
    out="$(HOME="$EMPTYH" zsh -c '
        _src() { [ -f "$1" ] && . "$1" >/dev/null 2>&1; }
        _src "$HOME/.local/bin/env"
        for _v in "$HOME"/*/.venv/bin/activate(N) "$HOME"/.venv/bin/activate(N); do _src "$_v" && break; done
        echo REACHED_CTP' 2>&1)"
    [[ "$out" == *REACHED_CTP* ]] && ok "exec prelude reaches ctp with no venv present" \
        || bad "exec prelude aborts with no venv: $out"
else
    echo "  --  zsh unavailable; skipping NULL_GLOB behaviour test"
fi

# Run path needs a tty (the gate refuses non-interactive by design). Use script(1)
# to allocate one; skip honestly if unavailable.
if command -v script >/dev/null 2>&1; then
    rm -f "$TMP/count.log"
    script -qec "PATH='$BIN:$PATH' CTP_BRIDGE_CONF='$CONF' CTP_BRIDGE_LOG='$TMP/count.log' bash '$ROOT/scripts/ctp-bridge.sh' host deploy-role trainbox_t02" /dev/null <<<"y" >"$TMP/run.out" 2>&1
    # The mock echoes the full docker-exec argv; the ctp args must arrive as
    # trailing positional params (…_ host deploy-role trainbox_t02), never a string.
    if grep -Fq '_ host deploy-role trainbox_t02' "$TMP/run.out"; then
        ok "confirm 'y' runs the exact positional argv"
    else bad "confirm 'y' runs the exact positional argv ($(grep RAN: "$TMP/run.out" | head -1))"; fi
    # the exec activates the venv (ansible-playbook lives there), not just autocomplete
    if grep -q '.venv/bin/activate' "$TMP/run.out" && grep -q '.local/bin/env' "$TMP/run.out" \
       && grep -q 'ANSIBLE_VAULT_PASSWORD_FILE' "$TMP/run.out"; then
        ok "exec sources venv + env + vault-password-file prelude"
    else bad "exec sources venv + env + vault-password-file prelude"; fi
    # runs in the project dir (config CTP_PROJECT_DIR), not the container WORKDIR
    if grep -Fq 'WDIR: /srv/inventories/dcm' "$TMP/run.out"; then
        ok "exec sets -w to the project dir (CTP_PROJECT_DIR)"
    else bad "exec sets -w to the project dir ($(grep WDIR: "$TMP/run.out" | head -1))"; fi
    if [[ -f "$TMP/count.log" ]] && grep -q "deploy-role" "$TMP/count.log" && ! grep -q "trainbox" "$TMP/count.log"; then
        ok "count log records verb+outcome, not the target"
    else bad "count log records verb+outcome, not the target"; fi
    # a read verb runs too (update-inventory, no target)
    script -qec "PATH='$BIN:$PATH' CTP_BRIDGE_CONF='$CONF' bash '$ROOT/scripts/ctp-bridge.sh' project update-inventory" /dev/null <<<"y" >"$TMP/inv.out" 2>&1
    if grep -Fq '_ project update-inventory' "$TMP/inv.out"; then
        ok "update-inventory runs (no target)"
    else bad "update-inventory runs ($(grep RAN: "$TMP/inv.out" | head -1))"; fi
else
    echo "  --  script(1) unavailable; skipping run-path tests"
fi

# ============================================================================
echo "== hook (decision on tool-call JSON) =="
HOOK="$ROOT/.claude/hooks/pretooluse-ctp.sh"
if ! command -v jq >/dev/null 2>&1; then
    echo "  --  jq unavailable; skipping hook tests"
else
HSTATE="$TMP/hookstate"; mkdir -p "$HSTATE"
decide() { # decide <json> -> prints allow|deny|ask|none
    local out
    out="$(CTP_BRIDGE_CONF="$CONF" CTP_BRIDGE_STATE="$HSTATE" CTP_TARGET_USER=tester \
        CTP_TARGET_HOME=/home/tester HOME=/home/tester bash "$HOOK" <<<"$1" 2>/dev/null)"
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
# the INSTALLED name is `ctp-bridge` (no .sh); the hook must recognise it too
check "installed name deploy allowed -> ask"  "$(decide "$(bash_json "ctp-bridge host deploy trainbox_t02")")" ask
check "installed name wrong team -> deny"      "$(decide "$(bash_json "ctp-bridge host deploy trainbox_t05")")" deny
check "installed name abs path -> ask"         "$(decide "$(bash_json "/home/u/.local/bin/ctp-bridge host deploy trainbox_t02")")" ask
check "installed name update-inventory -> ask" "$(decide "$(bash_json "ctp-bridge project update-inventory")")" ask
check "Bash wrapper allowed -> ask"       "$(decide "$(bash_json "bash $ROOT/scripts/ctp-bridge.sh host deploy trainbox_t02")")" ask
check "Bash wrapper wrong team -> deny"   "$(decide "$(bash_json "bash $ROOT/scripts/ctp-bridge.sh host deploy trainbox_t05")")" deny
check "Bash wrapper update-inventory -> ask" "$(decide "$(bash_json "bash $ROOT/scripts/ctp-bridge.sh project update-inventory")")" ask
check "Bash wrapper list <box> -> ask"    "$(decide "$(bash_json "bash $ROOT/scripts/ctp-bridge.sh host list trainbox_t02")")" ask
check "Bash wrapper refused verb -> deny" "$(decide "$(bash_json "bash $ROOT/scripts/ctp-bridge.sh host remove trainbox_t02")")" deny
check "env cannot override config -> deny" "$(decide "$(bash_json "CTP_ALLOWED_TARGET=evil_t02 bash $ROOT/scripts/ctp-bridge.sh host deploy evil_t02")")" deny
check "prose mentioning ctp -> none"      "$(decide "$(bash_json 'echo use ctp later to deploy')")"  none
check "unrelated bash -> none"            "$(decide "$(bash_json 'ls -la /workspace')")"             none

# approving a wrapper call writes a token bound to the exact argv
rm -f "$HSTATE/approval"
decide "$(bash_json "ctp-bridge host deploy trainbox_t02")" >/dev/null
if [[ -f "$HSTATE/approval" ]] && grep -Fq 'host deploy trainbox_t02' "$HSTATE/approval"; then
    ok "ask writes an approval token bound to the argv"
else bad "ask writes an approval token bound to the argv"; fi

# redirection after the wrapper args is stripped: the bound token matches the argv
# the wrapper will actually receive (the real 2>&1 | tail bug from the box).
check "redirected wrapper call -> ask"    "$(decide "$(bash_json "ctp-bridge host list trainbox_t02 2>&1")")" ask
rm -f "$HSTATE/approval"
decide "$(bash_json "ctp-bridge host list trainbox_t02 2>&1 | tail -60")" >/dev/null
if [[ -f "$HSTATE/approval" ]] && grep -Eq $'\thost list trainbox_t02$' "$HSTATE/approval"; then
    ok "token bound to clean argv (redirection/pipe stripped)"
else bad "token bound to clean argv (got: $(cat "$HSTATE/approval" 2>/dev/null))"; fi
# a refused call writes NO token
rm -f "$HSTATE/approval"
decide "$(bash_json "ctp-bridge host deploy trainbox_t05")" >/dev/null
[[ ! -f "$HSTATE/approval" ]] && ok "refused call writes no token" || bad "refused call writes no token"

# the approval token path is guarded from tools (read/write/bash)
APPROVAL_PATH="$HSTATE/approval"
check "Read approval token -> deny"  "$(decide "$(read_json "$APPROVAL_PATH")")" deny
check "Write to secret path -> deny" "$(decide "$(printf '{"tool_name":"Write","tool_input":{"file_path":"%s"}}' "$APPROVAL_PATH")")" deny
check "Bash write token -> deny"     "$(decide "$(bash_json "echo x > $APPROVAL_PATH")")" deny
check "Edit .env -> deny"            "$(decide "$(printf '{"tool_name":"Edit","tool_input":{"file_path":"/app/.env"}}')")" deny

# C1 — PII/IP path guard at the hook: reads/writes of a configured Org path deny;
# an unlisted path draws no opinion (no friction).
check "Read PII path -> deny"        "$(decide "$(read_json /home/tester/org-data/clients.csv)")" deny
check "Bash cat PII path -> deny"    "$(decide "$(bash_json "cat /home/tester/org-data/clients.csv")")" deny
check "Bash <redirect PII -> deny"   "$(decide "$(bash_json "mail -s x foo < /srv/customer/db.sql")")" deny
check "Write to PII path -> deny"    "$(decide "$(printf '{"tool_name":"Write","tool_input":{"file_path":"/srv/customer/out.csv"}}')")" deny
check "Read unlisted path -> none"   "$(decide "$(read_json /home/tester/notes/readme.md)")" none

# multi-line Bash must not be mis-segmented: a commit message or a heredoc body
# whose line happens to start ctp/make is DATA, not a command. This was a real
# false-deny on the box that forced `git commit -F` workarounds.
check "multiline commit msg body -> none" "$(decide "$(bash_json "$(printf 'git commit -m "fix bridge\nctp host deploy notes\nmake start notes"')")")" none
# a heredoc delimiter ended by the newline ITSELF (the common form, no trailing
# redirect) must still register the heredoc so its body is skipped, not parsed.
check "heredoc body with ctp/make -> none" "$(decide "$(bash_json "$(printf 'cat <<EOF > /tmp/n\nctp host deploy x\nmake start y\nEOF')")")" none
check "unquoted delim at EOL body -> none" "$(decide "$(bash_json "$(printf 'cat <<EOF\nctp host remove x\nEOF')")")" none
check "quoted delim at EOL body -> none"   "$(decide "$(bash_json "$(printf "cat <<'EOF'\nctp host remove x\nEOF")")")" none
check "dash delim at EOL body -> none"      "$(decide "$(bash_json "$(printf 'cat <<-EOF\n\tctp host remove x\n\tEOF')")")" none
check "quoted-delim heredoc body -> none"  "$(decide "$(bash_json "$(printf "cat <<'EOF' > /tmp/n\nctp host deploy x\nEOF")")")" none
# but a genuine command on its own line, or after a pipe, is still caught
check "newline-separated bare ctp -> deny" "$(decide "$(bash_json "$(printf 'echo hi\nctp host deploy x')")")" deny
check "pipe into bare ctp -> deny"         "$(decide "$(bash_json 'true | ctp host deploy x')")" deny

# command substitution / backticks / subshells must reach classification on the
# INNER command — even inside double quotes, where the shell still expands them —
# so `echo $(ctp ...)` cannot slip a bare ctp past the confirm gate as `echo`.
check "cmdsub bare -> deny"               "$(decide "$(bash_json 'echo $(ctp host remove x)')")" deny
check "cmdsub inside dquotes -> deny"     "$(decide "$(bash_json 'echo "$(ctp host remove x)"')")" deny
check "backtick cmdsub -> deny"           "$(decide "$(bash_json 'echo `ctp host remove x`')")" deny
check "subshell -> deny"                  "$(decide "$(bash_json '( ctp host remove x )')")" deny
check "assign cmdsub -> deny"             "$(decide "$(bash_json 'out=$(ctp host list foo)')")" deny
check "nested cmdsub in dquotes -> deny"  "$(decide "$(bash_json 'echo "$(echo "$(ctp host remove x)")"')")" deny
# single quotes expand nothing, so the command never runs there — not classified
check "single-quoted literal -> none"     "$(decide "$(bash_json "echo '\$(ctp host remove x)'")")" none
# and legitimate substitutions are NOT denied (no new false positives)
check "legit cmdsub (git) -> none"        "$(decide "$(bash_json 'echo "$(git rev-parse HEAD)"')")" none
check "legit assign cmdsub (grep) -> none" "$(decide "$(bash_json 'files=$(grep -rl foo .)')")" none
check "legit subshell -> none"            "$(decide "$(bash_json '( cd /tmp && ls )')")" none
check "legit process subst -> none"       "$(decide "$(bash_json 'diff <(sort a) <(sort b)')")" none
check "legit param expansion -> none"     "$(decide "$(bash_json 'echo "${ctp_home}/bin"')")" none
fi

# ============================================================================
echo ""
echo "Result: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
