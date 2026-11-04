#!/usr/bin/env bash
# Session-end engagement audit hook.
# Checks engagement YAML for documentation gaps before session closes.
# Outputs additional context for Claude to act on — not a hard gate.

set -euo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-.}"
ENG_DIR="$PROJECT_DIR/engagements"

# Find most recent engagement YAML
LATEST=$(find "$ENG_DIR" -maxdepth 1 -name '*.yaml' -type f 2>/dev/null \
  | sort -t/ -k2 | tail -1)

if [[ -z "$LATEST" ]]; then
  exit 0
fi

ENG_ID=$(basename "$LATEST" .yaml)
WARNINGS=""

# Count techniques_tried vs findings
TECHNIQUES=$(grep -c -- '  - target:' "$LATEST" 2>/dev/null) || TECHNIQUES=0
FINDINGS=$(grep -c -- '  - id:' "$LATEST" 2>/dev/null) || FINDINGS=0

if [[ "$TECHNIQUES" -gt 0 ]] && [[ "$FINDINGS" -eq 0 ]]; then
  WARNINGS+="ENGAGEMENT AUDIT: $TECHNIQUES techniques tried but 0 findings recorded in $ENG_ID.yaml. Run catch-up procedure before closing. "
fi

if [[ "$TECHNIQUES" -gt "$FINDINGS" ]]; then
  GAP=$((TECHNIQUES - FINDINGS))
  WARNINGS+="ENGAGEMENT AUDIT: $GAP technique outcomes missing from findings in $ENG_ID.yaml. "
fi

# Check for credential refs
CRED_REFS=$(grep -c 'tuoni_cred_id:' "$LATEST" 2>/dev/null) || CRED_REFS=0
CRED_TECHNIQUES=$(grep -cE 'cred-harvest|Credential|T1003|credential' "$LATEST" 2>/dev/null) || CRED_TECHNIQUES=0
if [[ "$CRED_TECHNIQUES" -gt 0 ]] && [[ "$CRED_REFS" -eq 0 ]]; then
  WARNINGS+="ENGAGEMENT AUDIT: Credential techniques logged but 0 credential refs stored. Ensure creds stored in Tuoni cred store. "
fi

# Check plugin_inventory exists
if ! grep -q 'plugin_inventory:' "$LATEST" 2>/dev/null; then
  WARNINGS+="ENGAGEMENT AUDIT: No plugin_inventory in $ENG_ID.yaml. Run pre-engagement-cache to populate. "
fi

if [[ -n "$WARNINGS" ]]; then
  echo "$WARNINGS"
fi
