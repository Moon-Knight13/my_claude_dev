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
# FAIL CLOSED (issue #87). This is the agent path: if the guard stack cannot be
# found or its required layers cannot load, nothing can be classified, so every
# call this hook sees is DENIED with a reason that says how to fix it. Any other
# unexpected failure exits 2, which Claude Code treats as blocking; a plain
# non-zero exit would be a non-blocking error, i.e. fail open. The operator path
# (running ctp-bridge by hand) does not go through this hook and is unaffected.
#
# The wrapper re-classifies from its own argv and is authoritative on the run;
# this hook is defense in depth plus the human prompt. Boundary values come from
# the config file, never from the caller's environment.
#
# The POLICY lives in scripts/lib/guard-stack.sh, shared with the local-model
# executor (enforcement point #2) so the two cannot drift. This file is enforcement
# point #1: it parses the tool call, asks the stack for a verdict, and renders that
# verdict in the hook's JSON protocol. It decides nothing on its own.
set -euo pipefail
# Any command failure under `set -e` would otherwise exit non-zero-but-not-2,
# which Claude Code does not treat as a block. Turn it into a blocking exit.
trap 'echo "pretooluse-ctp: guard hook failed unexpectedly; denying this call (fail closed)" >&2; exit 2' ERR

# Deny without the stack (emit() below needs nothing from it either, but is
# defined after the stack loads; keep this self-contained).
_deny_unavailable() {
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$1"
    exit 0
}

_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Installed at user scope (~/.claude/hooks) on the box, but also runs from the
# repo in dev/tests. Resolve the guard stack across both layouts; first hit wins.
_find_stack() {
    local c
    for c in "${GUARD_STACK_LIB:-}" \
             "$HOME/.local/lib/ctp-bridge/guard-stack.sh" \
             "$_HERE/guard-stack.sh" \
             "$_HERE/../../scripts/lib/guard-stack.sh"; do
        [[ -n "$c" && -f "$c" ]] && { printf '%s' "$c"; return 0; }
    done
    return 1
}
_STACK="$(_find_stack)" \
    || _deny_unavailable "ctp guard stack not found, so this call cannot be checked and is denied (fail closed). Install it with: bash scripts/install-ctp-bridge.sh"
# shellcheck source=scripts/lib/guard-stack.sh disable=SC1091
source "$_STACK"
# Required layers missing ⇒ we cannot classify anything, so deny rather than let
# the call through unchecked.
guard_stack_load hook \
    || _deny_unavailable "ctp guard stack is incomplete (a required layer failed to load), so this call is denied (fail closed). Reinstall with: bash scripts/install-ctp-bridge.sh"

emit() { # emit <allow|deny|ask> <reason>
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":"%s"}}\n' \
        "$1" "$2"
    exit 0
}
pass() { exit 0; }  # no opinion

# _write_approval <argv-string> — record a single-use, argv-bound, short-TTL token
# so the wrapper knows the human approved THIS invocation at the prompt below.
_write_approval() {
    local dir; dir="$(ctp_state_dir)"
    mkdir -p "$dir" 2>/dev/null || return 0
    ( umask 077; printf '%s\t%s\n' "$(( $(date +%s) + 180 ))" "$1" > "$dir/approval" 2>/dev/null )
}

# _render — turn the stack's GUARD_STACK_VERDICT ("ask:<reason>" / "deny:<reason>"
# / "") into the hook protocol. Empty means no opinion.
#
# The stack sets a global instead of printing, so it must NOT be called inside
# $(...) — a subshell would discard GUARD_STACK_APPROVAL_ARGV and silently stop the
# approval token being written.
_render() {
    case "$GUARD_STACK_VERDICT" in
        ask:*)  emit ask  "${GUARD_STACK_VERDICT#ask:}" ;;
        deny:*) emit deny "${GUARD_STACK_VERDICT#deny:}" ;;
    esac
}

INPUT="$(cat)"
_json() { printf '%s' "$INPUT" | jq -r "$1" 2>/dev/null; }

TOOL="$(_json '.tool_name')"

# --- Read/Write/Edit: block touching a guarded path --------------------------
if [[ "$TOOL" == "Read" || "$TOOL" == "Write" || "$TOOL" == "Edit" ]]; then
    fp="$(_json '.tool_input.file_path')"
    if [[ -n "$fp" ]]; then
        guard_stack_classify_path "$fp"
        _render
    fi
    pass
fi

[[ "$TOOL" == "Bash" ]] || pass
CMD="$(_json '.tool_input.command')"
[[ -n "$CMD" ]] || pass

guard_stack_classify_command "$CMD"
# A permitted wrapper call: bind the approval to the exact argv the wrapper will
# receive, so it runs without a second (impossible, no-TTY) prompt.
if [[ ${#GUARD_STACK_APPROVAL_ARGV[@]} -gt 0 ]]; then
    _write_approval "${GUARD_STACK_APPROVAL_ARGV[*]:-}"
fi
_render

pass
