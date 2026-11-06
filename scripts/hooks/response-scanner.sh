#!/usr/bin/env bash
# response-scanner.sh — PostToolUse hook: scan tool output for secrets.
#
# Catches credentials that leak through MCP responses, Bash output, or
# file reads before they fully enter model context. On match: WARN the
# operator with the pattern name (never echo the value). The tool output
# has already been returned, so this hook cannot block it — it flags it
# for awareness and logs to the audit trail.
#
# Detection layers (same patterns as secret-scan.sh):
#   1. Private keys
#   2. API token formats (GitHub PAT, AWS, Anthropic, Slack, Stripe, etc.)
#   3. Key-value secret patterns (password:, token:, etc.)
#   4. HashiCorp Vault tokens
#
# Exit codes (PostToolUse protocol):
#   0  — always (PostToolUse cannot block; output is informational)
#
# Output: hookSpecificOutput with notification text shown to operator.
set -euo pipefail

HOOK_INPUT="$(cat)"

# Extract tool output (the response content)
TOOL_OUTPUT="$(printf '%s' "$HOOK_INPUT" | python3 -I -c '
import sys, json
try:
    data = json.load(sys.stdin)
    output = data.get("tool_result", {})
    if isinstance(output, str):
        print(output)
    elif isinstance(output, dict):
        print(json.dumps(output))
    elif isinstance(output, list):
        print(json.dumps(output))
    else:
        print(str(output))
except Exception:
    print("")
' 2>/dev/null || true)"

[[ -n "$TOOL_OUTPUT" ]] || exit 0

TOOL_NAME="$(printf '%s' "$HOOK_INPUT" | python3 -I -c '
import sys, json
try: print(json.load(sys.stdin).get("tool_name",""))
except: print("")' 2>/dev/null || true)"

FINDINGS=()

# ── Private keys ──────────────────────────────────────────────────────────
if [[ "$TOOL_OUTPUT" =~ -----BEGIN[[:space:]]+(RSA|DSA|EC|OPENSSH|PGP|ENCRYPTED)?[[:space:]]*PRIVATE[[:space:]]+KEY----- ]]; then
    FINDINGS+=("private key in response")
fi

# ── API token formats ─────────────────────────────────────────────────────
[[ "$TOOL_OUTPUT" =~ ghp_[A-Za-z0-9]{36,} ]] && FINDINGS+=("GitHub PAT")
[[ "$TOOL_OUTPUT" =~ github_pat_[A-Za-z0-9_]{22,} ]] && FINDINGS+=("GitHub fine-grained PAT")
[[ "$TOOL_OUTPUT" =~ sk-ant-api[0-9]{2}-[A-Za-z0-9_-]{40,} ]] && FINDINGS+=("Anthropic API key")
[[ "$TOOL_OUTPUT" =~ sk-proj-[A-Za-z0-9_-]{40,} ]] && FINDINGS+=("OpenAI project key")
[[ "$TOOL_OUTPUT" =~ AKIA[0-9A-Z]{16} ]] && FINDINGS+=("AWS access key")
[[ "$TOOL_OUTPUT" =~ xoxb-[0-9]{10,}-[A-Za-z0-9]+ ]] && FINDINGS+=("Slack bot token")
[[ "$TOOL_OUTPUT" =~ sk_live_[A-Za-z0-9]{24,} ]] && FINDINGS+=("Stripe live key")
[[ "$TOOL_OUTPUT" =~ hvs\.[A-Za-z0-9_-]{24,} ]] && FINDINGS+=("Vault token")

# ── Key-value secret patterns ─────────────────────────────────────────────
# Scan first 200 lines only to avoid performance hit on large outputs
_head="$(echo "$TOOL_OUTPUT" | head -200)"
while IFS= read -r line; do
    if [[ "$line" =~ (password|passwd|secret|token|api_key|apikey|private_key|auth_token|access_key|secret_key|client_secret|db_password)[[:space:]]*[:=][[:space:]]*(.*) ]]; then
        local_val="${BASH_REMATCH[2]}"
        local_val="${local_val#\"}"
        local_val="${local_val%\"}"
        local_val="${local_val#\'}"
        local_val="${local_val%\'}"
        local_val="${local_val#"${local_val%%[![:space:]]*}"}"
        [[ -z "$local_val" ]] && continue
        [[ "$local_val" == "{{"*"}}" ]] && continue
        [[ "$local_val" == "<redacted>"* ]] && continue
        [[ "$local_val" == "REDACTED"* ]] && continue
        [[ "$local_val" == "***"* ]] && continue
        [[ "$local_val" == "null" ]] && continue
        [[ "$local_val" == "None" ]] && continue
        [[ "$local_val" == "changeme" ]] && continue
        [[ "$local_val" == "your_"* ]] && continue
        [[ "$local_val" == "example"* ]] && continue
        [[ "$local_val" == "placeholder"* ]] && continue
        [[ "$local_val" == "xxx"* ]] && continue
        [[ ${#local_val} -lt 4 ]] && continue
        FINDINGS+=("key-value secret (${BASH_REMATCH[1]})")
        break
    fi
done <<< "$_head"

# ── Verdict ───────────────────────────────────────────────────────────────
if (( ${#FINDINGS[@]} == 0 )); then
    exit 0
fi

# Deduplicate
declare -A seen
unique=()
for f in "${FINDINGS[@]}"; do
    [[ -n "${seen[$f]:-}" ]] && continue
    seen[$f]=1
    unique+=("$f")
done

# Log to audit trail
AUDIT_DIR="${CLAUDE_PROJECT_DIR:-.}/.claude/audit"
mkdir -p "$AUDIT_DIR" 2>/dev/null || true
AUDIT_FILE="$AUDIT_DIR/secret-detections.jsonl"
MODE="$(cat "${CLAUDE_PROJECT_DIR:-.}/.claude/.active-mode" 2>/dev/null || echo "unknown")"

# Append detection to audit log (never log the actual secret value)
python3 -I -c '
import json, sys, datetime
findings = sys.argv[1:]
entry = {
    "timestamp": datetime.datetime.utcnow().isoformat() + "Z",
    "event": "secret_detected_in_response",
    "tool": "'"$TOOL_NAME"'",
    "mode": "'"$MODE"'",
    "findings": findings,
}
print(json.dumps(entry))
' "${unique[@]}" >> "$AUDIT_FILE" 2>/dev/null || true

# Warn the operator (PostToolUse notification — cannot block)
warning="SECRET DETECTED in $TOOL_NAME response: ${unique[*]}. Review output before proceeding. This detection is logged to .claude/audit/secret-detections.jsonl"

printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","notification":"%s"}}\n' \
    "$(printf '%s' "$warning" | python3 -I -c 'import sys,json; print(json.dumps(sys.stdin.read())[1:-1])')"
exit 0
