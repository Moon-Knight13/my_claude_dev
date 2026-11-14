#!/usr/bin/env bash
# Session-end engagement sync hook.
# Syncs engagement state to BOTH Obsidian wiki AND Claude memory file.
# Prevents session continuity failure where next session reads stale memory.
#
# Outputs additional context for Claude to act on before session closes.
# Not a hard gate — advisory output that prompts Claude to sync state.

set -euo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-.}"
ENG_DIR="$PROJECT_DIR/engagements"

# Find most recent active engagement YAML (not archived)
LATEST=$(find "$ENG_DIR" -maxdepth 1 -name '*.yaml' -type f 2>/dev/null \
  | sort -t/ -k2 | tail -1)

if [[ -z "$LATEST" ]]; then
  # No active engagement — nothing to sync
  exit 0
fi

ENG_ID=$(basename "$LATEST" .yaml)

# Build sync reminder output for Claude
OUTPUT=""

# --- Engagement state summary for memory sync ---
# Extract key fields (best-effort — yq may not be installed)
if command -v yq >/dev/null 2>&1; then
  # Detect yq flavor
  if yq --version 2>&1 | grep -qi "mikefarah\|version v\?[34]\."; then
    _yq() { yq "$@"; }
  else
    _yq() { yq -r "$@"; }
  fi

  PHASE=$(_yq '.phase // "unknown"' "$LATEST" 2>/dev/null || echo "unknown")
  TARGET_COUNT=$(_yq '.targets | length' "$LATEST" 2>/dev/null || echo 0)
  FINDING_COUNT=$(_yq '.findings | length' "$LATEST" 2>/dev/null || echo 0)
  CRED_COUNT=$(grep -c 'tuoni_cred_id:' "$LATEST" 2>/dev/null || echo 0)
  ENG_TYPE=$(_yq '.type // "standard"' "$LATEST" 2>/dev/null || echo "standard")
else
  PHASE=$(grep '^phase:' "$LATEST" 2>/dev/null | head -1 | sed 's/phase: *//' || echo "unknown")
  TARGET_COUNT=$(grep -c '  - hostname:' "$LATEST" 2>/dev/null || echo 0)
  FINDING_COUNT=$(grep -c '  - id:' "$LATEST" 2>/dev/null || echo 0)
  CRED_COUNT=$(grep -c 'tuoni_cred_id:' "$LATEST" 2>/dev/null || echo 0)
  ENG_TYPE=$(grep '^type:' "$LATEST" 2>/dev/null | head -1 | sed 's/type: *//' || echo "standard")
fi

OUTPUT+="SESSION-END SYNC REQUIRED for engagement $ENG_ID: "
OUTPUT+="phase=$PHASE, type=$ENG_TYPE, targets=$TARGET_COUNT, findings=$FINDING_COUNT, cred_refs=$CRED_COUNT. "

# --- Obsidian sync check ---
# Check if obsidian-mcp is likely available (can't query MCP from bash,
# but we can check if the wiki path exists locally)
WIKI_PAGE="llm-wiki/wiki/engagements/${ENG_ID}.md"
if [[ -d "$PROJECT_DIR/llm-wiki" ]]; then
  OUTPUT+="UPDATE Obsidian wiki page ($WIKI_PAGE) with final state. "
else
  OUTPUT+="WARN: llm-wiki directory not found locally — update Obsidian via obsidian-mcp if available, or log that sync was skipped. "
fi

# --- Claude memory sync ---
MEMORY_DIR="$HOME/.claude/projects/-home-chris-Documents-my-claude-dev/memory"
if [[ -d "$MEMORY_DIR" ]]; then
  OUTPUT+="UPDATE Claude memory file with engagement state summary (engagement ID: $ENG_ID, phase: $PHASE, targets: $TARGET_COUNT, findings: $FINDING_COUNT, creds: $CRED_COUNT). "
  OUTPUT+="Memory update prevents next session from duplicating completed work. "
else
  OUTPUT+="WARN: Claude memory directory not found at $MEMORY_DIR — memory sync skipped. "
fi

# --- Handoff note ---
OUTPUT+="Write concise handoff in both locations: what was completed, what is next, current access state."

echo "$OUTPUT"
