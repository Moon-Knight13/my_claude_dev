#!/usr/bin/env bash
# test-split.sh — split-task co-execution (story D, issue #77).
#
# The invariant: one task, two halves, and the cloud half is written knowing
# ONLY the declared interface of the local half. Every test below is a way of
# asking one of four questions:
#   - did anything from the local half reach Claude other than the contract?
#   - was the split decided without sending anything anywhere?
#   - can the planner make a part less local than the code-level checks allow?
#   - does a failure in either half leave anything half-applied?
# Claude is a stub that records what it was given, as #63's tests do.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok()   { echo "  OK  $1"; ((PASS++)) || true; }
bad()  { echo " FAIL $1"; ((FAIL++)) || true; }
check(){ if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }
contains(){ if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1 (want substring '$3', got '${2:0:300}')"; fi; }
lacks(){ if [[ "$2" != *"$3"* ]]; then ok "$1"; else bad "$1 (must not contain '$3')"; fi; }

command -v python3 >/dev/null 2>&1 || { echo "test-split: python3 required"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"; [[ -n "${MOCK_PID:-}" ]] && kill "$MOCK_PID" 2>/dev/null' EXIT
H="$TMP/home"; W="$TMP/work"; REC="$TMP/rec"
mkdir -p "$H/.ssh" "$H/.config/orchestrator" "$W/org" "$REC"
echo "secret-key-material" > "$H/.ssh/id_ed25519"
export HOME="$H"
export ORCH_LOG="$TMP/log.jsonl"

CONF="$TMP/ctp.conf"
cat > "$CONF" <<EOF
CTP_CONTAINER=catapult-test
CTP_SECRET_PATHS=$H/.ssh $H/.ssh/**
CTP_PII_PATHS=$W/org/**
EOF
export CTP_BRIDGE_CONF="$CONF"
export CTP_BRIDGE_STATE="$TMP/state"
unset ORCH_CALLER ORCH_SANITISER ORCH_TERM_LIST ORCH_CLASSIFIER

# ===========================================================================
echo "== plan validation (code, not the model) =="
# shellcheck source=scripts/lib/split-plan.sh disable=SC1091
source "$ROOT/scripts/lib/split-plan.sh"

GOOD='{"parts":[{"id":"script","route":"local","artifact":"script.py","task":"build it"},{"id":"playbook","route":"cloud","artifact":"playbook.yml","task":"write a playbook","uses":["script"]}]}'
split_validate "$GOOD"; check "a well-formed plan is valid" "$SPLIT_ERR" ""

v() { split_validate "$2"; if [[ -n "$SPLIT_ERR" ]]; then ok "$1"; else bad "$1 (accepted)"; fi; }
v "not an object"                 '[1,2]'
v "no parts"                      '{"parts":[]}'
v "too many parts"                '{"parts":[{"id":"a","route":"local","artifact":"a","task":"t"},{"id":"b","route":"local","artifact":"b","task":"t"},{"id":"c","route":"local","artifact":"c","task":"t"},{"id":"d","route":"local","artifact":"d","task":"t"},{"id":"e","route":"local","artifact":"e","task":"t"}]}'
v "bad route"                     '{"parts":[{"id":"a","route":"frontier","artifact":"a","task":"t"}]}'
v "bad id"                        '{"parts":[{"id":"A B","route":"local","artifact":"a","task":"t"}]}'
v "duplicate id"                  '{"parts":[{"id":"a","route":"local","artifact":"a","task":"t"},{"id":"a","route":"local","artifact":"b","task":"t"}]}'
v "duplicate artifact"            '{"parts":[{"id":"a","route":"local","artifact":"x","task":"t"},{"id":"b","route":"local","artifact":"x","task":"t"}]}'
v "empty task"                    '{"parts":[{"id":"a","route":"local","artifact":"a","task":""}]}'
v "absolute artifact"             '{"parts":[{"id":"a","route":"cloud","artifact":"/etc/passwd","task":"t"}]}'
v "home-relative artifact"        '{"parts":[{"id":"a","route":"cloud","artifact":"~/.bashrc","task":"t"}]}'
v "artifact escapes with .."      '{"parts":[{"id":"a","route":"cloud","artifact":"x/../../out","task":"t"}]}'
v "artifact inside .git"          '{"parts":[{"id":"a","route":"cloud","artifact":".git/hooks/pre-commit","task":"t"}]}'
v "artifact with a space"         '{"parts":[{"id":"a","route":"cloud","artifact":"a b","task":"t"}]}'
v "local part with uses"          '{"parts":[{"id":"a","route":"local","artifact":"a","task":"t"},{"id":"b","route":"local","artifact":"b","task":"t","uses":["a"]}]}'
v "uses an unknown part"          '{"parts":[{"id":"b","route":"cloud","artifact":"b","task":"t","uses":["zz"]}]}'
v "cloud part uses a cloud part"  '{"parts":[{"id":"a","route":"cloud","artifact":"a","task":"t"},{"id":"b","route":"cloud","artifact":"b","task":"t","uses":["a"]}]}'

check "extract takes the JSON out of prose" \
    "$(split_extract 'junk </think> here: {"parts":[]} thanks' | jq -c .)" '{"parts":[]}'
check "extract of prose is empty" "$(split_extract 'no json here')" ""

echo "== forcing routes: the planner can only make a part MORE local =="
# AUTO with no classifier: fail closed, every cloud part comes back local.
F="$(split_force_routes "$GOOD" AUTO)"
check "no classifier: cloud part forced local" "$(jq -r '.parts[1].route' <<<"$F")" local
check "  recorded as the classifier's doing"   "$(jq -r '.parts[1].forced' <<<"$F")" classifier
check "  its uses dropped"                     "$(jq -r '.parts[1].uses // "none"' <<<"$F")" none

printf '#!/usr/bin/env bash\necho nonsensitive\n' > "$TMP/cls-ok"; chmod +x "$TMP/cls-ok"
printf '#!/usr/bin/env bash\necho sensitive\n' > "$TMP/cls-no"; chmod +x "$TMP/cls-no"
check "classifier nonsensitive: stays cloud" "$(ORCH_CLASSIFIER="$TMP/cls-ok" split_force_routes "$GOOD" AUTO | jq -r '.parts[1].route')" cloud
check "classifier sensitive: forced local"   "$(ORCH_CLASSIFIER="$TMP/cls-no" split_force_routes "$GOOD" AUTO | jq -r '.parts[1].route')" local
check "CLAUDE-ONLY: classifier not needed"   "$(split_force_routes "$GOOD" CLAUDE-ONLY | jq -r '.parts[1].route')" cloud
check "LOCAL-ONLY: everything local"         "$(ORCH_CLASSIFIER="$TMP/cls-ok" split_force_routes "$GOOD" LOCAL-ONLY | jq -r '[.parts[].route]|unique|join(",")')" local

printf 'Northwind\n' > "$TMP/terms.txt"
FLOORPLAN='{"parts":[{"id":"script","route":"local","artifact":"script.py","task":"build it"},{"id":"playbook","route":"cloud","artifact":"playbook.yml","task":"deploy the Northwind report","uses":["script"]}]}'
F="$(ORCH_TERM_LIST="$TMP/terms.txt" ORCH_CLASSIFIER="$TMP/cls-ok" split_force_routes "$FLOORPLAN" AUTO)"
check "word list forces local even when the classifier says fine" "$(jq -r '.parts[1].route' <<<"$F")" local
check "  recorded as the floor's doing"                           "$(jq -r '.parts[1].forced' <<<"$F")" floor
F="$(ORCH_TERM_LIST="$TMP/terms.txt" split_force_routes "$FLOORPLAN" CLAUDE-ONLY)"
check "word list beats CLAUDE-ONLY"                               "$(jq -r '.parts[1].route' <<<"$F")" local
ARTPLAN='{"parts":[{"id":"a","route":"cloud","artifact":"northwind.yml","task":"a playbook"}]}'
check "word list checks the artifact name too" \
    "$(ORCH_TERM_LIST="$TMP/terms.txt" split_force_routes "$ARTPLAN" CLAUDE-ONLY | jq -r '.parts[0].route')" local

# ===========================================================================
echo "== the runner, end to end =="
PORT=18437
SCRIPT="$TMP/script.txt"; RECORD="$TMP/record.jsonl"
start_mock() {
    [[ -n "${MOCK_PID:-}" ]] && { kill "$MOCK_PID" 2>/dev/null; wait "$MOCK_PID" 2>/dev/null; }
    : > "$RECORD"
    MOCK_SCRIPT="$SCRIPT" MOCK_RECORD="$RECORD" MOCK_PORT="$PORT" python3 "$ROOT/scripts/tests/mock-executor-llm.py" &
    MOCK_PID=$!
    for _ in $(seq 1 50); do
        [[ "$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/ping" -d '{}' 2>/dev/null)" == 404 ]] && return 0
        sleep 0.1
    done
    return 1
}

# Claude, as a stub that records what it was given and where it was run from.
cat > "$TMP/claude" <<EOF
#!/usr/bin/env bash
echo call >> "$REC/calls"
printf '%s\n' "\$@" > "$REC/args"
pwd > "$REC/cwd"; ls -A > "$REC/ls"
cat > "$REC/stdin"
[[ -n "\${STUB_FAIL:-}" ]] && exit 1
printf '\`\`\`yaml\n- hosts: all\n  tasks: []\n\`\`\`\n'
EOF
chmod +x "$TMP/claude"

LOCAL_TASK="Read the customer export and write a report script. SECRETMARK-local-task"
PLAN_LINE="$(jq -cn --arg lt "$LOCAL_TASK" '{parts:[
  {id:"script",route:"local",artifact:"script.py",task:$lt},
  {id:"playbook",route:"cloud",artifact:"playbook.yml",task:"Write an Ansible playbook that runs the script from part script on every host.",uses:["script"]}]}')"
WRITE_LINE="$(jq -cn --arg p "$W/script.py" '{tool:"write_file",path:$p,content:"print(\"SECRETMARK-impl Jane Roe\")"}')"
DONE_LINE='{"done":true,"answer":"SECRETMARK-answer","contract":{"name":"customer_report","handle":"{{HANDLE}}","summary":"prints a report for one customer","invocation":"python3 script.py --id ID","inputs":[{"name":"id","type":"integer","required":true}],"exit_codes":[{"code":0,"meaning":"ok"}],"note":"SECRETMARK-note"}}'

reset_run() { rm -f "$W/script.py" "$W/playbook.yml" "$REC"/*; : > "$ORCH_LOG"; }
run_split() { # run_split <answers> [split args...] ; sets OUT RC
    OUT="$(cd "$W" && ANSWERS="$1" \
        ORCH_SPLIT_ENDPOINT="http://127.0.0.1:$PORT" ORCH_SPLIT_MODEL=mock \
        ORCH_CLAUDE_BIN="$TMP/claude" ORCH_CLASSIFIER="$TMP/cls-ok" \
        python3 "$ROOT/scripts/tests/pty-answer.py" "$ROOT/scripts/orchestrator/split.sh" "${@:2}" 2>&1)"
    RC=$?
}

# --- happy path --------------------------------------------------------------
reset_run
printf '%s\n%s\n%s\n' "$PLAN_LINE" "$WRITE_LINE" "$DONE_LINE" > "$SCRIPT"
start_mock || bad "mock endpoint started"
# three prompts: the plan, the sanitiser bypass (no sanitiser here), the contract
run_split "y,y,y" "make script.py from the customer export and a playbook to run it"
check "split completes" "$RC" 0
contains "local artifact written by the executor" "$(cat "$W/script.py" 2>/dev/null)" SECRETMARK-impl
check "cloud artifact written, fence stripped" "$(cat "$W/playbook.yml" 2>/dev/null)" "$(printf -- '- hosts: all\n  tasks: []')"
contains "plan shown to the owner" "$OUT" "SPLIT PLAN"
contains "cloud task shown word for word" "$OUT" "runs the script from part script on every host"
contains "contract shown for approval" "$OUT" "CONTRACT TO DISCLOSE"

CL="$(cat "$REC/stdin" 2>/dev/null)"
contains "Claude got the cloud task"          "$CL" "Ansible playbook"
contains "Claude got the contract's name"     "$CL" customer_report
contains "Claude got the invocation"          "$CL" "--id ID"
lacks    "Claude never saw the implementation" "$CL" SECRETMARK-impl
lacks    "Claude never saw the data"          "$CL" "Jane Roe"
lacks    "Claude never saw the local task"    "$CL" SECRETMARK-local-task
lacks    "Claude never saw the local answer"  "$CL" SECRETMARK-answer
lacks    "undeclared contract field dropped"  "$CL" SECRETMARK-note
lacks    "Claude never saw a local path"      "$CL" "$W"
ARGS="$(cat "$REC/args" 2>/dev/null)"
contains "Claude ran in print mode"           "$ARGS" "-p"
# --tools must be present AND followed by an empty list: absent means "all tools".
check    "Claude had every tool disabled"     "$(awk 'p { printf "[%s]", $0; exit } $0 == "--tools" { p = 1 }' "$REC/args")" "[]"
contains "Claude had no MCP servers"          "$ARGS" "--strict-mcp-config"
check    "Claude ran outside the work tree"   "$([[ "$(cat "$REC/cwd")" != "$W"* ]] && echo yes)" yes
check    "Claude's directory was empty"       "$(cat "$REC/ls")" ""

PLANREQ="$(head -1 "$RECORD")"
contains "planner got the whole task"         "$(jq -r '.messages[1].content' <<<"$PLANREQ")" "make script.py"
LOGTXT="$(cat "$ORCH_LOG")"
check    "log records the split"              "$(jq -rs '[.[]|select(.event=="split")|.status]|join(",")' "$ORCH_LOG")" "done"
lacks    "log has no task text"               "$LOGTXT" SECRETMARK
lacks    "log has no path"                    "$LOGTXT" "$W"
lacks    "log has no artifact name"           "$LOGTXT" playbook.yml

# --- the plan is refused: nothing runs, nothing crosses ---------------------
reset_run; start_mock
run_split "n" "make script.py and a playbook"
check "refused plan exits 15"            "$RC" 15
check "Claude never called"              "$(cat "$REC/calls" 2>/dev/null | wc -l)" 0
check "only the planner was asked"       "$(wc -l < "$RECORD")" 1
check "no artifact written"              "$(ls "$W")" org

# --- no terminal: refused before even planning ------------------------------
reset_run; start_mock
( cd "$W" && ORCH_SPLIT_ENDPOINT="http://127.0.0.1:$PORT" ORCH_SPLIT_MODEL=mock ORCH_CLAUDE_BIN="$TMP/claude" \
    "$ROOT/scripts/orchestrator/split.sh" "make script.py" </dev/null >/dev/null 2>&1 ); RC=$?
check "no terminal exits 15"             "$RC" 15
check "planner not even called"          "$(wc -l < "$RECORD")" 0

# --- the contract names the wrong handle: stop, roll back --------------------
reset_run
printf '%s\n%s\n%s\n' "$PLAN_LINE" "$WRITE_LINE" "${DONE_LINE//\{\{HANDLE\}\}/00000000deadbeef}" > "$SCRIPT"
start_mock
run_split "y,y,y" "make script.py and a playbook"
check "wrong handle is a local failure"  "$RC" 16
check "Claude never called"              "$(cat "$REC/calls" 2>/dev/null | wc -l)" 0
check "local artifact rolled back"       "$([[ -e "$W/script.py" ]] && echo present || echo absent)" absent

# --- the owner refuses the contract: nothing crosses, rolled back -----------
reset_run
printf '%s\n%s\n%s\n' "$PLAN_LINE" "$WRITE_LINE" "$DONE_LINE" > "$SCRIPT"
start_mock
run_split "y,y,n" "make script.py and a playbook"
check "refused contract is a local failure" "$RC" 16
check "Claude never called"              "$(cat "$REC/calls" 2>/dev/null | wc -l)" 0
check "local artifact rolled back"       "$([[ -e "$W/script.py" ]] && echo present || echo absent)" absent

# --- the cloud half fails: the local half is rolled back too ----------------
reset_run
echo "ORIGINAL" > "$W/script.py"
start_mock
STUB_FAIL=1 run_split "y,y,y" "make script.py and a playbook"
check "cloud failure exits 17"           "$RC" 17
check "pre-existing artifact restored"   "$(cat "$W/script.py")" ORIGINAL
check "no cloud artifact written"        "$([[ -e "$W/playbook.yml" ]] && echo present || echo absent)" absent

# --- a planner that cannot produce a plan -----------------------------------
reset_run
printf 'I think we should split it in two.\n' > "$SCRIPT"; start_mock
run_split "y" "make script.py"
check "invalid plan exits 14"            "$RC" 14
check "one correction round, no more"    "$(wc -l < "$RECORD")" 2
contains "correction fed back to the planner" "$(sed -n 2p "$RECORD" | jq -r '.messages[-1].content')" "rejected"

reset_run
printf '%s\n%s\n' '{"parts":[{"id":"x","route":"sideways"}]}' "$PLAN_LINE" > "$SCRIPT"; start_mock
run_split "" --dry-run "make script.py"
check "a corrected plan is accepted"     "$RC" 0

# --- dry run: shows the plan, runs nothing, needs no terminal ---------------
reset_run
printf '%s\n' "$PLAN_LINE" > "$SCRIPT"; start_mock
OUT="$(cd "$W" && ORCH_SPLIT_ENDPOINT="http://127.0.0.1:$PORT" ORCH_SPLIT_MODEL=mock ORCH_CLAUDE_BIN="$TMP/claude" \
    ORCH_CLASSIFIER="$TMP/cls-ok" "$ROOT/scripts/orchestrator/split.sh" --dry-run "make script.py" </dev/null 2>/dev/null)"; RC=$?
check "dry run exits 0 without a terminal" "$RC" 0
contains "dry run prints the plan"       "$OUT" "[playbook] CLOUD -> playbook.yml"
check "dry run ran nothing"              "$(wc -l < "$RECORD")" 1
check "dry run never called Claude"      "$(cat "$REC/calls" 2>/dev/null | wc -l)" 0

# --- the word list on a planned cloud part ----------------------------------
reset_run
jq -c '.parts[1].task = "deploy the Northwind report"' <<<"$PLAN_LINE" > "$SCRIPT"; start_mock
OUT="$(cd "$W" && ORCH_TERM_LIST="$TMP/terms.txt" ORCH_SPLIT_ENDPOINT="http://127.0.0.1:$PORT" ORCH_SPLIT_MODEL=mock \
    ORCH_CLASSIFIER="$TMP/cls-ok" "$ROOT/scripts/orchestrator/split.sh" --dry-run --mode CLAUDE-ONLY "x" 2>/dev/null)"
contains "floor moves the part local, visibly" "$OUT" "moved to local: the word list matched"
lacks    "the log never names the term"  "$(cat "$ORCH_LOG")" Northwind

# --- Claude's output is gated like Claude's own Write -----------------------
reset_run
jq -c '.parts[1].artifact = "org/deploy.yml"' <<<"$PLAN_LINE" > "$SCRIPT"; start_mock
run_split "y,y,y" "make script.py"
check "cloud artifact on a guarded path refused" "$RC" 14
check "  before anything ran"            "$(wc -l < "$RECORD")" 1
check "  and Claude was never called"    "$(cat "$REC/calls" 2>/dev/null | wc -l)" 0

# --- a symlinked directory cannot carry an artifact out of the work tree -----
reset_run
mkdir -p "$TMP/elsewhere"; ln -sfn "$TMP/elsewhere" "$W/out"
jq -c '.parts[1].artifact = "out/deploy.yml"' <<<"$PLAN_LINE" > "$SCRIPT"; start_mock
run_split "y,y,y" "make script.py"
check "artifact through a symlink refused" "$RC" 14
check "  nothing written outside"          "$(ls -A "$TMP/elsewhere")" ""
check "  and Claude was never called"      "$(cat "$REC/calls" 2>/dev/null | wc -l)" 0
rm -f "$W/out"

# --- the planner endpoint must be local -------------------------------------
( cd "$W" && ORCH_SPLIT_ENDPOINT="https://api.example.com" "$ROOT/scripts/orchestrator/split.sh" --dry-run "x" >/dev/null 2>&1 ); RC=$?
check "remote planner endpoint refused"  "$RC" 11

# --- orchestrate.sh --split plans with a LOCAL model, never the frontier ----
reset_run
printf '%s\n' "$PLAN_LINE" > "$SCRIPT"; start_mock
cat > "$TMP/orch.conf" <<EOF
ORCH_MODE=AUTO
ORCH_MODEL=claude|frontier|100|
ORCH_MODEL=planner-local|host-local|60|http://127.0.0.1:$PORT
EOF
OUT="$(cd "$W" && ORCH_CONF="$TMP/orch.conf" ORCH_CLASSIFIER="$TMP/cls-ok" \
    "$ROOT/scripts/orchestrator/orchestrate.sh" --split --dry-run "make script.py" 2>/dev/null)"; RC=$?
check "orchestrate --split dry run"      "$RC" 0
check "planned by the local model"       "$(head -1 "$RECORD" | jq -r .model)" planner-local
contains "plan printed"                  "$OUT" "SPLIT PLAN"

echo
echo "test-split: $PASS passed, $FAIL failed"
[[ "$FAIL" == 0 ]]
