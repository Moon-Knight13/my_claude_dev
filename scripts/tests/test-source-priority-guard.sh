#!/usr/bin/env bash
# test-source-priority-guard.sh -- unit tests for the source-priority advisory hook.
set -euo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/.claude/hooks/source-priority-guard.sh"
SETTINGS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/.claude/settings.json"
pass=0 fail=0

_result() {
    if [[ $1 -eq 0 ]]; then
        printf '  PASS: %s\n' "$2"; pass=$(( pass + 1 ))
    else
        printf '  FAIL: %s\n' "$2"; fail=$(( fail + 1 ))
    fi
}

_tmp_dir="$(mktemp -d)"
mkdir -p "$_tmp_dir/.claude"
trap 'rm -rf "$_tmp_dir"' EXIT

_set_mode() {
    local mode="$1"
    python3 -I -c '
import json, sys
mode, path = sys.argv[1], sys.argv[2]
with open(path, "r") as f:
    s = json.load(f)
if mode:
    s["_mode"] = mode
else:
    s.pop("_mode", None)
with open(path, "w") as f:
    json.dump(s, f)
' "$mode" "$_tmp_dir/.claude/settings.json"
}

_run_hook() {
    local tool_json="$1"
    { echo "$tool_json" | CLAUDE_PROJECT_DIR="$_tmp_dir" bash "$HOOK" >/dev/null; } 2>&1 || true
}

echo "=== source-priority-guard tests ==="

# --- T1: hook file exists and is executable ---
rc=0; [[ -x "$HOOK" ]] || rc=1
_result $rc "hook file exists and is executable"

# --- T2: hook is registered in settings.json ---
rc=0
python3 -I -c '
import json, sys
with open(sys.argv[1]) as f:
    s = json.load(f)
hooks = s.get("hooks",{}).get("PreToolUse",[])
found = any(
    "source-priority-guard" in h.get("command","")
    for entry in hooks
    for h in entry.get("hooks",[])
)
sys.exit(0 if found else 1)
' "$SETTINGS" || rc=1
_result $rc "hook registered in settings.json PreToolUse"

# --- Prepare a red-team mode settings copy ---
cp "$SETTINGS" "$_tmp_dir/.claude/settings.json"
_set_mode "red-team"

# --- T3: WebSearch triggers warning in red-team mode ---
stderr_out="$(_run_hook '{"tool_name":"WebSearch","tool_input":{"query":"test"}}')"
rc=0; echo "$stderr_out" | grep -qi "source priority" 2>/dev/null || rc=1
_result $rc "WebSearch triggers advisory warning with source priority message"

# --- T4: WebFetch triggers warning in red-team mode ---
stderr_out="$(_run_hook '{"tool_name":"WebFetch","tool_input":{"url":"https://example.com"}}')"
rc=0; echo "$stderr_out" | grep -qi "source priority" 2>/dev/null || rc=1
_result $rc "WebFetch triggers advisory warning"

# --- T5: non-web tool passes silently ---
stderr_out="$(_run_hook '{"tool_name":"Bash","tool_input":{"command":"ls"}}')"
rc=0; [[ -z "$stderr_out" ]] || rc=1
_result $rc "non-web tool (Bash) passes silently"

# --- T6: hook exits 0 (never blocks) on WebSearch ---
rc=0
echo '{"tool_name":"WebSearch","tool_input":{"query":"test"}}' \
    | CLAUDE_PROJECT_DIR="$_tmp_dir" bash "$HOOK" >/dev/null 2>&1 || rc=$?
_result $rc "WebSearch exits 0 (advisory only)"

# --- T7: hook exits 0 on WebFetch ---
rc=0
echo '{"tool_name":"WebFetch","tool_input":{"url":"https://example.com"}}' \
    | CLAUDE_PROJECT_DIR="$_tmp_dir" bash "$HOOK" >/dev/null 2>&1 || rc=$?
_result $rc "WebFetch exits 0 (advisory only)"

# --- T8: hook is silent in platform-ops mode ---
_set_mode "platform-ops"
stderr_out="$(_run_hook '{"tool_name":"WebSearch","tool_input":{"query":"test"}}')"
rc=0; [[ -z "$stderr_out" ]] || rc=1
_result $rc "WebSearch silent in platform-ops mode"

# --- T9: hook is silent when no mode set ---
_set_mode ""
stderr_out="$(_run_hook '{"tool_name":"WebSearch","tool_input":{"query":"test"}}')"
rc=0; [[ -z "$stderr_out" ]] || rc=1
_result $rc "WebSearch silent when no mode set"

# --- T10: warning mentions all priority sources ---
_set_mode "red-team"
stderr_out="$(_run_hook '{"tool_name":"WebSearch","tool_input":{"query":"test"}}')"
rc=0
for keyword in Providentia GitLab Wiki Tuoni Obsidian hacktricks; do
    echo "$stderr_out" | grep -qi "$keyword" 2>/dev/null || { rc=1; break; }
done
_result $rc "warning mentions all higher-priority sources"

echo ""
echo "Results: $pass passed, $fail failed out of $(( pass + fail )) tests"
[[ $fail -eq 0 ]]
