#!/usr/bin/env bash
# The ctp agent-path PreToolUse hook must FAIL CLOSED (issue #87).
#
# When the guard stack is missing, or a required layer cannot load, the hook
# cannot classify anything, so it must DENY (with a reason that says how to fix
# it) rather than exit 0 and let other permissions decide. An unexpected failure
# must exit 2 (Claude Code's blocking code), never a plain non-zero (non-blocking,
# i.e. fail open). With the stack present, normal behaviour is unchanged.
#
# Each case copies the hook into an isolated temp layout with an empty HOME so
# no installed copy of the stack can be found by accident. No network.
#
# Usage: bash scripts/tests/test-ctp-hook-fail-closed.sh
# Exit: 0 pass, non-zero = number of failures.
# shellcheck disable=SC2015  # `cond && ok || bad` is intentional: ok() never fails
set -uo pipefail
command -v jq >/dev/null 2>&1 || { echo "jq required; skipping"; exit 0; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$(dirname "$HERE")")"
HOOK_SRC="$ROOT/.claude/hooks/pretooluse-ctp.sh"
LIBDIR="$ROOT/scripts/lib"

fails=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fails=$((fails + 1)); }

BASH_CALL='{"tool_name":"Bash","tool_input":{"command":"ls -la"}}'
READ_CALL='{"tool_name":"Read","tool_input":{"file_path":"/tmp/x.txt"}}'

# run_hook <hook-path> <stdin>  -> sets OUT, RC (stderr discarded)
run_hook() {
    OUT="$(env -u GUARD_STACK_LIB -u CTP_GUARD_LIB -u CMD_SEGMENT_LIB HOME="$TMP/emptyhome" \
        bash "$1" <<<"$2" 2>/dev/null)"
    RC=$?
}
decision() {
    local d
    d="$(jq -r '.hookSpecificOutput.permissionDecision // empty' <<<"$1" 2>/dev/null)"
    echo "${d:-none}"   # no output from the hook = no opinion
}
reason()   { jq -r '.hookSpecificOutput.permissionDecisionReason // ""' <<<"$1" 2>/dev/null; }

mkdir -p "$TMP/emptyhome"

# --- 1. No guard stack anywhere ------------------------------------------------
mkdir -p "$TMP/nostack/.claude/hooks"
cp "$HOOK_SRC" "$TMP/nostack/.claude/hooks/"
H1="$TMP/nostack/.claude/hooks/pretooluse-ctp.sh"
run_hook "$H1" "$BASH_CALL"
[[ $RC -eq 0 && "$(decision "$OUT")" == deny ]] && ok "missing stack: Bash call denied" \
    || bad "missing stack: Bash call denied (rc=$RC, decision=$(decision "$OUT"))"
[[ "$(reason "$OUT")" == *"install-ctp-bridge.sh"* ]] && ok "missing stack: reason says how to fix" \
    || bad "missing stack: reason says how to fix"
run_hook "$H1" "$READ_CALL"
[[ "$(decision "$OUT")" == deny ]] && ok "missing stack: Read call denied" || bad "missing stack: Read call denied"

# --- 2. Stack present, required layer missing ------------------------------------
mkdir -p "$TMP/partial/.claude/hooks"
cp "$HOOK_SRC" "$LIBDIR/guard-stack.sh" "$TMP/partial/.claude/hooks/"
H2="$TMP/partial/.claude/hooks/pretooluse-ctp.sh"
run_hook "$H2" "$BASH_CALL"
[[ $RC -eq 0 && "$(decision "$OUT")" == deny ]] && ok "required layer missing: call denied" \
    || bad "required layer missing: call denied (rc=$RC, decision=$(decision "$OUT"))"
[[ "$(reason "$OUT")" == *"incomplete"* ]] && ok "required layer missing: reason names the cause" \
    || bad "required layer missing: reason names the cause"

# --- 3. Full stack: normal behaviour unchanged -----------------------------------
# (Config-dependent decisions are covered by test-ctp-bridge.sh; here only the
# config-free baseline: a benign call still draws no opinion.)
mkdir -p "$TMP/full/.claude/hooks" "$TMP/full/scripts"
cp "$HOOK_SRC" "$TMP/full/.claude/hooks/"
cp -r "$LIBDIR" "$TMP/full/scripts/lib"
H3="$TMP/full/.claude/hooks/pretooluse-ctp.sh"
run_hook "$H3" "$BASH_CALL"
[[ $RC -eq 0 && "$(decision "$OUT")" == none ]] && ok "full stack: benign Bash call -> no opinion" \
    || bad "full stack: benign Bash call -> no opinion (rc=$RC, decision=$(decision "$OUT"))"
run_hook "$H3" "$READ_CALL"
[[ $RC -eq 0 && "$(decision "$OUT")" == none ]] && ok "full stack: benign Read call -> no opinion" \
    || bad "full stack: benign Read call -> no opinion (rc=$RC, decision=$(decision "$OUT"))"

# --- 4. Unexpected failure is a blocking exit, not a silent pass ------------------
run_hook "$H3" 'this is not json'
[[ $RC -eq 2 ]] && ok "malformed input: blocking exit 2" || bad "malformed input: blocking exit 2 (rc=$RC)"

echo
if (( fails == 0 )); then echo "All ctp hook fail-closed tests passed."; else echo "$fails failure(s)."; fi
exit "$fails"
