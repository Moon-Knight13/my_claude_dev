#!/usr/bin/env bash
# mode-tool-gate.sh — PreToolUse hook: deterministic mode-based tool deny.
#
# Reads the active mode from .claude/.active-mode, loads that mode's
# tool-policy.yaml, and denies any MCP tool call matching a deny pattern.
# This is ENFORCEMENT, not suggestion — the model cannot bypass it.
#
# Policy files: .claude/modes/<mode>/tool-policy.yaml
# Format: YAML with a 'deny:' list of glob patterns (fnmatch-style).
#
# Exit protocol:
#   0 + deny JSON  = blocked
#   0 + no output  = no opinion (allow)
#   2              = block (error / fail-closed)
set -euo pipefail
trap 'exit 2' ERR

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
MODE_FILE="$PROJECT_DIR/.claude/.active-mode"

# No active mode = no policy to enforce
[[ -f "$MODE_FILE" ]] || exit 0

MODE="$(cat "$MODE_FILE" 2>/dev/null)"
[[ -n "$MODE" ]] || exit 0

POLICY_FILE="$PROJECT_DIR/.claude/modes/$MODE/tool-policy.yaml"
[[ -f "$POLICY_FILE" ]] || exit 0

# Read tool name from stdin JSON
input="$(cat)"
tool_name="$(printf '%s' "$input" | python3 -I -c '
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get("tool_name", ""))
except Exception:
    print("")
' 2>/dev/null || true)"

# Only gate MCP tools (mcp__*) — Bash/Read/Edit/Write handled by other hooks
[[ "$tool_name" == mcp__* ]] || exit 0

# Parse deny patterns from YAML (lightweight — no PyYAML needed)
# Supports: deny:\n  - "pattern"\n  - "pattern"
mapfile -t deny_patterns < <(
    python3 -I -c '
import sys, re
content = open(sys.argv[1]).read()
in_deny = False
for line in content.splitlines():
    stripped = line.strip()
    if stripped == "deny:":
        in_deny = True
        continue
    if in_deny:
        if stripped.startswith("- "):
            pattern = stripped[2:].strip().strip("\"").strip("'\''")
            print(pattern)
        elif stripped and not stripped.startswith("#"):
            break
' "$POLICY_FILE" 2>/dev/null
)

# Match tool_name against deny patterns (glob/fnmatch)
for pattern in "${deny_patterns[@]}"; do
    [[ -z "$pattern" ]] && continue
    # Convert glob pattern to bash extended glob for matching
    # Simple case: pattern ends with * (prefix match)
    if [[ "$pattern" == *'*' ]]; then
        prefix="${pattern%\*}"
        if [[ "$tool_name" == "$prefix"* ]]; then
            printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Blocked by mode policy: tool %s is not available in %s mode. Switch mode with /mode or start-mode.sh to access this tool."}}\n' "$tool_name" "$MODE"
            exit 0
        fi
    else
        # Exact match
        if [[ "$tool_name" == "$pattern" ]]; then
            printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Blocked by mode policy: tool %s is not available in %s mode. Switch mode with /mode or start-mode.sh to access this tool."}}\n' "$tool_name" "$MODE"
            exit 0
        fi
    fi
done

# No deny match — no opinion
exit 0
