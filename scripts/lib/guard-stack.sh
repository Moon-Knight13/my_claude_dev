#!/usr/bin/env bash
# guard-stack.sh — the composed guard stack: ONE policy, two enforcement points.
#
# Enforcement point #1 is the PreToolUse hook, which fronts Claude's tools.
# Enforcement point #2 is the local-model executor, which does not go through
# Claude and therefore does not inherit that hook. Both call this library, so the
# policy cannot drift between them: a layer added here defends both, and a layer
# that stops working here fails loudly in both.
#
# It composes, in this order, per command segment:
#   cmd-segment.sh   segmentation (classify the command WORD + args, never a raw
#                    string — so a heredoc body or commit message is not misread)
#   ctp-guard.sh     build tooling, bare-ctp and container-exec bypass
#   guarded paths    configured secret paths + the approval token
#   C1 PII paths     configured Org PII/IP paths  (MODE-DEPENDENT, see below)
#   safety-guard.sh  destructive filesystem / infra / database commands
#   git-guard.sh     destructive git operations (control 2b)
#
# CALLER MODE — the only layer that varies:
#   hook      C1 PII paths are DENIED. Keeps Org PII/IP out of Claude's
#             transcript; hooks cannot redact tool output, so the read must be
#             denied rather than sanitised.
#   executor  C1 PII paths are ALLOWED (decision E5). The local executor is the
#             component whose purpose is to read that material without egress —
#             enforcing C1 verbatim would make it unable to do its job. The
#             carve-out is paid for on the RETURN path (interface-only disclosure,
#             decision E6), not waived.
# Secret paths are denied in BOTH modes: reading Org data is the executor's job;
# reading credentials is not.
#
# API:
#   guard_stack_load [mode]            resolve + source the layer libs and load
#                                      their configs. Returns non-zero if a
#                                      REQUIRED layer is missing, so the caller
#                                      decides how to fail (the hook fails open to
#                                      other permissions; the executor must not).
#   guard_stack_classify_path <path>   sets GUARD_STACK_VERDICT to
#                                      ""|"deny:<reason>"  (file-path shaped tool
#                                      calls: Read/Write/Edit)
#   guard_stack_classify_command <cmd> sets GUARD_STACK_VERDICT to
#                                      ""|"ask:<reason>"|"deny:<reason>".
#                                      First verdict wins, layers in the order
#                                      above, segments left to right.
#
# Both SET A GLOBAL rather than printing, deliberately. A caller that captured the
# verdict with $(...) would run the classifier in a subshell, and the approval argv
# below — set as a side effect — would be discarded silently, disabling the token
# binding with no error anywhere. Returning by global keeps the verdict and its
# side data in the caller's shell, together.
#
# When a command's verdict is an `ask` from the ctp wrapper path, the cleaned argv
# is left in GUARD_STACK_APPROVAL_ARGV so the caller can bind an approval token to
# the exact invocation the wrapper will receive. The token itself is the caller's
# business — this library classifies, it does not grant.

# This library returns its results by GLOBAL (GUARD_STACK_VERDICT,
# GUARD_STACK_APPROVAL_ARGV) rather than on stdout — see the API note above. Every
# assignment to them is read by a caller, so shellcheck's unused-variable warning
# is wrong for this file specifically.
# shellcheck disable=SC2034

# Resolve a layer lib across both layouts (installed user-scope on the box, or the
# repo in dev/tests). Env override first, then next to this library, then the
# installed dir, then the repo tree. First hit wins.
_guard_stack_find() { # _guard_stack_find <basename> <env-override>
    local c _self
    _self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    for c in "${2:-}" \
             "$_self/$1" \
             "$HOME/.local/lib/ctp-bridge/$1" \
             "$_self/../../scripts/lib/$1"; do
        [[ -n "$c" && -f "$c" ]] && { printf '%s' "$c"; return 0; }
    done
    return 1
}

GUARD_STACK_MODE="hook"
_GS_SAFETY_LIB=""
_GS_GITGUARD_LIB=""

guard_stack_load() { # guard_stack_load [hook|executor]
    case "${1:-hook}" in
        hook|executor) GUARD_STACK_MODE="${1:-hook}" ;;
        *) return 2 ;;   # an unknown mode is a caller bug, not a policy decision
    esac

    # REQUIRED layers. ctp-guard carries the config parse and the path predicates;
    # cmd-segment carries the segmentation everything else classifies against.
    # Without either we cannot classify anything at all.
    local guard seg
    guard="$(_guard_stack_find ctp-guard.sh "${CTP_GUARD_LIB:-}")" || return 1
    # shellcheck source=scripts/lib/ctp-guard.sh disable=SC1091
    source "$guard"
    ctp_load_config "${CTP_BRIDGE_CONF:-$HOME/.ctp-bridge.conf}" || true

    seg="$(_guard_stack_find cmd-segment.sh "${CMD_SEGMENT_LIB:-}")" || return 1
    # shellcheck source=scripts/lib/cmd-segment.sh disable=SC1091
    source "$seg"

    # OPTIONAL layers. Absent ⇒ that check is skipped and everything else still
    # works; this mirrors the behaviour the hook has always had.
    _GS_SAFETY_LIB="$(_guard_stack_find safety-guard.sh "${SAFETY_GUARD_LIB:-}")" || _GS_SAFETY_LIB=""
    if [[ -n "$_GS_SAFETY_LIB" ]]; then
        # shellcheck source=scripts/lib/safety-guard.sh disable=SC1091
        source "$_GS_SAFETY_LIB"
        safety_load_config "${SAFETY_GUARD_CONF:-$HOME/.config/safety-guard.conf}" || true
    fi
    _GS_GITGUARD_LIB="$(_guard_stack_find git-guard.sh "${GIT_GUARD_LIB:-}")" || _GS_GITGUARD_LIB=""
    if [[ -n "$_GS_GITGUARD_LIB" ]]; then
        # shellcheck source=scripts/lib/git-guard.sh disable=SC1091
        source "$_GS_GITGUARD_LIB"
        gitguard_load_config "${GIT_GUARD_CONF:-$HOME/.config/git-guard.conf}" || true
    fi
    return 0
}

# A path is guarded if it is a configured secret OR the approval token (which no
# caller may read or forge). Denied in every mode.
_gs_is_guarded_path() {
    ctp_is_secret_path "$1" && return 0
    [[ "$1" == "$(ctp_approval_file)" ]] && return 0
    return 1
}

# C1: Org PII/IP paths. The one mode-dependent layer (see header).
_gs_is_denied_pii_path() {
    [[ "$GUARD_STACK_MODE" == "hook" ]] || return 1
    ctp_is_pii_path "$1"
}

GUARD_STACK_VERDICT=""

guard_stack_classify_path() { # guard_stack_classify_path <path>
    local fp="$1"
    GUARD_STACK_VERDICT=""
    [[ -n "$fp" ]] || return 0
    if _gs_is_guarded_path "$fp"; then
        GUARD_STACK_VERDICT="deny:a guarded path (secret or approval token) is off-limits to tools: $fp"; return 0
    fi
    if _gs_is_denied_pii_path "$fp"; then
        GUARD_STACK_VERDICT="deny:a guarded Org-sensitive (PII/IP) path is off-limits to tools: $fp"; return 0
    fi
    return 0
}

_gs_stripq() { local t="$1"; t="${t#[\"\']}"; t="${t%[\"\']}"; printf '%s' "$t"; }
# basename without matching a mere substring: test-ctp-bridge.sh must NOT read as
# ctp-bridge.sh.
_gs_base() { local p="$1"; printf '%s' "${p##*/}"; }
# the wrapper is `ctp-bridge` installed on PATH and `ctp-bridge.sh` in the repo.
_gs_is_wrapper_name() { case "$(_gs_base "$1")" in ctp-bridge|ctp-bridge.sh) return 0 ;; *) return 1 ;; esac; }

# echo args with shell redirection removed, so the argv classified and bound
# matches what the wrapper actually receives (the shell strips `2>&1`, `> file`,
# `2>err` etc. before the wrapper sees its argv). Box names never contain < or >.
_gs_strip_redirection() {
    local t skip=0 out=()
    for t in "$@"; do
        if [[ "$skip" == 1 ]]; then skip=0; continue; fi
        if [[ "$t" =~ ^[0-9]*(\>\>|\>|\<)$ || "$t" =~ ^\&\>\>?$ ]]; then skip=1; continue; fi
        if [[ "$t" == *'>'* || "$t" == *'<'* ]]; then continue; fi
        out+=("$t")
    done
    printf '%s\n' "${out[@]}"
}

GUARD_STACK_APPROVAL_ARGV=()

guard_stack_classify_command() { # guard_stack_classify_command <command>
    local CMD="$1"
    GUARD_STACK_APPROVAL_ARGV=()
    GUARD_STACK_VERDICT=""
    [[ -n "$CMD" ]] || return 0

    # --- guarded-path touches, token level -----------------------------------
    # Tokenise loosely and test each token; a legitimate flow never needs to name
    # these paths.
    local _t _c _toks
    read -r -a _toks <<<"$CMD"
    for _t in "${_toks[@]}"; do
        _c="$(_gs_stripq "$_t")"
        _c="${_c#<}"   # redirection like <secret
        _c="${_c#>}"   # redirection like >token
        [[ -n "$_c" ]] || continue
        if _gs_is_guarded_path "$_c"; then
            GUARD_STACK_VERDICT="deny:command would touch a guarded path: $_c"; return 0
        fi
        if _gs_is_denied_pii_path "$_c"; then
            GUARD_STACK_VERDICT="deny:command would touch a guarded Org-sensitive (PII/IP) path: $_c"; return 0
        fi
    done

    # --- per-segment layers ---------------------------------------------------
    local _seg _cw _sw _tok _seen _is_wrapper _wrapper_args _clean_args _ca verdict vrc _sv _gv
    _split_segments "$CMD"
    for _seg in "${_SEGMENTS[@]:-}"; do
        [[ -n "$_seg" ]] || continue
        _cw="$(_seg_cmdword "$_seg")" || continue
        read -r -a _sw <<<"$_seg"

        # Is the wrapper the executed command in this segment? A segment that
        # merely NAMES the path (chmod, grep, cat, running the test file) is not.
        _wrapper_args=()
        if _gs_is_wrapper_name "$_cw"; then
            _seen=0
            for _tok in "${_sw[@]}"; do
                if [[ "$_seen" == 1 ]]; then _wrapper_args+=("$_tok"); continue; fi
                _gs_is_wrapper_name "$_tok" && _seen=1
            done
            _is_wrapper=1
        elif [[ "$_cw" =~ ^(bash|sh|zsh|dash)$ ]]; then
            _is_wrapper=0; _seen=0
            for _tok in "${_sw[@]}"; do
                if [[ "$_seen" == 1 ]]; then _wrapper_args+=("$_tok"); continue; fi
                if _gs_is_wrapper_name "$_tok"; then _seen=1; _is_wrapper=1; fi
            done
        else
            _is_wrapper=0
        fi

        if [[ "$_is_wrapper" == 1 ]]; then
            _clean_args=()
            while IFS= read -r _ca; do _clean_args+=("$_ca"); done < <(_gs_strip_redirection "${_wrapper_args[@]:-}")
            verdict="$(ctp_classify "${_clean_args[@]:-}")" && vrc=0 || vrc=$?
            if [[ "$vrc" -eq 0 ]]; then
                # Leave the caller the exact argv, so it can bind an approval to
                # THIS invocation. Granting is the caller's business, not ours.
                GUARD_STACK_APPROVAL_ARGV=("${_clean_args[@]:-}")
                GUARD_STACK_VERDICT="ask:confirm build-tooling run: ctp ${_clean_args[*]:-}"; return 0
            else
                GUARD_STACK_VERDICT="deny:ctp bridge refuses this: ${verdict#refuse }"; return 0
            fi
        fi

        case "$_cw" in
            make)
                case " ${_sw[*]} " in
                    *" start "*|*" restart "*|*" stop "*)
                        GUARD_STACK_VERDICT="deny:make start/restart/stop is owner-run (interactive credential entry), not agent-run"; return 0 ;;
                esac ;;
            ctp)
                GUARD_STACK_VERDICT="deny:reach ctp through scripts/ctp-bridge.sh, not a bare ctp invocation"; return 0 ;;
            docker)
                if [[ " ${_sw[*]} " == *" exec "* && ( "$_seg" == *"$(ctp_container)"* || "$_seg" == *catapult-* ) ]]; then
                    GUARD_STACK_VERDICT="deny:reach ctp through scripts/ctp-bridge.sh, not docker exec into the container"; return 0
                fi ;;
        esac

        # Destructive-action gate: generic filesystem/infra/db commands.
        # ctp/make/docker-exec are handled above; git is out of its scope.
        if [[ -n "$_GS_SAFETY_LIB" ]]; then
            _sv="$(safety_classify "$_seg")" || true
            case "$_sv" in
                ask:*|deny:*) GUARD_STACK_VERDICT="$_sv"; return 0 ;;
            esac
        fi

        # Destructive-git gate (control 2b): force-push, reset --hard, clean -f,
        # branch -D, checkout --force.
        if [[ -n "$_GS_GITGUARD_LIB" ]]; then
            _gv="$(gitguard_classify "$_seg")" || true
            case "$_gv" in
                ask:*|deny:*) GUARD_STACK_VERDICT="$_gv"; return 0 ;;
            esac
        fi
    done
    return 0
}
