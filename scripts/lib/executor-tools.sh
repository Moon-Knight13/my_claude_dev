#!/usr/bin/env bash
# executor-tools.sh — the tool vocabulary, gating and logging primitives for the
# local-model executor (enforcement point #2). Sourced, not executed.
#
# The executor runs shell and file work on the box for tasks too sensitive to send
# to a cloud model. It does NOT go through Claude, so it does not inherit the
# PreToolUse hook: everything it does has to be gated here, by the same
# guard-stack.sh the hook uses, or the two enforcement points drift apart.
#
# Three properties this file exists to hold:
#
#   1. THE VOCABULARY IS CLOSED. The model selects from a fixed set of tools; it
#      cannot name a new one. exec_parse_call rejects anything else as a parse
#      error rather than dispatching it. This is the structural half of injection
#      containment: text read out of a file can at most ask for a tool that
#      already exists.
#
#   2. EVERY TOOL IS GATED THE SAME WAY. read_file is judged exactly as
#      run_command is. Structure exists for auditability, never for differential
#      trust — a write_file to a secret path is the same denial as a shell command
#      naming it. A structured tool that skipped a layer because it "looks safe"
#      would be the hole.
#
#   3. THE LOG INDEXES NOTHING. Tool calls carry real filesystem paths, and
#      .ai/orchestrator-log.jsonl is readable by Claude. Logged targets are
#      therefore opaque handles (decision E9), stable within a run so a sequence
#      is still followable, meaningless outside it.
#
# API:
#   exec_tools_init                 start a run: fresh handle map, fresh run id
#   exec_handle <string>            stable opaque handle for a string (h1, h2, …)
#   exec_log_token <token>          a token safe to log: handles anything path-shaped
#   exec_caller_is_human            rc 0 if this run may return raw output (R8)
#   exec_tty_ok                     rc 0 if BOTH stdin and stdout are a TTY (R9)
#   exec_confirm <reason>           rc 0 if a human confirmed at the TTY (E2)
#   exec_parse_call <model-reply>   -> EXEC_TOOL / EXEC_PATH / EXEC_CONTENT /
#                                      EXEC_COMMAND / EXEC_DONE / EXEC_ANSWER /
#                                      EXEC_PARSE_ERR
#   exec_gate                       -> EXEC_VERDICT ("" | ask:<reason> | deny:<reason>)
#
# Like guard-stack.sh, the parse and gate calls return by GLOBAL rather than on
# stdout: a $(…) capture would run them in a subshell and quietly discard the rest
# of the parsed call.
# shellcheck disable=SC2034

_ET_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/guard-stack.sh disable=SC1091
source "${GUARD_STACK_LIB:-$_ET_SELF/guard-stack.sh}"

# The closed set. Adding a name here is a deliberate change to the executor's
# reach, reviewed as such; nothing at runtime can extend it.
EXEC_TOOLS="read_file write_file list_dir run_command"

EXEC_RUN_ID=""
_EXEC_HMAP=""

exec_tools_init() {
    EXEC_RUN_ID="$(od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
    [[ -n "$EXEC_RUN_ID" ]] || EXEC_RUN_ID="$$"
    _EXEC_HMAP="$(mktemp "${TMPDIR:-/tmp}/orch-handles.XXXXXX")"
    EXEC_TOOL=""; EXEC_PATH=""; EXEC_CONTENT=""; EXEC_COMMAND=""
    EXEC_ANSWER=""; EXEC_DONE=0; EXEC_PARSE_ERR=""; EXEC_VERDICT=""; EXEC_CONTRACT=""
}

# exec_handle <string> — the opaque handle for a string, allocated on first sight
# and stable for the rest of the run.
#
# File-backed rather than an in-memory array on purpose: the executor calls this
# from inside $(…) while building log lines, and a subshell's array assignment
# would be thrown away — every distinct path would come back as h1, which is worse
# than useless in a log meant to be followed.
exec_handle() {
    [[ -n "$_EXEC_HMAP" ]] || return 0
    local enc found
    # base64 so a path containing a tab, a newline or a glob cannot break the map
    enc="$(printf '%s' "$1" | base64 2>/dev/null | tr -d '\n')"
    found="$(awk -F'\t' -v k="$enc" '$2==k {print $1; exit}' "$_EXEC_HMAP" 2>/dev/null)"
    if [[ -n "$found" ]]; then printf '%s' "$found"; return 0; fi
    local n; n=$(( $(wc -l < "$_EXEC_HMAP" 2>/dev/null || echo 0) + 1 ))
    printf 'h%s\t%s\n' "$n" "$enc" >> "$_EXEC_HMAP"
    printf 'h%s' "$n"
}

# exec_log_token <token> — anything that could be a path becomes a handle; a plain
# command word (`rm`, `git`) is logged as itself, because knowing WHICH verb ran is
# the whole point of the log and the verb names nothing.
exec_log_token() {
    local t="$1"
    [[ -n "$t" ]] || { printf ''; return 0; }
    case "$t" in
        */*|'~'*) exec_handle "$t" ;;
        *)        printf '%s' "$t" ;;
    esac
}

# --- caller and human presence ---------------------------------------------
# R8: until the interface contract (#63) exists, there is no format in which the
# executor could safely answer a cloud-bound caller, so it answers none. Anything
# other than an explicit (or defaulted) human caller is refused — an unrecognised
# value fails closed rather than being treated as human.
exec_caller_is_human() {
    case "${ORCH_CALLER:-human}" in
        human) return 0 ;;
        *)     return 1 ;;
    esac
}

# R9: one signal, checked one way. stdin AND stdout must both be a TTY, so
# `orchestrate.sh … | tee log` counts as non-human — which errs safe.
exec_tty_ok() { [[ -t 0 && -t 1 ]]; }

# E2: an `ask` is confirmed by the human at the controlling TTY. No TTY, no
# confirmation, no run — the Bash-tool situation that made the hook necessary in
# the first place.
exec_confirm() { # exec_confirm <reason>
    exec_tty_ok || return 1
    local ans=""
    printf '\n[executor] %s\n[executor] run it? [y/N] ' "$1" > /dev/tty
    IFS= read -r ans < /dev/tty || return 1
    case "$ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# --- parsing the model's reply ---------------------------------------------
EXEC_TOOL=""; EXEC_PATH=""; EXEC_CONTENT=""; EXEC_COMMAND=""
EXEC_ANSWER=""; EXEC_DONE=0; EXEC_PARSE_ERR=""; EXEC_CONTRACT=""

exec_parse_call() { # exec_parse_call <model reply text>
    EXEC_TOOL=""; EXEC_PATH=""; EXEC_CONTENT=""; EXEC_COMMAND=""
    EXEC_ANSWER=""; EXEC_DONE=0; EXEC_PARSE_ERR=""; EXEC_CONTRACT=""
    local raw="${1:-}" obj

    # Local models wrap the object in prose or a ```json fence more often than
    # not. Take the outermost brace span and let jq decide whether it is an
    # object; guessing less than that would reject perfectly good calls, guessing
    # more would start interpreting the prose.
    if [[ "$raw" != *"{"* || "$raw" != *"}"* ]]; then
        EXEC_PARSE_ERR="reply was not a JSON tool call object"; return 0
    fi
    obj="{${raw#*\{}"; obj="${obj%\}*}}"
    if ! printf '%s' "$obj" | jq -e 'type=="object"' >/dev/null 2>&1; then
        EXEC_PARSE_ERR="reply was not a JSON tool call object"; return 0
    fi

    if [[ "$(printf '%s' "$obj" | jq -r 'if .done == true then 1 else 0 end')" == 1 ]]; then
        EXEC_DONE=1
        EXEC_ANSWER="$(printf '%s' "$obj" | jq -r '.answer // ""')"
        # The proposed interface contract, for a cloud-bound caller (S3). Absent
        # for an ordinary local run — the human at the terminal gets the answer
        # itself, and needs no contract to read it.
        EXEC_CONTRACT="$(printf '%s' "$obj" | jq -c '.contract // empty' 2>/dev/null)"
        return 0
    fi

    local tool; tool="$(printf '%s' "$obj" | jq -r '.tool // ""')"
    case " $EXEC_TOOLS " in
        *" $tool "*) : ;;
        *)  EXEC_PARSE_ERR="unknown tool '${tool}'; the vocabulary is fixed: $EXEC_TOOLS"
            return 0 ;;
    esac

    EXEC_PATH="$(printf '%s' "$obj"    | jq -r '.path // ""')"
    EXEC_CONTENT="$(printf '%s' "$obj" | jq -r '.content // ""')"
    EXEC_COMMAND="$(printf '%s' "$obj" | jq -r '.command // ""')"

    case "$tool" in
        read_file|list_dir)
            [[ -n "$EXEC_PATH" ]] || { EXEC_PARSE_ERR="$tool requires a 'path'"; return 0; } ;;
        write_file)
            [[ -n "$EXEC_PATH" ]] || { EXEC_PARSE_ERR="write_file requires a 'path'"; return 0; } ;;
        run_command)
            [[ -n "$EXEC_COMMAND" ]] || { EXEC_PARSE_ERR="run_command requires a 'command'"; return 0; } ;;
    esac
    EXEC_TOOL="$tool"
    return 0
}

# --- gating ------------------------------------------------------------------
EXEC_VERDICT=""

# A path-bearing tool is judged BOTH as a path (the Read/Write/Edit shape) and as
# the shell command it is equivalent to. Two passes, not one, because the two
# classifiers cover different layers: the path pass carries the secret/PII
# predicates, the command pass carries the ctp, destructive-filesystem and
# destructive-git layers. Checking only one is how a structured tool becomes a
# quiet way round a guard.
_exec_gate_path() { # _exec_gate_path <path> <equivalent command>
    local p="$1" real
    # Judge the resolved path too. The guard classifies a STRING; the tool that
    # runs afterwards follows symlinks. Without this,
    # `ln -s ~/.ssh/id_ed25519 notes.txt` turns an allowed read into a credential
    # read and the verdict says nothing is wrong. -m so a path that does not exist
    # yet (a write target) still resolves through its existing parent directories.
    real="$(realpath -m -- "$p" 2>/dev/null)" || real=""
    guard_stack_classify_path "$p"
    if [[ -n "$GUARD_STACK_VERDICT" ]]; then EXEC_VERDICT="$GUARD_STACK_VERDICT"; return 0; fi
    if [[ -n "$real" && "$real" != "$p" ]]; then
        guard_stack_classify_path "$real"
        if [[ -n "$GUARD_STACK_VERDICT" ]]; then
            # Report the verdict against the path the model NAMED, not the one it
            # resolves to: naming the real target in the refusal would disclose the
            # location the guard exists to keep quiet.
            EXEC_VERDICT="deny:the resolved target of $p is a guarded path"; return 0
        fi
    fi
    guard_stack_classify_command "$2"
    EXEC_VERDICT="$GUARD_STACK_VERDICT"
}

# Shell gets the same symlink treatment as the structured tools: the stack's own
# token check compares the string it was given, so `cat notes.txt` where notes.txt
# links to a key reads as an ordinary file read. Anything token-shaped like a path
# is resolved and re-checked before the stack's verdict is taken.
#
# Scope, stated honestly: this covers a path written plainly in the command. It
# does not cover one built at runtime — through a variable, an expansion, or a
# shell that re-reads it. The stack has always had that limit; resolving the
# plain case closes the one an ordinary tool-using model actually produces.
_exec_gate_command() { # _exec_gate_command <command>
    local cmd="$1" tok real
    # Split on whitespace with pathname expansion OFF — an unquoted split would
    # glob a `*` in the command against the current directory and check files the
    # command never named, while dropping the token that was actually there.
    local -a _toks=() _restore_glob=1
    [[ -o noglob ]] && _restore_glob=0
    set -f
    # shellcheck disable=SC2206  # deliberate word-splitting; globbing is off
    _toks=($cmd)
    [[ "$_restore_glob" == 1 ]] && set +f
    for tok in "${_toks[@]}"; do
        case "$tok" in
            */*|'~'*) : ;;
            *) continue ;;
        esac
        tok="${tok#[\"\']}"; tok="${tok%[\"\']}"
        real="$(realpath -m -- "$tok" 2>/dev/null)" || continue
        [[ -n "$real" && "$real" != "$tok" ]] || continue
        guard_stack_classify_path "$real"
        if [[ -n "$GUARD_STACK_VERDICT" ]]; then
            EXEC_VERDICT="deny:the resolved target of $tok is a guarded path"; return 0
        fi
    done
    guard_stack_classify_command "$cmd"
    EXEC_VERDICT="$GUARD_STACK_VERDICT"
}

exec_gate() {
    EXEC_VERDICT=""
    case "$EXEC_TOOL" in
        read_file)   _exec_gate_path "$EXEC_PATH" "cat -- $EXEC_PATH" ;;
        list_dir)    _exec_gate_path "$EXEC_PATH" "ls -la -- $EXEC_PATH" ;;
        write_file)  _exec_gate_path "$EXEC_PATH" "tee -- $EXEC_PATH" ;;
        run_command) _exec_gate_command "$EXEC_COMMAND" ;;
        *)           EXEC_VERDICT="deny:no tool selected" ;;
    esac
    return 0
}
