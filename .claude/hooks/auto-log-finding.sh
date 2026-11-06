#!/usr/bin/env bash
# auto-log-finding.sh — PostToolUse hook for tuoni_command_get results.
#
# Detects actionable findings (credentials, new hosts, access, services)
# in command output and emits a notification prompting /log-finding.
#
# Matcher: mcp__tuoni-mcp__tuoni_command_get (set in settings.json)
# Mode guard: only fires in red-team or purple mode.
#
# Exit: always 0 (PostToolUse is informational, cannot block).
# Output: hookSpecificOutput notification when findings detected.
set -euo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# ── Mode guard: only red-team and purple produce engagement findings ──
MODE_FILE="$PROJECT_DIR/.claude/.active-mode"
if [[ -f "$MODE_FILE" ]]; then
    MODE="$(cat "$MODE_FILE" 2>/dev/null)"
else
    exit 0
fi
case "$MODE" in
    red-team|purple) ;;
    *) exit 0 ;;
esac

# ── Parse hook input ──────────────────────────────────────────────────
HOOK_INPUT="$(cat)"

RESULT="$(printf '%s' "$HOOK_INPUT" | python3 -I -c '
import sys, json
try:
    data = json.load(sys.stdin)
    result = data.get("tool_result", "")
    if isinstance(result, str):
        print(result)
    elif isinstance(result, (dict, list)):
        print(json.dumps(result))
    else:
        print(str(result))
except Exception:
    print("")
' 2>/dev/null || true)"

[[ -n "$RESULT" ]] || exit 0

# ── Detect actionable findings ────────────────────────────────────────
# Each category appends to FINDINGS array with a short label.
# Patterns are intentionally broad — false positives are cheap (just a
# suggestion), false negatives lose knowledge.
FINDINGS=()

# Credentials: hashes, cleartext passwords, tokens, kerberos tickets
if printf '%s' "$RESULT" | grep -qiE \
    '([a-fA-F0-9]{32}:[a-fA-F0-9]{32}|NTLM|NTHash|password[[:space:]]*[:=]|plaintext|cleartext|credentials?[[:space:]]+found|krbtgt|TGT|TGS|\.kirbi|base64.*ticket|Kerberos|ServicePrincipalName|SPN)'; then
    FINDINGS+=("credentials/hashes")
fi

# New hosts or IPs discovered
if printf '%s' "$RESULT" | grep -qiE \
    '(alive|host[[:space:]]+discovered|new[[:space:]]+host|reachable|responding|[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}.*open|scan.*complete)'; then
    FINDINGS+=("host-discovery")
fi

# Access gained: shells, escalation, sessions
if printf '%s' "$RESULT" | grep -qiE \
    '(NT AUTHORITY\\SYSTEM|root@|admin(istrator)?[[:space:]]*access|privilege[[:space:]]*escalat|impersonat|session[[:space:]]+opened|shell[[:space:]]+obtained|reverse[[:space:]]+shell|beacon[[:space:]]+established|access[[:space:]]+granted)'; then
    FINDINGS+=("access-gained")
fi

# Service enumeration results
if printf '%s' "$RESULT" | grep -qiE \
    '(listening|open[[:space:]]+port|service[[:space:]]+detected|SMB|WinRM|RDP|SSH|MSSQL|MySQL|LDAP|Kerberos|HTTP[S]?[[:space:]]+server|IIS|Apache|nginx)'; then
    FINDINGS+=("service-enumeration")
fi

# File access: sensitive files, configs, SAM/SYSTEM, shadow
if printf '%s' "$RESULT" | grep -qiE \
    '(SAM|SYSTEM|SECURITY|NTDS\.dit|shadow|passwd|authorized_keys|id_rsa|web\.config|unattend\.xml|Groups\.xml|\.kdbx|keepass|credential[[:space:]]+manager)'; then
    FINDINGS+=("sensitive-file-access")
fi

# Lateral movement indicators
if printf '%s' "$RESULT" | grep -qiE \
    '(psexec|wmiexec|smbexec|atexec|dcomexec|evil-winrm|pass.the.hash|overpass|golden[[:space:]]+ticket|silver[[:space:]]+ticket|DCSync|secretsdump)'; then
    FINDINGS+=("lateral-movement")
fi

[[ ${#FINDINGS[@]} -gt 0 ]] || exit 0

# ── Build notification ────────────────────────────────────────────────
# Join findings into comma-separated string
FINDING_LIST=$(IFS=', '; echo "${FINDINGS[*]}")

# Extract a one-line summary from the result (first non-empty line, truncated)
SUMMARY="$(printf '%s' "$RESULT" | python3 -I -c '
import sys, json
text = sys.stdin.read()
try:
    data = json.loads(text)
    if isinstance(data, dict):
        text = data.get("output", data.get("result", data.get("text", str(data))))
    elif isinstance(data, list):
        text = str(data[0]) if data else ""
except (json.JSONDecodeError, ValueError):
    pass
for line in str(text).splitlines():
    stripped = line.strip()
    if stripped and len(stripped) > 5:
        print(stripped[:120])
        break
' 2>/dev/null || true)"

# Escape for JSON output
FINDING_LIST_ESC="$(printf '%s' "$FINDING_LIST" | sed 's/"/\\"/g')"
SUMMARY_ESC="$(printf '%s' "$SUMMARY" | sed 's/"/\\"/g')"

cat <<EOF
{"hookSpecificOutput":{"hookEventName":"PostToolUse","notification":"FINDING DETECTED [${FINDING_LIST_ESC}] in tuoni_command_get result. Summary: ${SUMMARY_ESC}. Invoke /log-finding with the technique, target, and outcome to capture this before context is lost."}}
EOF
