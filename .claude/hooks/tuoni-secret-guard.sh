#!/usr/bin/env bash
# tuoni-secret-guard.sh — PreToolUse Bash guard.
#
# The permissions.deny rules in settings.json stop the file tools (Read/Edit/
# Grep/Glob) from opening the Tuoni live-mount secrets, but they do not bind the
# Bash tool. This hook closes that gap: it denies any Bash command that touches a
# Tuoni secret path (the live mount ~/tuoni-live or the server's /srv/tuoni),
# so credentials in config/ssl/keys/DB never reach the model's context.
#
# Read state through the tuoni MCP (redacted). Edit config by hand in your own
# terminal, not through Claude.
set -euo pipefail

input="$(cat)"
cmd="$(printf '%s' "$input" | python3 -I -c 'import sys,json
try: print(json.load(sys.stdin).get("tool_input",{}).get("command",""))
except Exception: print("")' 2>/dev/null || true)"

# Secret paths under the live mount and the server install:
#   config/ and ssl/ dirs, *.pem/*.keystore/*.jks keys, and the sqlite DB.
if printf '%s' "$cmd" | grep -Eiq \
  '(tuoni-live/(config|ssl)/|/srv/tuoni/(config|ssl)/|tuoni-(live|/srv/tuoni).*\.(pem|keystore|jks)|tuoni-live/.*\.(pem|keystore|jks)|/srv/tuoni/.*\.(pem|keystore|jks)|tuoni-db\.sqlite3)'; then
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Blocked: Bash access to a Tuoni secret path (config/ssl/keys/DB holds live credentials). Read state via the tuoni MCP instead; edit config by hand in your own terminal."}}\n'
  exit 0
fi
exit 0
