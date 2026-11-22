#!/usr/bin/env bash
# test-commit-scope-guard.sh — verify commit-scope soft guard behavior.
# shellcheck disable=SC2015,SC2155
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$ROOT/scripts/hooks/commit-scope-guard.sh"
PASS=0; FAIL=0
ok()  { echo "  OK  $1"; ((PASS++)) || true; }
bad() { echo " FAIL $1"; ((FAIL++)) || true; }

[[ -x "$HOOK" ]] || chmod +x "$HOOK"

# Use isolated tracking dir so we don't pollute real state
export CLAUDE_SESSION_ID="test-$$-$(date +%s)"
TRACK_DIR="/tmp/cc-commit-count"

cleanup() { rm -f "$TRACK_DIR/$CLAUDE_SESSION_ID" 2>/dev/null || true; }
trap cleanup EXIT

# Helper: feed JSON stdin to the hook and capture output
run_hook() {
    printf '%s' "$1" | bash "$HOOK" 2>&1
}

# ── 1. Non-commit Bash command produces no tracking ─────────────────────────
INPUT='{"tool_name":"Bash","tool_input":{"command":"ls -la"}}'
OUT="$(run_hook "$INPUT")"
[[ -z "$OUT" ]]                               && ok "non-commit: silent"            || bad "non-commit produced output: $OUT"
[[ ! -f "$TRACK_DIR/$CLAUDE_SESSION_ID" ]]    && ok "non-commit: no tracking file"  || bad "non-commit created tracking file"

# ── 2. Non-Bash tool is ignored ─────────────────────────────────────────────
INPUT='{"tool_name":"Read","tool_input":{"file_path":"/tmp/x"}}'
OUT="$(run_hook "$INPUT")"
[[ -z "$OUT" ]]                               && ok "non-Bash tool: silent"         || bad "non-Bash tool produced output: $OUT"

# ── 3. First git commit passes silently ─────────────────────────────────────
INPUT='{"tool_name":"Bash","tool_input":{"command":"git commit -m \"first\""}}'
OUT="$(run_hook "$INPUT")"
[[ -z "$OUT" ]]                               && ok "first commit: silent"          || bad "first commit produced output: $OUT"
[[ -f "$TRACK_DIR/$CLAUDE_SESSION_ID" ]]      && ok "first commit: tracking file created" || bad "first commit: no tracking file"
COUNT="$(cat "$TRACK_DIR/$CLAUDE_SESSION_ID")"
[[ "$COUNT" == "1" ]]                         && ok "first commit: count=1"         || bad "first commit: count=$COUNT"

# ── 4. Second git commit warns on stderr ────────────────────────────────────
INPUT='{"tool_name":"Bash","tool_input":{"command":"git commit -m \"second\""}}'
OUT="$(run_hook "$INPUT")"
[[ "$OUT" == *"Multiple commits detected"* ]] && ok "second commit: warning shown"  || bad "second commit: no warning ($OUT)"
[[ "$OUT" == *"hookSpecificOutput"* ]]        && ok "second commit: valid JSON"     || bad "second commit: not JSON hook output"
COUNT="$(cat "$TRACK_DIR/$CLAUDE_SESSION_ID")"
[[ "$COUNT" == "2" ]]                         && ok "second commit: count=2"        || bad "second commit: count=$COUNT"

# ── 5. Third commit also warns ──────────────────────────────────────────────
INPUT='{"tool_name":"Bash","tool_input":{"command":"git commit --amend --no-edit"}}'
OUT="$(run_hook "$INPUT")"
[[ "$OUT" == *"Multiple commits detected"* ]] && ok "third commit: warning shown"   || bad "third commit: no warning"
COUNT="$(cat "$TRACK_DIR/$CLAUDE_SESSION_ID")"
[[ "$COUNT" == "3" ]]                         && ok "third commit: count=3"         || bad "third commit: count=$COUNT"

# ── 6. git log (not a commit) does not increment ───────────────────────────
INPUT='{"tool_name":"Bash","tool_input":{"command":"git log --oneline -5"}}'
OUT="$(run_hook "$INPUT")"
[[ -z "$OUT" ]]                               && ok "git log: silent"              || bad "git log produced output"
COUNT="$(cat "$TRACK_DIR/$CLAUDE_SESSION_ID")"
[[ "$COUNT" == "3" ]]                         && ok "git log: count unchanged"     || bad "git log changed count to $COUNT"

echo ""
echo "commit-scope-guard: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
