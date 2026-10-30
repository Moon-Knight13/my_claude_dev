#!/usr/bin/env bash
# source-priority-guard.sh — PreToolUse advisory guard for source priority.
#
# Active in red-team mode only. Fires on WebSearch and WebFetch tool calls to
# remind the operator that web research is the lowest-priority source in the
# range intelligence hierarchy. This is a SOFT guard: it warns but never blocks.
#
# Source priority (highest → lowest):
#   1. Providentia (CMDB) — ground truth
#   2. GitLab READMEs — deploy notes
#   3. Wiki repo-docs — mirrored docs
#   4. Wiki vulns-docs — vuln research
#   5. Tuoni Discovery — live C2 state
#   6. Obsidian — tactical notes
#   7. Reference MCPs (HackTricks, MITRE, GTFOBins) — only when above insufficient
#   8. Web research — last resort
#
# Exit codes: always 0 (advisory only, never blocks).
set -euo pipefail

# ---------- mode check -------------------------------------------------------
# The /mode skill writes _mode into .claude/settings.json when switching modes.
# This guard only acts in red-team mode; in all other modes it is silent.
_settings="${CLAUDE_PROJECT_DIR:-.}/.claude/settings.json"
_mode=""
if [[ -f "$_settings" ]]; then
    _mode="$(python3 -I -c 'import sys,json
try: print(json.load(sys.stdin).get("_mode",""))
except Exception: print("")' < "$_settings" 2>/dev/null || true)"
fi
[[ "$_mode" == "red-team" ]] || exit 0

# ---------- parse tool call ---------------------------------------------------
INPUT="$(cat)"
TOOL="$(printf '%s' "$INPUT" | python3 -I -c 'import sys,json
try: print(json.load(sys.stdin).get("tool_name",""))
except Exception: print("")' 2>/dev/null || true)"

# Only act on web research tools.
case "$TOOL" in
    WebSearch|WebFetch) ;;
    *) exit 0 ;;
esac

# ---------- advisory warning --------------------------------------------------
# Output to stderr as an advisory. Exit 0 so the call proceeds.
cat >&2 << 'WARN'
⚠  SOURCE PRIORITY REMINDER (red-team mode)

Web research is priority 8 (last resort). Check higher-priority sources first:
  1. Providentia  — range-intel MCP (providentia_* tools)
  2. GitLab       — range-intel MCP (gitlab_* tools)
  3. Wiki         — outline-readonly MCP (outline_search / outline_read_document)
  4. Tuoni        — tuoni-mcp (discovery / agent state)
  5. Obsidian     — obsidian-mcp (tactical notes)
  6. Reference    — hacktricks-mcp, mitre-mcp, gtfobins-mcp

Proceeding with web lookup. If higher-priority sources were already checked,
this warning can be ignored.
WARN

exit 0
