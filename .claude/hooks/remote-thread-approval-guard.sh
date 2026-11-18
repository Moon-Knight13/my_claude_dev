#!/usr/bin/env bash
# remote-thread-approval-guard.sh — PreToolUse hook: enforce approval-required
# runtime mode for threads created from remote sources.
#
# When a remote-origin signal is detected, any t3_thread_launch, create_threads,
# or delegate_task call that does NOT set runtimeMode to "approval-required" is
# denied. The denial message tells the caller what to set.
#
# Remote-origin signals (any one triggers enforcement):
#   1. environmentId in tool input (cross-environment thread creation)
#   2. .claude/.remote-approval-required flag file (operator always-on gate)
#   3. T3 Connect active + unattended session (automated remote access)
#
# Bypass:
#   - Delete .claude/.remote-approval-required to disable the flag gate
#   - Set runtimeMode: "approval-required" in the tool call to pass
#   - Local attended sessions are not gated (unless flag file exists)
#
# Exit protocol (PreToolUse):
#   0 + deny JSON  = blocked
#   0 + no output  = no opinion (allow)
#   2              = block (error / fail-closed)
set -euo pipefail
trap 'exit 2' ERR

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
FLAG_FILE="$PROJECT_DIR/.claude/.remote-approval-required"

input="$(cat)"

# Parse tool input with Python — output JSON, no eval
parsed="$(printf '%s' "$input" | python3 -I -c '
import sys, json

try:
    data = json.load(sys.stdin)
except Exception:
    json.dump({"gated": False}, sys.stdout)
    sys.exit(0)

tool_name = data.get("tool_name", "")
tool_input = data.get("tool_input", {})
if isinstance(tool_input, str):
    try:
        tool_input = json.loads(tool_input)
    except Exception:
        tool_input = {}

GATED_TOOLS = {
    "mcp__t3-code__t3_thread_launch",
    "mcp__t3-code__create_threads",
    "mcp__t3-code__delegate_task",
}
if tool_name not in GATED_TOOLS:
    json.dump({"gated": False}, sys.stdout)
    sys.exit(0)

has_env_id = bool(tool_input.get("environmentId"))
target = tool_input.get("target", {})
if isinstance(target, dict) and target.get("environmentId"):
    has_env_id = True

runtime_mode = tool_input.get("runtimeMode", "")

if tool_name == "mcp__t3-code__create_threads":
    threads = tool_input.get("threads", [])
    if isinstance(threads, list):
        modes = set()
        for t in threads:
            if isinstance(t, dict):
                m = t.get("runtimeMode", "")
                modes.add(m if m else "")
        if modes and all(m == "approval-required" for m in modes if m):
            if all(m for m in modes):
                runtime_mode = "approval-required"
            else:
                runtime_mode = ""
        else:
            non_approved = [m for m in modes if m and m != "approval-required"]
            runtime_mode = non_approved[0] if non_approved else ""

json.dump({
    "gated": True,
    "tool_name": tool_name,
    "has_env_id": has_env_id,
    "runtime_mode": runtime_mode,
}, sys.stdout)
' 2>/dev/null || echo '{"gated":false}')"

# Extract fields from JSON — no eval, no shell metacharacter risk
GATED="$(printf '%s' "$parsed" | python3 -I -c 'import sys,json; print(json.load(sys.stdin).get("gated",False))' 2>/dev/null || echo "False")"
[[ "$GATED" == "True" ]] || exit 0

TOOL_NAME="$(printf '%s' "$parsed" | python3 -I -c 'import sys,json; print(json.load(sys.stdin).get("tool_name",""))' 2>/dev/null || true)"
HAS_ENV_ID="$(printf '%s' "$parsed" | python3 -I -c 'import sys,json; d=json.load(sys.stdin); print("1" if d.get("has_env_id") else "0")' 2>/dev/null || echo "0")"
RUNTIME_MODE="$(printf '%s' "$parsed" | python3 -I -c 'import sys,json; print(json.load(sys.stdin).get("runtime_mode",""))' 2>/dev/null || true)"

# --- Detect remote origin ---
is_remote=0

# Signal 1: flag file (operator-configured always-on gate)
if [[ -f "$FLAG_FILE" ]]; then
    is_remote=1
fi

# Signal 2: environmentId in tool input (cross-environment creation)
if [[ "${HAS_ENV_ID:-0}" == "1" ]]; then
    is_remote=1
fi

# Signal 3: T3 Connect active + unattended session
# CLAUDE_CODE_SESSION_ATTENDED=0 means no human watching this session.
# Combined with T3 Connect being enabled, this indicates remote automation.
if [[ "${CLAUDE_CODE_SESSION_ATTENDED:-1}" == "0" ]]; then
    # Check if T3 Connect is active (server accepts non-local connections)
    T3_RUNTIME="${HOME}/.t3/userdata/server-runtime.json"
    if [[ -f "$T3_RUNTIME" ]]; then
        connect_active="$(python3 -I -c '
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    # privateNetworkOnly=false means T3 Connect tunnel is active
    # Even privateNetworkOnly=true with LAN access means remote is possible
    pno = data.get("privateNetworkOnly", True)
    host = data.get("host", "127.0.0.1")
    # If listening on 0.0.0.0 or T3 Connect relay, remote access possible
    if host == "0.0.0.0" or not pno:
        print("1")
    else:
        print("0")
except Exception:
    print("0")
' "$T3_RUNTIME" 2>/dev/null || echo "0")"
        if [[ "$connect_active" == "1" ]]; then
            is_remote=1
        fi
    fi
fi

# Not remote — no opinion, allow normal thread creation
[[ "$is_remote" == "1" ]] || exit 0

# --- Enforce approval-required ---
if [[ "$RUNTIME_MODE" == "approval-required" ]]; then
    # Correct mode set — allow
    exit 0
fi

# Determine which signal triggered
reason=""
if [[ -f "$FLAG_FILE" ]]; then
    reason="remote-approval gate active (.claude/.remote-approval-required)"
elif [[ "${HAS_ENV_ID:-0}" == "1" ]]; then
    reason="cross-environment thread creation (environmentId present)"
else
    reason="unattended session with remote access enabled"
fi

if [[ -n "$RUNTIME_MODE" ]]; then
    mode_msg="runtimeMode \"$RUNTIME_MODE\" is too permissive"
else
    mode_msg="no runtimeMode specified (would inherit parent mode)"
fi

python3 -I -c '
import json, sys
reason_text = "Remote thread guard: %s — %s. Set runtimeMode: \"approval-required\" for remote-originated threads. Override: delete .claude/.remote-approval-required or set the mode explicitly." % (sys.argv[1], sys.argv[2])
out = {"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": reason_text}}
print(json.dumps(out, separators=(",", ":"), ensure_ascii=False))
' "$reason" "$mode_msg"
exit 0
