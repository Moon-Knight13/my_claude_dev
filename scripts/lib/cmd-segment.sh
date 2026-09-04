#!/usr/bin/env bash
# cmd-segment.sh — quote/heredoc/subshell-aware shell command segmentation.
#
# Extracted verbatim from .claude/hooks/pretooluse-ctp.sh (commits #40-42) so BOTH
# the ctp gate and the destructive-action safety guard classify the SAME segmented
# command words instead of drifting apart. Sourced, not executed.
#
# Provides:
#   _seg_cmdword <segment>  -> effective first word (env-assignment prefixes stripped)
#   _split_segments <cmd>   -> populates the _SEGMENTS array with top-level segments,
#                              honouring quotes/heredocs and descending into $(…),
#                              `…`, <(…)/>(…) and ( subshells ).
# Best-effort by design (see the bridge's hygiene posture); a wrapper re-checks.

# --- split into command segments and inspect each command word ---------------
# Anchoring to the command WORD (after separators and env-assignment prefixes)
# avoids denying commands that merely mention "ctp", "docker" or "make" inside a
# comment, string or path — the string-matching false-positive this bridge warns
# about. Best-effort; the wrapper re-checks and is authoritative.
_seg_cmdword() { # prints the effective first word of a segment (env prefixes stripped)
    local seg="$1" w
    read -r -a _w <<<"$seg"
    for w in "${_w[@]}"; do
        [[ "$w" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] && continue   # skip FOO=bar prefix (value may contain /)
        printf '%s' "$w"; return 0
    done
    return 1
}

# _split_segments <cmd> — populate _SEGMENTS with the top-level shell command
# segments, honouring single/double quotes (which may span lines) and skipping
# heredoc bodies. A naive split on separators also breaks on the physical newlines
# INSIDE a quoted string or a `cat <<EOF` body, so a commit message or a written
# file whose line happens to start `ctp`/`make start` was mis-read as a command
# and denied (fail-closed, but it blocked legitimate multi-line Bash). Splitting
# with quote/heredoc awareness fixes that while still catching a real command on
# its own line, after a pipe, or after `&&`. Separators outside quotes: ; | || &&
# and newline (a lone & is left alone, so 2>&1 survives).
#
# It also descends into command substitutions — $(…), backticks (both of which the
# shell expands even inside "double quotes"), <(…)/>(…) process substitutions, and
# a ( subshell ) — so `echo "$(ctp …)"` and `x=$(ctp …)` are classified on the
# INNER command rather than sailing through as `echo`/`x=`. A ' single-quoted '
# occurrence expands nothing, so it is left alone (the command does not run there).
# Best-effort, matching the bridge's documented hygiene posture; the wrapper
# re-classifies any real run.
_SEGMENTS=()
_split_segments() {
    local cmd="$1"
    local -a _lines=()
    readarray -t _lines <<<"$cmd"
    local q="" esc=0 cur="" hd="" hd_dash=0 expect_delim=0 delim="" delim_q="" hd_ready=""
    local -a qsave=() kind=()            # stack of enclosing quote state, one per open $(…)/`…`/subshell
    local li nlines=${#_lines[@]}
    _flush() { [[ -n "${cur//[[:space:]]/}" ]] && _SEGMENTS+=("$cur"); cur=""; }
    # descend into / return from a nested command context (command substitution,
    # process substitution, or a ( subshell ). The nested command is itself split
    # and classified; on return the enclosing quote state is restored, because a
    # $(…) may sit inside a "double-quoted" string that continues after it.
    _push() { qsave+=("$q"); kind+=("$1"); q=""; esc=0; _flush; }
    _pop()  { local n=${#kind[@]}; [[ "$n" -gt 0 ]] || return 0; _flush; q="${qsave[n-1]}"; esc=0; unset 'qsave[n-1]' 'kind[n-1]'; }
    for (( li=0; li<nlines; li++ )); do
        local L="${_lines[li]}" m j ch nx
        # inside a heredoc body: swallow whole lines until the delimiter line
        if [[ -n "$hd" ]]; then
            local cmp="$L"
            [[ "$hd_dash" == 1 ]] && cmp="${cmp#"${cmp%%[!$'\t']*}"}"   # <<- strips leading tabs
            [[ "$cmp" == "$hd" ]] && { hd=""; hd_dash=0; }
            continue
        fi
        m=${#L}; j=0
        while (( j < m )); do
            ch="${L:j:1}"
            if [[ "$q" == "'" ]]; then
                cur+="$ch"; [[ "$ch" == "'" ]] && q=""; j=$((j+1)); continue
            fi
            if [[ "$q" == '"' ]]; then
                # command substitution ($(…) and backticks) still expands inside a
                # double-quoted string, so descend into it; <(…), >(…) and ( … ) do
                # not, and stay literal text here.
                if [[ "$esc" == 1 ]]; then cur+="$ch"; esc=0; j=$((j+1)); continue; fi
                nx="${L:j+1:1}"
                case "$ch" in
                    "\\") cur+="$ch"; esc=1 ;;
                    '"')  cur+="$ch"; q="" ;;
                    '`')  cur+="$ch"; _push backtick ;;
                    '$')  if [[ "$nx" == '(' ]]; then cur+="\$("; j=$((j+1)); _push paren; else cur+="$ch"; fi ;;
                    *)    cur+="$ch" ;;
                esac
                j=$((j+1)); continue
            fi
            if [[ "$expect_delim" == 1 ]]; then   # capturing a heredoc delimiter word
                cur+="$ch"
                if [[ -n "$delim_q" ]]; then
                    [[ "$ch" == "$delim_q" ]] && delim_q="" || delim+="$ch"
                    j=$((j+1)); continue
                fi
                case "$ch" in
                    '-') [[ -z "$delim" ]] && hd_dash=1 || delim+="$ch" ;;
                    ' '|$'\t') [[ -n "$delim" ]] && { hd_ready="$delim"; expect_delim=0; } ;;
                    \'|\") delim_q="$ch" ;;
                    ';'|'|'|'&') hd_ready="$delim"; expect_delim=0 ;;
                    *) delim+="$ch" ;;
                esac
                j=$((j+1)); continue
            fi
            if [[ "$esc" == 1 ]]; then cur+="$ch"; esc=0; j=$((j+1)); continue; fi
            nx="${L:j+1:1}"
            case "$ch" in
                \\) cur+="$ch"; esc=1 ;;
                "'") cur+="$ch"; q="'" ;;
                '"') cur+="$ch"; q='"' ;;
                '`') cur+="$ch"
                     if [[ "${#kind[@]}" -gt 0 && "${kind[${#kind[@]}-1]}" == backtick ]]; then _pop; else _push backtick; fi ;;
                '$') if [[ "$nx" == '(' ]]; then cur+="\$("; j=$((j+1)); _push paren; else cur+="$ch"; fi ;;
                '<')
                    if [[ "$nx" == '(' ]]; then                      # process substitution <(…)
                        cur+='<('; j=$((j+1)); _push paren
                    elif [[ "$nx" == '<' && "${L:j+2:1}" == '<' ]]; then
                        cur+='<<<'; j=$((j+2))                       # here-string, not a heredoc
                    elif [[ "$nx" == '<' && "${#kind[@]}" -eq 0 ]]; then
                        # Heredocs are tracked only at the top level. KNOWN LIMITATION:
                        # a heredoc opened INSIDE a command substitution or subshell —
                        # `x=$(cat <<EOF ... EOF)` — is not registered, so its body is
                        # parsed as commands and a body line starting `ctp`/`make` is
                        # false-denied. This fails CLOSED (denies, never bypasses) and
                        # the shape is rare, so it is left as-is; a full fix would move
                        # the heredoc delimiter onto the kind/qsave stack so it pops with
                        # its context instead of leaking to the enclosing one.
                        cur+='<<'; j=$((j+1)); expect_delim=1; delim=""; delim_q=""; hd_dash=0
                    else cur+="$ch"; fi ;;
                '>') if [[ "$nx" == '(' ]]; then cur+='>('; j=$((j+1)); _push paren; else cur+="$ch"; fi ;;
                '(') _push paren ;;                                  # subshell / group
                ')') if [[ "${#kind[@]}" -gt 0 ]]; then _pop; else cur+="$ch"; fi ;;
                ';') _flush ;;
                '|') _flush; [[ "$nx" == '|' ]] && j=$((j+1)) ;;
                '&') if [[ "$nx" == '&' ]]; then _flush; j=$((j+1)); else cur+="$ch"; fi ;;
                *)   cur+="$ch" ;;
            esac
            j=$((j+1))
        done
        if [[ -n "$q" ]]; then
            cur+=$'\n'                       # newline lives inside an open quote: keep it, no split
        else
            # A delimiter word ended by the newline itself — `cat <<EOF` with
            # nothing after it, the common form — is still open at this point;
            # resolve it here so its body is registered as a heredoc and skipped.
            # (Ending it by a space or a redirect resolves it in the char loop.)
            [[ "$expect_delim" == 1 && -n "$delim" && "${#kind[@]}" -eq 0 ]] && { hd_ready="$delim"; expect_delim=0; delim=""; delim_q=""; }
            if [[ -n "$hd_ready" ]]; then
                hd="$hd_ready"; hd_ready=""; _flush   # heredoc body starts on the next line
            else
                esc=0; _flush                # a bare newline is a separator
            fi
        fi
    done
    _flush
}
