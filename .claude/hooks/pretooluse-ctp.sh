#!/usr/bin/env bash
# pretooluse-ctp.sh — the authoritative agent-path gate for the tool bridge.
#
# Runs OUTSIDE the agent's command (a PreToolUse hook), so the agent cannot alter
# it. Reads the tool call on stdin as JSON and decides:
#   deny  — direct container/ctp access (bypass), a refused verb, a make lifecycle
#           verb, or a Read/Bash touch of a configured secret path.
#   ask   — a permitted wrapper call: the human confirms at this prompt (the Bash
#           tool's stdin is non-interactive, so confirmation cannot happen in the
#           wrapper for the agent path).
#   (silent exit 0) — no opinion; other permissions decide.
#
# The wrapper re-classifies from its own argv and is authoritative on the run;
# this hook is defense in depth plus the human prompt. Boundary values come from
# the config file, never from the caller's environment.
set -euo pipefail

_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ROOT="$(cd "$_HERE/../.." && pwd)"
# shellcheck source=scripts/lib/ctp-guard.sh disable=SC1091
source "$_ROOT/scripts/lib/ctp-guard.sh"
ctp_load_config "${CTP_BRIDGE_CONF:-$_ROOT/.ctp-bridge.conf}" || true

emit() { # emit <allow|deny|ask> <reason>
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":"%s"}}\n' \
        "$1" "$2"
    exit 0
}
pass() { exit 0; }  # no opinion

INPUT="$(cat)"
_json() { printf '%s' "$INPUT" | jq -r "$1" 2>/dev/null; }

TOOL="$(_json '.tool_name')"

# --- Read tool: block reads of secret paths ----------------------------------
if [[ "$TOOL" == "Read" ]]; then
    fp="$(_json '.tool_input.file_path')"
    [[ -n "$fp" ]] && ctp_is_secret_path "$fp" && \
        emit deny "reading a secret path into the transcript is refused: $fp"
    pass
fi

[[ "$TOOL" == "Bash" ]] || pass
CMD="$(_json '.tool_input.command')"
[[ -n "$CMD" ]] || pass

# --- secret-path reads via Bash ----------------------------------------------
# Tokenise loosely and test each token; the wrapper checks vault by existence, so
# a legitimate flow never needs to name these paths.
_stripq() { local t="$1"; t="${t#[\"\']}"; t="${t%[\"\']}"; printf '%s' "$t"; }
read -r -a _toks <<<"$CMD"
for _t in "${_toks[@]}"; do
    _c="$(_stripq "$_t")"
    _c="${_c#<}"   # redirection like <secret
    [[ -n "$_c" ]] || continue
    ctp_is_secret_path "$_c" && emit deny "command would read a secret path: $_c"
done

# --- split into command segments and inspect each command word ---------------
# Anchoring to the command WORD (after separators and env-assignment prefixes)
# avoids denying commands that merely mention "ctp", "docker" or "make" inside a
# comment, string or path — the string-matching false-positive this bridge warns
# about. Best-effort; the wrapper re-checks and is authoritative.
_seg_cmdword() { # prints the effective first word of a segment (env prefixes stripped)
    local seg="$1" w
    read -r -a _w <<<"$seg"
    for w in "${_w[@]}"; do
        [[ "$w" == *=* && "$w" != */* ]] && continue   # skip FOO=bar prefix
        printf '%s' "$w"; return 0
    done
    return 1
}
# _base <path> — basename without matching a mere substring: test-ctp-bridge.sh
# must NOT read as ctp-bridge.sh.
_base() { local p="$1"; printf '%s' "${p##*/}"; }

# Replace segment separators with newlines, then examine each segment. A wrapper
# INVOCATION (ctp-bridge.sh actually executed, directly or via an interpreter) is
# classified; a segment that merely names the path (chmod, grep, cat, running the
# test file) is not — that was the substring false-positive this bridge warns of.
_segs="${CMD//&&/$'\n'}"; _segs="${_segs//||/$'\n'}"
_segs="${_segs//;/$'\n'}"; _segs="${_segs//|/$'\n'}"
while IFS= read -r _seg; do
    [[ -n "$_seg" ]] || continue
    _cw="$(_seg_cmdword "$_seg")" || continue
    read -r -a _sw <<<"$_seg"

    # Is the wrapper the executed command in this segment?
    _wrapper_args=()
    if [[ "$(_base "$_cw")" == "ctp-bridge.sh" ]]; then
        _seen=0
        for _tok in "${_sw[@]}"; do
            if [[ "$_seen" == 1 ]]; then _wrapper_args+=("$_tok"); continue; fi
            [[ "$(_base "$_tok")" == "ctp-bridge.sh" ]] && _seen=1
        done
        _is_wrapper=1
    elif [[ "$_cw" =~ ^(bash|sh|zsh|dash)$ ]]; then
        _is_wrapper=0; _seen=0
        for _tok in "${_sw[@]}"; do
            if [[ "$_seen" == 1 ]]; then _wrapper_args+=("$_tok"); continue; fi
            if [[ "$(_base "$_tok")" == "ctp-bridge.sh" ]]; then _seen=1; _is_wrapper=1; fi
        done
    else
        _is_wrapper=0
    fi

    if [[ "$_is_wrapper" == 1 ]]; then
        verdict="$(ctp_classify "${_wrapper_args[@]:-}")" && vrc=0 || vrc=$?
        if [[ "$vrc" -eq 0 ]]; then
            emit ask "confirm build-tooling run: ctp ${_wrapper_args[*]:-}"
        else
            emit deny "ctp bridge refuses this: ${verdict#refuse }"
        fi
    fi

    case "$_cw" in
        make)
            case " ${_sw[*]} " in
                *" start "*|*" restart "*|*" stop "*)
                    emit deny "make start/restart/stop is owner-run (interactive credential entry), not agent-run" ;;
            esac ;;
        ctp)
            emit deny "reach ctp through scripts/ctp-bridge.sh, not a bare ctp invocation" ;;
        docker)
            if [[ " ${_sw[*]} " == *" exec "* && ( "$_seg" == *"$(ctp_container)"* || "$_seg" == *catapult-* ) ]]; then
                emit deny "reach ctp through scripts/ctp-bridge.sh, not docker exec into the container"
            fi ;;
    esac
done <<<"$_segs"

pass
