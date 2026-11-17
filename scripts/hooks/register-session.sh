#!/usr/bin/env bash
# register-session.sh — Register current Claude Code session for provenance.
#
# Creates a session file in .claude/sessions/ so the provenance hook can
# verify this session was started through a legitimate entry point.
#
# Called by start-mode.sh at session startup. Can also be run manually
# to register an existing session.
#
# Session file contains: mode, timestamp, and origin marker.
set -euo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SESSION_DIR="$PROJECT_DIR/.claude/sessions"
SESSION_ID="${CLAUDE_CODE_SESSION_ID:-}"

if [[ -z "$SESSION_ID" ]]; then
    echo "register-session: no CLAUDE_CODE_SESSION_ID set, skipping" >&2
    exit 0
fi

mkdir -p "$SESSION_DIR" 2>/dev/null || true

# Read current mode
MODE="unknown"
MODE_FILE="$PROJECT_DIR/.claude/.active-mode"
OVERRIDE_DIR="$PROJECT_DIR/.claude/.mode-overrides"
if [[ -n "$SESSION_ID" && -f "$OVERRIDE_DIR/$SESSION_ID" ]]; then
    MODE="$(cat "$OVERRIDE_DIR/$SESSION_ID" 2>/dev/null)" || true
elif [[ -f "$MODE_FILE" ]]; then
    MODE="$(cat "$MODE_FILE" 2>/dev/null)" || true
fi

# Write session registration (atomic via temp + mv)
TMPFILE="$SESSION_DIR/.tmp.$$"
cat > "$TMPFILE" <<EOF
session_id: ${SESSION_ID}
mode: ${MODE}
registered: $(date -u +%Y-%m-%dT%H:%M:%SZ)
origin: primary
EOF
mv -f "$TMPFILE" "$SESSION_DIR/$SESSION_ID"

# Clean stale sessions (older than 48h)
find "$SESSION_DIR" -maxdepth 1 -type f -mmin +2880 -delete 2>/dev/null || true

echo "register-session: registered $SESSION_ID (mode: $MODE)" >&2
exit 0
