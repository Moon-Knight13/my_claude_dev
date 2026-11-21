#!/usr/bin/env bash
# pretooluse-ctp.sh — user-level PreToolUse hook: ctp-bridge safety gate.
# Deployed to ~/.claude/hooks/ by deploy-hq.sh.
# Fail-closed: if guard stack not found, denies all gated calls.
set -euo pipefail
trap 'echo "pretooluse-ctp: guard hook failed unexpectedly; denying this call (fail closed)" >&2; exit 2' ERR

# Double-fire prevention: if project-level hook exists, let it handle this.
HOOK_NAME="$(basename "${BASH_SOURCE[0]}")"
if [[ -n "${CLAUDE_PROJECT_DIR:-}" && \
      -x "$CLAUDE_PROJECT_DIR/.claude/hooks/$HOOK_NAME" ]]; then
    exit 0
fi

_deny_unavailable() {
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$1"
    exit 0
}

# Guard-stack resolution chain (user-level paths first):
_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_find_stack() {
    local c
    for c in "${GUARD_STACK_LIB:-}" \
             "$HOME/.local/lib/ctp-bridge/guard-stack.sh" \
             "$_HERE/guard-stack.sh" \
             "$_HERE/../../scripts/lib/guard-stack.sh" \
             "${CLAUDE_PROJECT_DIR:-__none__}/scripts/lib/guard-stack.sh"; do
        [[ -n "$c" && "$c" != "__none__/scripts/lib/guard-stack.sh" && -f "$c" ]] && { printf '%s' "$c"; return 0; }
    done
    return 1
}
_STACK="$(_find_stack)" \
    || _deny_unavailable "ctp guard stack not found, so this call cannot be checked and is denied (fail closed). Install it with: bash scripts/install-ctp-bridge.sh"

# Load .env before the guard stack so GUARD_* vars are available.
_STACK_DIR="$(dirname "$_STACK")"
# shellcheck disable=SC1091
source "$_STACK_DIR/load-env.sh" 2>/dev/null || true

_HOOK_AUTO_APPROVE_READONLY="${CTP_AUTO_APPROVE_READONLY:-}"

# shellcheck disable=SC1090
source "$_STACK"
guard_stack_load hook \
    || _deny_unavailable "ctp guard stack is incomplete (a required layer failed to load), so this call is denied (fail closed). Reinstall with: bash scripts/install-ctp-bridge.sh"

emit() {
    python3 -I -c '
import json, sys
decision, reason = sys.argv[1], sys.argv[2]
out = {"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": decision, "permissionDecisionReason": reason}}
print(json.dumps(out))
' "$1" "$2"
    exit 0
}
pass() { exit 0; }

_write_approval() {
    local dir; dir="$(ctp_state_dir)"
    mkdir -p "$dir" 2>/dev/null || return 0
    ( umask 077; printf '%s\t%s\n' "$(( $(date +%s) + 180 ))" "$1" > "$dir/approval" 2>/dev/null )
}

_render() {
    case "$GUARD_STACK_VERDICT" in
        ask:*)  emit ask  "${GUARD_STACK_VERDICT#ask:}" ;;
        deny:*) emit deny "${GUARD_STACK_VERDICT#deny:}" ;;
    esac
}

INPUT="$(cat)"
_json() { printf '%s' "$INPUT" | jq -r "$1" 2>/dev/null; }

TOOL="$(_json '.tool_name')"

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
if [[ ${#GUARD_STACK_APPROVAL_ARGV[@]} -gt 0 ]]; then
    _write_approval "${GUARD_STACK_APPROVAL_ARGV[*]:-}"
fi

_is_readonly_ctp() {
    [[ ${#GUARD_STACK_APPROVAL_ARGV[@]} -gt 0 ]] || return 1
    local a0="${GUARD_STACK_APPROVAL_ARGV[0]:-}" a1="${GUARD_STACK_APPROVAL_ARGV[1]:-}"
    case "$a0" in
        host)
            case "$a1" in
                list|vars|connect) return 0 ;;
            esac ;;
        project)
            case "$a1" in
                update-inventory) return 0 ;;
            esac ;;
    esac
    return 1
}

if [[ "$GUARD_STACK_VERDICT" == ask:* && ( "$_HOOK_AUTO_APPROVE_READONLY" == "1" || "$_HOOK_AUTO_APPROVE_READONLY" == "true" ) ]]; then
    if _is_readonly_ctp; then
        emit allow "auto-approved read-only ctp command (CTP_AUTO_APPROVE_READONLY=1)"
    fi
fi

_render

pass
