#!/usr/bin/env bash
# tuoni-secret-guard.sh — user-level PreToolUse Bash guard.
# Deployed to ~/.claude/hooks/ by deploy-hq.sh.
# Denies Bash commands that touch Tuoni secret paths.
set -euo pipefail
trap 'exit 2' ERR

# Double-fire prevention: if project-level hook exists, let it handle this.
HOOK_NAME="$(basename "${BASH_SOURCE[0]}")"
if [[ -n "${CLAUDE_PROJECT_DIR:-}" && \
      -x "$CLAUDE_PROJECT_DIR/.claude/hooks/$HOOK_NAME" ]]; then
    exit 0
fi

input="$(cat)"
cmd="$(printf '%s' "$input" | python3 -I -c 'import sys,json
try: print(json.load(sys.stdin).get("tool_input",{}).get("command",""))
except Exception: print("")' 2>/dev/null || true)"

if printf '%s' "$cmd" | grep -Eiq \
  '(tuoni-live/(config|ssl)/|/srv/tuoni/(config|ssl)/|tuoni-(live|/srv/tuoni).*\.(pem|keystore|jks)|tuoni-live/.*\.(pem|keystore|jks)|/srv/tuoni/.*\.(pem|keystore|jks)|tuoni-db\.sqlite3)'; then
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Blocked: Bash access to a Tuoni secret path (config/ssl/keys/DB holds live credentials). Read state via the tuoni MCP instead; edit config by hand in your own terminal."}}\n'
  exit 0
fi
exit 0
