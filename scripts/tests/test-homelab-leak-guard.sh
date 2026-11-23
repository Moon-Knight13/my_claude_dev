#!/usr/bin/env bash
# test-homelab-leak-guard.sh — tests for AD-13 homelab leak guard hook.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$ROOT/scripts/hooks/homelab-leak-guard.sh"
PASS=0; FAIL=0

ok()  { echo "  OK  $1"; ((PASS++)) || true; }
bad() { echo " FAIL $1"; ((FAIL++)) || true; }

[[ -x "$HOOK" ]] || chmod +x "$HOOK"

# Setup: create temp project dir with mode file
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT
mkdir -p "$TMPDIR/.claude"
export CLAUDE_PROJECT_DIR="$TMPDIR"

# Helper: run hook with given mode and JSON input
run_hook() {
    local mode="$1" input="$2"
    printf '%s' "$mode" > "$TMPDIR/.claude/.active-mode"
    printf '%s' "$input" | bash "$HOOK" 2>/dev/null
}

has_warning() { printf '%s' "$1" | grep -q "AD-13 LEAK GUARD"; }
is_silent()   { [[ -z "$1" ]]; }

# ══════════════════════════════════════════════════════════════════════════════
echo "== Irrelevant tools skipped =="
# ══════════════════════════════════════════════════════════════════════════════

OUT="$(run_hook "homelab" '{"tool_name":"Read","tool_input":{"file_path":"/tmp/10.10.1.1"}}')"
is_silent "$OUT" && ok "Read tool: ignored" || bad "Read tool triggered guard: $OUT"

OUT="$(run_hook "homelab" '{"tool_name":"Agent","tool_input":{"prompt":"check 10.10.1.1"}}')"
is_silent "$OUT" && ok "Agent tool: ignored" || bad "Agent tool triggered guard: $OUT"

# ══════════════════════════════════════════════════════════════════════════════
echo "== No mode set =="
# ══════════════════════════════════════════════════════════════════════════════

rm -f "$TMPDIR/.claude/.active-mode"
OUT="$(printf '{"tool_name":"Bash","tool_input":{"command":"ping 10.10.1.1"}}' | CLAUDE_PROJECT_DIR="$TMPDIR" bash "$HOOK" 2>/dev/null)"
is_silent "$OUT" && ok "no active mode: silent" || bad "no mode produced output: $OUT"

# ══════════════════════════════════════════════════════════════════════════════
echo "== Direction 1: range data in homelab mode =="
# ══════════════════════════════════════════════════════════════════════════════

OUT="$(run_hook "homelab" '{"tool_name":"Bash","tool_input":{"command":"ping 10.10.5.42"}}')"
has_warning "$OUT" && ok "10.10.x.x in Bash: warned" || bad "10.10.x.x in Bash: no warning"

OUT="$(run_hook "homelab" '{"tool_name":"Bash","tool_input":{"command":"ssh user@172.21.3.10"}}')"
has_warning "$OUT" && ok "172.21.x.x in Bash: warned" || bad "172.21.x.x in Bash: no warning"

OUT="$(run_hook "homelab" '{"tool_name":"Bash","tool_input":{"command":"curl dcm27-rt.crp.cr14.net"}}')"
has_warning "$OUT" && ok "dcm/cr14 in Bash: warned" || bad "dcm/cr14 in Bash: no warning"

OUT="$(run_hook "homelab" '{"tool_name":"Write","tool_input":{"file_path":"/tmp/test.yml","content":"target: 10.10.100.5\nhost: dcm15-ws"}}')"
has_warning "$OUT" && ok "range IP in Write: warned" || bad "range IP in Write: no warning"

OUT="$(run_hook "homelab" '{"tool_name":"Edit","tool_input":{"file_path":"/tmp/test.sh","new_string":"connect to tuoni agent","old_string":"placeholder"}}')"
has_warning "$OUT" && ok "tuoni ref in Edit: warned" || bad "tuoni ref in Edit: no warning"

OUT="$(run_hook "homelab" '{"tool_name":"Bash","tool_input":{"command":"echo RT-DEP-001 deploy order"}}')"
has_warning "$OUT" && ok "RT-DEP in Bash: warned" || bad "RT-DEP in Bash: no warning"

OUT="$(run_hook "homelab" '{"tool_name":"Bash","tool_input":{"command":"check engagement_state.yaml"}}')"
has_warning "$OUT" && ok "engagement ref: warned" || bad "engagement ref: no warning"

# ── Clean homelab commands should pass silently ──────────────────────────────

OUT="$(run_hook "homelab" '{"tool_name":"Bash","tool_input":{"command":"docker compose up -d jellyfin"}}')"
is_silent "$OUT" && ok "clean docker cmd: silent" || bad "clean docker cmd triggered: $OUT"

OUT="$(run_hook "homelab" '{"tool_name":"Bash","tool_input":{"command":"ping 10.5.1.1"}}')"
is_silent "$OUT" && ok "homelab IP in homelab mode: silent" || bad "homelab IP triggered in homelab mode: $OUT"

OUT="$(run_hook "homelab" '{"tool_name":"Write","tool_input":{"file_path":"/tmp/docker-compose.yml","content":"image: jellyfin/jellyfin:latest"}}')"
is_silent "$OUT" && ok "clean Write: silent" || bad "clean Write triggered: $OUT"

# ══════════════════════════════════════════════════════════════════════════════
echo "== Direction 2: homelab data in non-homelab modes =="
# ══════════════════════════════════════════════════════════════════════════════

OUT="$(run_hook "red-team" '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"fix\" -- notes-with-10.5.1.1.md"}}')"
has_warning "$OUT" && ok "homelab IP in red-team commit: warned" || bad "homelab IP in red-team commit: no warning"

OUT="$(run_hook "platform-ops" '{"tool_name":"Bash","tool_input":{"command":"git add . && git commit -m \"update UDR7 config\""}}')"
has_warning "$OUT" && ok "UDR7 in platform-ops commit: warned" || bad "UDR7 in platform-ops commit: no warning"

OUT="$(run_hook "green-dev" '{"tool_name":"Write","tool_input":{"file_path":"/tmp/my_claude_dev/test.yml","content":"router: 10.5.1.1\ngateway: UDR7"}}')"
has_warning "$OUT" && ok "homelab data in Write to non-homelab: warned" || bad "homelab Write: no warning"

# ── Homelab data in homelab repos is expected ────────────────────────────────

OUT="$(run_hook "platform-ops" '{"tool_name":"Write","tool_input":{"file_path":"/home/chris/homelab_infra/ansible/host_vars.yml","content":"ip: 10.5.1.1\nrouter: UDR7"}}')"
is_silent "$OUT" && ok "homelab data in homelab_infra: silent" || bad "homelab_infra write triggered: $OUT"

OUT="$(run_hook "red-team" '{"tool_name":"Write","tool_input":{"file_path":"/tmp/homelab_planning/inventory.yml","content":"10.5.1.100"}}')"
is_silent "$OUT" && ok "homelab data in homelab_planning: silent" || bad "homelab_planning write triggered: $OUT"

# ── Range data in non-homelab modes should NOT trigger ───────────────────────

OUT="$(run_hook "red-team" '{"tool_name":"Bash","tool_input":{"command":"ping 10.10.5.42"}}')"
is_silent "$OUT" && ok "range IP in red-team: silent (expected context)" || bad "range IP in red-team triggered: $OUT"

OUT="$(run_hook "green-dev" '{"tool_name":"Bash","tool_input":{"command":"ssh dcm15-ws.crp.cr14.net"}}')"
is_silent "$OUT" && ok "dcm ref in green-dev: silent (expected)" || bad "dcm ref in green-dev triggered: $OUT"

# ── Non-git Bash in non-homelab mode: homelab IP no warning ──────────────────

OUT="$(run_hook "red-team" '{"tool_name":"Bash","tool_input":{"command":"echo 10.5.1.1 in a note"}}')"
is_silent "$OUT" && ok "homelab IP in non-git Bash: silent" || bad "non-git Bash triggered: $OUT"

# ══════════════════════════════════════════════════════════════════════════════
echo "== Heredoc false-positive prevention =="
# ══════════════════════════════════════════════════════════════════════════════

OUT="$(run_hook "homelab" "$(printf '{"tool_name":"Bash","tool_input":{"command":"gh pr create --body \"$(cat <<'"'"'EOF'"'"'\\n10.10.1.1 is an example range IP\\nEOF\\n)\""}}')")"
is_silent "$OUT" && ok "heredoc with range IP: silent" || bad "heredoc triggered: $OUT"

# ══════════════════════════════════════════════════════════════════════════════
echo "== Audit logging =="
# ══════════════════════════════════════════════════════════════════════════════

rm -f "$TMPDIR/.claude/audit/leak-guard.jsonl"
run_hook "homelab" '{"tool_name":"Bash","tool_input":{"command":"ping 10.10.1.1"}}' >/dev/null
[[ -f "$TMPDIR/.claude/audit/leak-guard.jsonl" ]] && ok "audit file created" || bad "no audit file"
if [[ -f "$TMPDIR/.claude/audit/leak-guard.jsonl" ]]; then
    grep -q "leak_guard_warning" "$TMPDIR/.claude/audit/leak-guard.jsonl" && ok "audit entry logged" || bad "audit entry missing"
fi

# ══════════════════════════════════════════════════════════════════════════════
echo "== Per-session mode override =="
# ══════════════════════════════════════════════════════════════════════════════

export CLAUDE_CODE_SESSION_ID="test-session-$$"
mkdir -p "$TMPDIR/.claude/.mode-overrides"
printf 'homelab' > "$TMPDIR/.claude/.mode-overrides/$CLAUDE_CODE_SESSION_ID"
printf 'red-team' > "$TMPDIR/.claude/.active-mode"

OUT="$(printf '{"tool_name":"Bash","tool_input":{"command":"ping 10.10.5.42"}}' | CLAUDE_PROJECT_DIR="$TMPDIR" bash "$HOOK" 2>/dev/null)"
has_warning "$OUT" && ok "session override to homelab: range IP warned" || bad "session override not respected: $OUT"

rm -f "$TMPDIR/.claude/.mode-overrides/$CLAUDE_CODE_SESSION_ID"
unset CLAUDE_CODE_SESSION_ID

echo ""
echo "homelab-leak-guard: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
