#!/usr/bin/env bash
# PreToolUse hook: source-priority guard for red-team mode.
#
# Warns (but does not block) when reference MCPs (Tier 3) are queried
# before authoritative sources (Tier 1/2) for the same target. Tracking
# is per-session via a state file.
#
# Tier 1 (authoritative): range-intel (Providentia + GitLab READMEs)
# Tier 2 (operational):   tuoni-mcp discovery, obsidian-mcp
# Tier 3 (reference):     hacktricks-mcp, mitre-mcp, gtfobins-mcp, eip-mcp
#
# Exit 0 = allow, exit 2 = warn (allow but show message).
set -euo pipefail

TOOL_NAME="${CLAUDE_TOOL_NAME:-}"
STATE_DIR="${CLAUDE_STATE_DIR:-/tmp/source-priority}"
STATE_FILE="$STATE_DIR/queried-tiers"

mkdir -p "$STATE_DIR"
touch "$STATE_FILE"

# Only applies in red-team mode
MODE_FILE="${CLAUDE_PROJECT_DIR:-.}/.claude/settings.json"
if [[ -f "$MODE_FILE" ]]; then
    current_mode="$(jq -r '._mode // "unknown"' "$MODE_FILE" 2>/dev/null || echo "unknown")"
    if [[ "$current_mode" != "red-team" ]]; then
        exit 0
    fi
fi

# Map tool to tier
tier=""
case "$TOOL_NAME" in
    mcp__range-intel__*|mcp__range_intel__*)
        tier="1"
        ;;
    mcp__outline-readonly__*|mcp__outline_readonly__*)
        tier="1"
        ;;
    mcp__tuoni-mcp__tuoni_discovery_*|mcp__tuoni_mcp__tuoni_discovery_*)
        tier="2"
        ;;
    mcp__obsidian-mcp__*|mcp__obsidian_mcp__*)
        tier="2"
        ;;
    mcp__hacktricks-mcp__*|mcp__hacktricks_mcp__*)
        tier="3"
        ;;
    mcp__mitre-mcp__*|mcp__mitre_mcp__*|mcp__mitre-attack-mcp__*|mcp__mitre_attack_mcp__*)
        tier="3"
        ;;
    mcp__gtfobins-mcp__*|mcp__gtfobins_mcp__*)
        tier="3"
        ;;
    mcp__eip-mcp__*|mcp__eip_mcp__*)
        tier="3"
        ;;
    *)
        exit 0
        ;;
esac

# Record this tier was queried
echo "$tier" >> "$STATE_FILE"

# Check: if this is Tier 3, has Tier 1 been queried this session?
if [[ "$tier" == "3" ]]; then
    if ! grep -q "^1$" "$STATE_FILE" 2>/dev/null; then
        echo "SOURCE PRIORITY: querying reference MCP ($TOOL_NAME) before authoritative sources (Providentia/GitLab/wiki). Query range-intel first for ground truth." >&2
        exit 2
    fi
fi

exit 0
