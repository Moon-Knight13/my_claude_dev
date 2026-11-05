#!/usr/bin/env bash
# audit-trail.sh — PreToolUse hook: structured logging of all tool calls.
#
# Appends one JSON line per tool invocation to .claude/audit/tool-calls.jsonl.
# Records: timestamp, mode, tool name, MCP server (if applicable), and
# whether the call was allowed or denied by other hooks (inferred from
# exit at log time — this hook always exits 0, so it never blocks).
#
# Runs as first PreToolUse hook (registered with empty matcher = all tools).
# Lightweight: no python for the fast path, only for JSON-safe escaping.
#
# Exit: always 0 (no opinion — logging only, never blocks).
set -uo pipefail

AUDIT_DIR="${CLAUDE_PROJECT_DIR:-.}/.claude/audit"
mkdir -p "$AUDIT_DIR" 2>/dev/null || true
AUDIT_FILE="$AUDIT_DIR/tool-calls.jsonl"

# Read tool call from stdin
input="$(cat)"

# Extract fields with python (fast, handles escaping)
python3 -I -c '
import sys, json, datetime

try:
    data = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)

tool_name = data.get("tool_name", "unknown")
tool_input = data.get("tool_input", {})

# For MCP tools, extract server name
mcp_server = ""
if tool_name.startswith("mcp__"):
    parts = tool_name.split("__", 2)
    if len(parts) >= 2:
        mcp_server = parts[1]

# Read active mode
mode = "unknown"
try:
    project_dir = data.get("project_dir", ".")
    with open(f"{project_dir}/.claude/.active-mode") as f:
        mode = f.read().strip()
except Exception:
    import os
    pd = os.environ.get("CLAUDE_PROJECT_DIR", ".")
    try:
        with open(f"{pd}/.claude/.active-mode") as f:
            mode = f.read().strip()
    except Exception:
        pass

# Build log entry — never log full tool_input for security
# Log tool name and param keys only (not values, which may contain secrets)
param_keys = sorted(tool_input.keys()) if isinstance(tool_input, dict) else []

entry = {
    "t": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
    "mode": mode,
    "tool": tool_name,
    "params": param_keys,
}
if mcp_server:
    entry["mcp"] = mcp_server

# Append to audit log
audit_file = sys.argv[2]
try:
    with open(audit_file, "a") as f:
        f.write(json.dumps(entry, separators=(",", ":")) + "\n")
except Exception:
    pass
' "$input" "$AUDIT_FILE" 2>/dev/null || true

exit 0
