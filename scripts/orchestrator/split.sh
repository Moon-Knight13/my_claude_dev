#!/usr/bin/env bash
# split.sh — split-task co-execution (story D, issue #77).
#
# One task, two halves: the local model does the sensitive half on this machine,
# Claude writes the rest, and Claude learns about the local half only through a
# declared interface the owner approved. The owner's example:
#
#   "make script.py with user data and generate an ansible playbook for it"
#     -> script.py     written locally, by the executor, reading the real data
#     -> playbook.yml  written by Claude, which knows how to CALL script.py and
#                      nothing else about it
#
# THE ORDER, AND WHY EACH STEP IS WHERE IT IS
#   1. plan      the LOCAL model proposes the split. Asking Claude to help would
#                mean describing the sensitive half to Claude in order to decide
#                it should not see it.
#   2. check     code, not the model, validates the plan and forces parts local:
#                word list always, classifier in AUTO (scripts/lib/split-plan.sh).
#   3. approve   the owner reads the plan — including every cloud task word for
#                word — and says yes. At a terminal; no terminal, no run.
#   4. local     local parts run first, through the executor and its guard stack.
#                A part a cloud part depends on returns only a contract, which
#                the owner approves on its own (E10, unchanged: per contract).
#   5. cloud     each cloud part goes to `claude -p` with ALL tools disabled and
#                no MCP servers, from an empty directory. Without that, Claude
#                could simply open script.py and the boundary would be theatre.
#   6. join      Claude's output is staged and only written once every part has
#                succeeded. Any failure rolls back every declared artifact.
#
# The halves run one after the other, never overlapping: the contract has to
# exist before anything can be written against it.
#
# Usage:  split.sh [--mode AUTO|CLAUDE-ONLY|LOCAL-ONLY] [--dry-run] "<task>"
# Exits:  0 done · 2 no task · 10 no planner prompt · 11 endpoint not local ·
#         12 planner call failed · 14 plan invalid · 15 plan not approved (or no
#         terminal) · 16 a local part failed · 17 a cloud part failed ·
#         18 the word list matched the final cloud prompt
#
# NOTE: no `set -e` — a failed part is an event to roll back from, not a reason
# to die holding half-written artifacts.
set -uo pipefail

_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/load-env.sh disable=SC1090,SC1091
source "$_HERE/../lib/load-env.sh" 2>/dev/null || true
# contract.sh brings executor-tools.sh, guard-stack.sh and orchestrator-route.sh.
# shellcheck source=scripts/lib/contract.sh disable=SC1091
source "${CONTRACT_LIB:-$_HERE/../lib/contract.sh}"
# shellcheck source=scripts/lib/split-plan.sh disable=SC1091
source "$_HERE/../lib/split-plan.sh"

ORCH_LOG="${ORCH_LOG:-.ai/orchestrator-log.jsonl}"
ENDPOINT="${ORCH_SPLIT_ENDPOINT:-${ORCH_EXEC_ENDPOINT:-${LOCAL_MODEL_ENDPOINT:-http://host.docker.internal:11434}}}"
MODEL="${ORCH_SPLIT_MODEL:-${ORCH_EXEC_MODEL:-${LOCAL_MODEL_MODEL:-richardyoung/qwen3-14b-abliterated:Q4_K_M}}}"
TIMEOUT="${ORCH_SPLIT_TIMEOUT:-300}"
CLOUD_TIMEOUT="${ORCH_SPLIT_CLOUD_TIMEOUT:-600}"
KEEP_ALIVE="${ORCH_EXEC_KEEP_ALIVE:-30m}"
PROMPT_FILE="${ORCH_PLANNER_PROMPT_FILE:-$HOME/.config/orchestrator/planner-prompt.md}"
EXECUTOR="${ORCH_EXECUTOR_BIN:-$_HERE/execute-local.sh}"
CLAUDE_BIN="${ORCH_CLAUDE_BIN:-claude}"

MODE="${ORCH_SPLIT_MODE:-AUTO}"; DRY_RUN=0; ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode) MODE="${2:-}"; shift 2 ;;
        --mode=*) MODE="${1#*=}"; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --) shift; ARGS+=("$@"); break ;;
        *) ARGS+=("$1"); shift ;;
    esac
done
case "$MODE" in AUTO|CLAUDE-ONLY|LOCAL-ONLY) : ;; *) MODE=AUTO ;; esac

TASK="${ARGS[*]:-}"
if [[ -z "$TASK" && ! -t 0 ]]; then TASK="$(cat)"; fi
[[ -n "$TASK" ]] || { echo "split.sh: no task given" >&2; exit 2; }

say() { echo "split.sh: $*" >&2; }

# --- metadata log -------------------------------------------------------------
# Counts and outcomes only. Never the task, a part's text, an artifact name or a
# contract — those are exactly what this path exists to keep in place.
_log() { # _log <status> [parts] [local] [cloud] [forced]
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
    mkdir -p "$(dirname "$ORCH_LOG")" 2>/dev/null || true
    jq -cn --arg ts "$ts" --arg st "$1" --arg mode "$MODE" \
        --argjson p "${2:-0}" --argjson l "${3:-0}" --argjson c "${4:-0}" --argjson f "${5:-0}" \
        '{ts:$ts, event:"split", status:$st, mode:$mode, parts:$p, local:$l, cloud:$c, forced:$f}' \
        >> "$ORCH_LOG" 2>/dev/null || true
}

# The planner never egresses, so a misconfigured endpoint is refused rather than
# dialled. Same list as execute-local.sh and classify-sensitivity.sh.
case "$ENDPOINT" in
    http://localhost*|http://127.*|http://host.docker.internal*|http://10.*|http://192.168.*|http://172.1[6-9].*|http://172.2[0-9].*|http://172.3[0-1].*|https://localhost*|https://127.*) : ;;
    *) say "endpoint is not local; refusing"; exit 11 ;;
esac

# The owner approves the plan at a terminal (and each contract, inside the
# executor). Find out now rather than after a planning call the owner then
# cannot act on. A dry run only shows the plan, so it needs no terminal.
if [[ "$DRY_RUN" == 0 ]] && ! exec_tty_ok; then
    say "a split needs you at a terminal to approve the plan; refusing"
    _log no-terminal; exit 15
fi

# --- 1. plan, locally ---------------------------------------------------------
# Read with `cat`, not a tool call: the private copy lives in the C1-guarded
# directory, readable here and never by Claude's tools.
SYS=""
[[ -f "$PROMPT_FILE" ]] && SYS="$(cat "$PROMPT_FILE" 2>/dev/null)"
if [[ -z "$SYS" && -f "$_HERE/planner-prompt.default.md" ]]; then
    SYS="$(cat "$_HERE/planner-prompt.default.md" 2>/dev/null)"
fi
[[ -n "$SYS" ]] || { say "no planner prompt available; refusing"; exit 10; }

say "planning locally with $MODEL ..."
MSGS="$(jq -n --arg s "$SYS" --arg u "$TASK" '[{role:"system",content:$s},{role:"user",content:$u}]')"
PLAN=""
for _attempt in 1 2; do
    REQ="$(jq -n --arg m "$MODEL" --argjson msgs "$MSGS" --arg k "$KEEP_ALIVE" \
        '{model:$m, messages:$msgs, stream:false, think:false, format:"json", keep_alive:$k,
          options:{temperature:0, top_p:1}}')"
    RESP="$(curl -sfS --max-time "$TIMEOUT" "$ENDPOINT/api/chat" \
        -H 'Content-Type: application/json' -d "$REQ" 2>/dev/null)" || {
        say "planner call failed"; _log planner-failed; exit 12; }
    REPLY="$(printf '%s' "$RESP" | jq -r '.message.content // ""' 2>/dev/null)"
    PLAN="$(split_extract "$REPLY")"
    split_validate "$PLAN"
    [[ -n "$PLAN" && -z "$SPLIT_ERR" ]] && break
    # One correction round. A local model that cannot produce a valid plan twice
    # is not going to on the tenth try, and each try is the owner's time.
    MSGS="$(printf '%s' "$MSGS" | jq --arg a "$REPLY" --arg e "${SPLIT_ERR:-reply was not a JSON object}" \
        '. + [{role:"assistant",content:$a},{role:"user",content:("That plan was rejected: " + $e + ". Reply with a corrected plan, JSON only.")}]')"
done
[[ -n "$PLAN" && -z "$SPLIT_ERR" ]] || {
    say "the planner did not produce a valid plan: ${SPLIT_ERR:-reply was not a JSON object}"
    _log plan-invalid; exit 14; }

# --- 2. code-level checks -----------------------------------------------------
PLAN="$(split_force_routes "$PLAN" "$MODE")"
N_PARTS="$(jq '.parts|length' <<<"$PLAN")"
N_LOCAL="$(jq '[.parts[]|select(.route=="local")]|length' <<<"$PLAN")"
N_CLOUD="$(jq '[.parts[]|select(.route=="cloud")]|length' <<<"$PLAN")"
N_FORCED="$(jq '[.parts[]|select(.forced)]|length' <<<"$PLAN")"

# --- 3. show the plan, and approve it -----------------------------------------
# Every cloud task is shown in full: it is sent word for word, so this is the
# owner reading exactly what will cross (the contracts are shown later, each on
# its own, by the executor).
render_plan() {
    jq -r '
        def why: if .forced == "floor" then "  (moved to local: the word list matched)"
                 elif .forced == "classifier" then "  (moved to local: the classifier judged it sensitive)"
                 elif .forced == "mode" then "  (local: LOCAL-ONLY mode)" else "" end;
        .parts[] |
        "\n[\(.id)] \(.route | ascii_upcase) -> \(.artifact)"
        + (if (.uses // []) | length > 0 then "   uses: \(.uses | join(", "))" else "" end)
        + why + "\n"
        + (if .route == "cloud" then "  sent to Claude word for word, plus the approved contract of each part it uses:\n"
           else "  task (stays on this machine):\n" end)
        + (.task | split("\n") | map("    " + .) | join("\n"))' <<<"$PLAN"
}

if [[ "$DRY_RUN" == 1 ]]; then
    printf '=== SPLIT PLAN (mode %s, dry run: nothing will run) ===' "$MODE"
    render_plan; echo
    _log dry-run "$N_PARTS" "$N_LOCAL" "$N_CLOUD" "$N_FORCED"
    exit 0
fi

{
    printf '\n=== SPLIT PLAN (mode %s) ===' "$MODE"
    render_plan
    printf '\n=== local parts run first; each contract is shown for approval before Claude sees it.\n'
    printf '=== run this plan? [y/N] '
} > /dev/tty
_ans=""
IFS= read -r _ans < /dev/tty || _ans=""
case "$_ans" in y|Y|yes|YES) : ;; *)
    say "plan not approved; nothing was run"
    _log refused "$N_PARTS" "$N_LOCAL" "$N_CLOUD" "$N_FORCED"; exit 15 ;;
esac

# --- rollback -----------------------------------------------------------------
# Every declared artifact is backed up (or noted as absent) before anything
# runs. A failure anywhere puts every one of them back: a half-applied split is
# a local artifact with nothing calling it, or a playbook calling nothing.
# Undeclared files a local part touched are not covered — see ORCHESTRATOR.md.
TMPD="$(mktemp -d)"; chmod 700 "$TMPD"
mkdir -p "$TMPD/backup" "$TMPD/stage" "$TMPD/claude-cwd"
mapfile -t ARTS < <(jq -r '.parts[].artifact' <<<"$PLAN")
# The plan's paths were checked as text. A symlinked directory inside the work
# tree can still point anywhere, so every artifact is resolved and must land
# inside the directory the split was started from.
_root="$(realpath -- "$PWD")"
for art in "${ARTS[@]}"; do
    _real="$(realpath -m -- "$art" 2>/dev/null)"
    [[ -n "$_real" && "$_real" == "$_root"/* ]] || {
        say "refusing: a planned artifact resolves outside the working directory"
        rm -rf "$TMPD"; _log refused-path "$N_PARTS" "$N_LOCAL" "$N_CLOUD" "$N_FORCED"; exit 14; }
done
FINISHED=0
for i in "${!ARTS[@]}"; do
    [[ -e "${ARTS[$i]}" ]] && cp -p -- "${ARTS[$i]}" "$TMPD/backup/$i" 2>/dev/null
done
# shellcheck disable=SC2317  # invoked from fail() and the EXIT trap
rollback() {
    local i
    for i in "${!ARTS[@]}"; do
        if [[ -e "$TMPD/backup/$i" ]]; then cp -p -- "$TMPD/backup/$i" "${ARTS[$i]}" 2>/dev/null
        else rm -f -- "${ARTS[$i]}" 2>/dev/null; fi
    done
}
# shellcheck disable=SC2317  # invoked by the traps
_on_exit() { [[ "$FINISHED" == 1 ]] || rollback; rm -rf "$TMPD"; }
trap '_on_exit' EXIT
trap 'say "interrupted; rolling back"; exit 130' INT TERM

fail() { # fail <exit code> <status> <message>
    say "$3; rolled back every artifact in the plan"
    _log "$2" "$N_PARTS" "$N_LOCAL" "$N_CLOUD" "$N_FORCED"
    exit "$1"
}

# Claude's output is written by THIS script, not by a tool Claude holds, so it
# gets Claude's rules here: the same guard stack in hook mode, as if Claude had
# used its own Write tool. Checked before anything runs, so a plan that would
# end in a refused write never starts.
guard_stack_load hook || { say "guard stack unavailable; refusing"; exit 10; }
while IFS= read -r art; do
    # shellcheck disable=SC2034  # exec_gate reads these globals
    EXEC_TOOL=write_file
    # shellcheck disable=SC2034
    EXEC_PATH="$PWD/$art"
    exec_gate
    case "$EXEC_VERDICT" in
        deny:*) say "refusing: a cloud part would write where Claude may not (${EXEC_VERDICT#deny:})"
                _log refused-path "$N_PARTS" "$N_LOCAL" "$N_CLOUD" "$N_FORCED"; exit 14 ;;
        ask:*)  exec_confirm "${EXEC_VERDICT#ask:}" || { say "cloud artifact write not confirmed"
                _log refused-path "$N_PARTS" "$N_LOCAL" "$N_CLOUD" "$N_FORCED"; exit 15; } ;;
    esac
done < <(jq -r '.parts[]|select(.route=="cloud")|.artifact' <<<"$PLAN")

# --- 4. local parts -----------------------------------------------------------
declare -A CONTRACT=() HANDLE=()
mapfile -t LOCAL_IDS < <(jq -r '.parts[]|select(.route=="local")|.id' <<<"$PLAN")
for id in "${LOCAL_IDS[@]}"; do
    art="$(jq -r --arg id "$id" '.parts[]|select(.id==$id)|.artifact' <<<"$PLAN")"
    ptask="$(jq -r --arg id "$id" '.parts[]|select(.id==$id)|.task' <<<"$PLAN")"
    needed="$(jq -r --arg id "$id" '[.parts[]|select(.route=="cloud")|(.uses // [])[]]|index($id) != null' <<<"$PLAN")"
    abs="$PWD/$art"
    mkdir -p -- "$(dirname -- "$abs")" 2>/dev/null
    out="$TMPD/out-$id"
    ltask="$ptask

Write the result to this file: $abs"
    caller=human
    if [[ "$needed" == true ]]; then
        caller=cloud
        handle="$(contract_handle "$abs")" || fail 16 local-failed "could not allocate a handle for part $id"
        ltask="$ltask

A cloud model will write code that calls this file without ever seeing it. Your handle for this artifact is $handle. When you are done, finish with a declared interface contract that uses this handle, exactly as your instructions describe. In the contract, refer to the file ONLY by the handle: the path above must not appear in any field, and neither may any other path. Write the invocation with the handle in place of the file, for example: python3 $handle, followed by the arguments the script really takes, if any."
    fi
    say "part $id: running locally ..."
    ORCH_CALLER="$caller" ORCH_EXEC_OUT="$out" ORCH_EXEC_ENDPOINT="$ENDPOINT" \
        ORCH_EXEC_MODEL="$MODEL" ORCH_LOG="$ORCH_LOG" "$EXECUTOR" "$ltask"
    rc=$?
    [[ "$rc" == 0 ]] || fail 16 local-failed "part $id failed locally (executor exit $rc)"
    [[ -f "$abs" ]] || fail 16 local-failed "part $id finished without writing its artifact"
    if [[ "$needed" == true ]]; then
        c="$(cat "$out" 2>/dev/null)"
        # The contract must name the handle this part was given. One that names
        # another handle describes some other artifact — or none.
        [[ -n "$c" && "$c" == *"$handle"* ]] || fail 16 local-failed "part $id's contract does not carry its handle"
        CONTRACT[$id]="$c"; HANDLE[$id]="$handle"
    elif [[ -s "$out" ]]; then
        printf '\n[%s] %s\n' "$id" "$(cat "$out")" >&2
    fi
done

# --- 5. cloud parts -----------------------------------------------------------
strip_fence() { # one surrounding ``` fence, if the whole reply is wrapped in it
    awk '{ l[NR] = $0 } END {
        s = 1; e = NR
        if (NR >= 2 && l[1] ~ /^```/ && l[NR] ~ /^```[[:space:]]*$/) { s = 2; e = NR - 1 }
        for (i = s; i <= e; i++) print l[i] }'
}

mapfile -t CLOUD_IDS < <(jq -r '.parts[]|select(.route=="cloud")|.id' <<<"$PLAN")
for id in "${CLOUD_IDS[@]}"; do
    ptask="$(jq -r --arg id "$id" '.parts[]|select(.id==$id)|.task' <<<"$PLAN")"
    mapfile -t uses < <(jq -r --arg id "$id" '.parts[]|select(.id==$id)|(.uses // [])[]' <<<"$PLAN")
    prompt="You are writing one file that is part of a larger task. Reply with ONLY the complete contents of that file: no explanation before or after it, no Markdown fence.

Task:
$ptask"
    if (( ${#uses[@]} > 0 )); then
        prompt="$prompt

Interfaces you may call. Each was declared by its owner, and its implementation is deliberately not available to you. Call each exactly as its invocation says, and do not guess at what it does inside."
        for u in "${uses[@]}"; do prompt="$prompt

$u:
${CONTRACT[$u]}"; done
    fi
    # The word list, once more, on the exact text that will cross. Every piece
    # of it has been checked already; this is the check on the assembly.
    orch_floor_match "$prompt" && fail 18 floor "part $id: the word list matched the prompt for Claude"

    say "part $id: sending to Claude (no tools) ..."
    staged="$TMPD/stage/$id"
    # --tools "" and --strict-mcp-config: no Read, no Bash, no connectors. Run
    # from an empty directory. Claude answers from the prompt or not at all.
    ( cd "$TMPD/claude-cwd" && printf '%s' "$prompt" \
        | env -u ORCH_CALLER timeout "$CLOUD_TIMEOUT" "$CLAUDE_BIN" -p --tools "" --strict-mcp-config ) \
        > "$TMPD/raw-$id" 2>/dev/null
    rc=$?
    [[ "$rc" == 0 && -s "$TMPD/raw-$id" ]] || fail 17 cloud-failed "part $id: Claude did not return a result (exit $rc)"
    strip_fence < "$TMPD/raw-$id" > "$staged"
done

# --- 6. join ------------------------------------------------------------------
# Assembled HERE, where both halves may be seen: Claude wrote against the opaque
# handle, and only now, on this machine, does each handle become the local
# artifact's path relative to the working directory. Claude never learns it.
for id in "${CLOUD_IDS[@]}"; do
    art="$(jq -r --arg id "$id" '.parts[]|select(.id==$id)|.artifact' <<<"$PLAN")"
    body="$(cat "$TMPD/stage/$id"; printf x)"; body="${body%x}"
    for u in "${!HANDLE[@]}"; do
        u_art="$(jq -r --arg id "$u" '.parts[]|select(.id==$id)|.artifact' <<<"$PLAN")"
        body="${body//"${HANDLE[$u]}"/"$u_art"}"
    done
    printf '%s' "$body" > "$TMPD/stage/$id"
    mkdir -p -- "$(dirname -- "$art")" 2>/dev/null
    cp -- "$TMPD/stage/$id" "$art" || fail 17 cloud-failed "could not write $art"
done
FINISHED=1
_log "done" "$N_PARTS" "$N_LOCAL" "$N_CLOUD" "$N_FORCED"
echo "split done:"
jq -r '.parts[] | "  \(.artifact)  (\(.route))"' <<<"$PLAN"
exit 0
