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
# Installed at user scope (~/.claude/hooks) on the box, but also runs from the
# repo in dev/tests. Resolve the guard lib across both layouts; first hit wins.
_find_guard() {
    local c
    for c in "${CTP_GUARD_LIB:-}" \
             "$HOME/.local/lib/ctp-bridge/ctp-guard.sh" \
             "$_HERE/ctp-guard.sh" \
             "$_HERE/../../scripts/lib/ctp-guard.sh"; do
        [[ -n "$c" && -f "$c" ]] && { printf '%s' "$c"; return 0; }
    done
    return 1
}
_GUARD="$(_find_guard)" || exit 0   # no guard, no opinion (fail open to other perms)
# shellcheck source=scripts/lib/ctp-guard.sh disable=SC1091
source "$_GUARD"
ctp_load_config "${CTP_BRIDGE_CONF:-$HOME/.ctp-bridge.conf}" || true

# Resolve a sibling lib across the same layouts (installed user-scope, or repo/tests).
_find_lib() { # _find_lib <basename> <env-override>
    local c
    for c in "${2:-}"              "$HOME/.local/lib/ctp-bridge/$1"              "$_HERE/$1"              "$_HERE/../../scripts/lib/$1"; do
        [[ -n "$c" && -f "$c" ]] && { printf '%s' "$c"; return 0; }
    done
    return 1
}
# cmd-segment.sh carries the segmentation the ctp path below depends on; without
# it we cannot classify anything, so fail open (no opinion) exactly as for a
# missing guard.
_SEG_LIB="$(_find_lib cmd-segment.sh "${CMD_SEGMENT_LIB:-}")" || exit 0
# shellcheck source=scripts/lib/cmd-segment.sh disable=SC1091
source "$_SEG_LIB"
# safety-guard.sh adds the destructive-command classifier. Optional: if absent,
# the ctp gate still works and the destructive check is simply skipped.
_SAFETY_LIB="$(_find_lib safety-guard.sh "${SAFETY_GUARD_LIB:-}")" || _SAFETY_LIB=""
if [[ -n "$_SAFETY_LIB" ]]; then
    # shellcheck source=scripts/lib/safety-guard.sh disable=SC1091
    source "$_SAFETY_LIB"
    safety_load_config "${SAFETY_GUARD_CONF:-$HOME/.config/safety-guard.conf}" || true
fi

emit() { # emit <allow|deny|ask> <reason>
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":"%s"}}\n' \
        "$1" "$2"
    exit 0
}
pass() { exit 0; }  # no opinion

# A path is guarded if it is a configured secret OR the approval token (which the
# agent must not read or forge). Used for Read/Write/Edit file_path and Bash args.
_is_guarded_path() {
    ctp_is_secret_path "$1" && return 0
    [[ "$1" == "$(ctp_approval_file)" ]] && return 0
    return 1
}

# _write_approval <argv-string> — record a single-use, argv-bound, short-TTL token
# so the wrapper knows the human approved THIS invocation at the prompt below.
_write_approval() {
    local dir; dir="$(ctp_state_dir)"
    mkdir -p "$dir" 2>/dev/null || return 0
    ( umask 077; printf '%s\t%s\n' "$(( $(date +%s) + 180 ))" "$1" > "$dir/approval" 2>/dev/null )
}

INPUT="$(cat)"
_json() { printf '%s' "$INPUT" | jq -r "$1" 2>/dev/null; }

TOOL="$(_json '.tool_name')"

# --- Read/Write/Edit: block touching a guarded path --------------------------
if [[ "$TOOL" == "Read" || "$TOOL" == "Write" || "$TOOL" == "Edit" ]]; then
    fp="$(_json '.tool_input.file_path')"
    if [[ -n "$fp" ]]; then
        _is_guarded_path "$fp" && \
            emit deny "a guarded path (secret or approval token) is off-limits to tools: $fp"
        # C1: keep Org PII/IP out of the transcript — deny reading/writing a
        # configured sensitive path (hooks cannot redact tool OUTPUT, so a read
        # must be denied, not sanitised).
        ctp_is_pii_path "$fp" && \
            emit deny "a guarded Org-sensitive (PII/IP) path is off-limits to tools: $fp"
    fi
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
    _c="${_c#>}"   # redirection like >token
    [[ -n "$_c" ]] || continue
    _is_guarded_path "$_c" && emit deny "command would touch a guarded path: $_c"
    ctp_is_pii_path "$_c" && \
        emit deny "command would touch a guarded Org-sensitive (PII/IP) path: $_c"
done

# _base <path> — basename without matching a mere substring: test-ctp-bridge.sh
# must NOT read as ctp-bridge.sh.
_base() { local p="$1"; printf '%s' "${p##*/}"; }
# _is_wrapper_name <path> — the wrapper is `ctp-bridge` when installed on PATH and
# `ctp-bridge.sh` in the repo/tests. Match both; NOT test-ctp-bridge.sh.
_is_wrapper_name() { case "$(_base "$1")" in ctp-bridge|ctp-bridge.sh) return 0 ;; *) return 1 ;; esac; }

# _strip_redirection <args...> — echo the args with shell redirection removed, so
# the argv the hook classifies and binds matches what the wrapper actually
# receives (the shell strips `2>&1`, `> file`, `2>err` etc. before the wrapper
# sees its argv). Box names never contain < or >, so this is safe.
_strip_redirection() {
    local t skip=0 out=()
    for t in "$@"; do
        if [[ "$skip" == 1 ]]; then skip=0; continue; fi           # operand of a bare operator
        if [[ "$t" =~ ^[0-9]*(\>\>|\>|\<)$ || "$t" =~ ^\&\>\>?$ ]]; then skip=1; continue; fi  # >  >>  2>  <  &>  (+ target next)
        if [[ "$t" == *'>'* || "$t" == *'<'* ]]; then continue; fi  # fused (>file, 2>&1, &>file, 2>err)
        out+=("$t")
    done
    printf '%s\n' "${out[@]}"
}


# A wrapper INVOCATION (ctp-bridge.sh actually executed, directly or via an
# interpreter) is classified; a segment that merely names the path (chmod, grep,
# cat, running the test file) is not — the substring false-positive this warns of.
_split_segments "$CMD"
for _seg in "${_SEGMENTS[@]:-}"; do
    [[ -n "$_seg" ]] || continue
    _cw="$(_seg_cmdword "$_seg")" || continue
    read -r -a _sw <<<"$_seg"

    # Is the wrapper the executed command in this segment?
    _wrapper_args=()
    if _is_wrapper_name "$_cw"; then
        _seen=0
        for _tok in "${_sw[@]}"; do
            if [[ "$_seen" == 1 ]]; then _wrapper_args+=("$_tok"); continue; fi
            _is_wrapper_name "$_tok" && _seen=1
        done
        _is_wrapper=1
    elif [[ "$_cw" =~ ^(bash|sh|zsh|dash)$ ]]; then
        _is_wrapper=0; _seen=0
        for _tok in "${_sw[@]}"; do
            if [[ "$_seen" == 1 ]]; then _wrapper_args+=("$_tok"); continue; fi
            if _is_wrapper_name "$_tok"; then _seen=1; _is_wrapper=1; fi
        done
    else
        _is_wrapper=0
    fi

    if [[ "$_is_wrapper" == 1 ]]; then
        # Strip shell redirection so the classified/bound argv matches what the
        # wrapper actually receives (the shell removes `2>&1`, `> file`, etc.).
        _clean_args=()
        while IFS= read -r _ca; do _clean_args+=("$_ca"); done < <(_strip_redirection "${_wrapper_args[@]:-}")
        verdict="$(ctp_classify "${_clean_args[@]:-}")" && vrc=0 || vrc=$?
        if [[ "$vrc" -eq 0 ]]; then
            # Human confirms at this prompt; leave the wrapper a token bound to the
            # exact argv it will receive so it runs without a second (impossible,
            # no-TTY) prompt.
            _write_approval "${_clean_args[*]:-}"
            emit ask "confirm build-tooling run: ctp ${_clean_args[*]:-}"
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

    # Destructive-action gate (safety-guard.sh): generic filesystem/infra/db
    # commands. ctp/make/docker-exec are handled above; git is out of scope (B).
    if [[ -n "$_SAFETY_LIB" ]]; then
        _sv="$(safety_classify "$_seg")" || true
        case "$_sv" in
            ask:*)  emit ask  "${_sv#ask:}" ;;
            deny:*) emit deny "${_sv#deny:}" ;;
        esac
    fi
done

pass
