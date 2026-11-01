#!/usr/bin/env bash
# UserPromptSubmit hook: scan submitted prompts for secrets before they reach
# the model. On match: BLOCK and name the pattern (never echo the value).
#
# Detection layers:
#   1. Custom regex: password:/passwd:/secret:/token: keys with non-empty,
#      non-templated values; private keys; Vault tokens; common API token
#      formats (GitHub PAT, AWS, Anthropic, Slack, etc.)
#   2. gitleaks stdin: runs the repo's .gitleaks.toml rules if gitleaks is
#      installed; catches the 100+ default secret patterns plus custom rules.
#
# Bypass: prefix the prompt with NOSECRET: to skip scanning. The prefix is
# stripped from the prompt before forwarding (via hookSpecificOutput). Use only
# for confirmed false positives. The bypass is logged to stderr.
#
# Exit codes (Claude Code UserPromptSubmit protocol):
#   0  — allow (with optional hookSpecificOutput JSON on stdout)
#   2  — block (hookSpecificOutput with reason on stdout)
#
# Env: CLAUDE_PROJECT_DIR (set by Claude Code), PROMPT via stdin JSON.
set -euo pipefail

HOOK_INPUT="$(cat)"
PROMPT="$(printf '%s' "$HOOK_INPUT" | jq -r '.prompt // empty' 2>/dev/null)"

[[ -n "$PROMPT" ]] || exit 0

# ── Bypass ──────────────────────────────────────────────────────────────────
if [[ "$PROMPT" == NOSECRET:* ]]; then
    echo "secret-scan: bypass requested — scanning skipped" >&2
    STRIPPED="${PROMPT#NOSECRET:}"
    STRIPPED="${STRIPPED#"${STRIPPED%%[![:space:]]*}"}"
    printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","modifiedPrompt":"%s"}}\n' \
        "$(printf '%s' "$STRIPPED" | jq -Rs '.' | sed 's/^"//;s/"$//')"
    exit 0
fi

FINDINGS=()

# ── Layer 1: custom regex patterns ──────────────────────────────────────────

# Password/secret key-value pairs (YAML, JSON, env-var style).
# Skip Jinja templates {{ }}, <redacted>, *** , empty values.
_check_kv_secrets() {
    # Match: password: "value", secret = value, token: 'value', etc.
    # Captures the key name for reporting.
    while IFS= read -r line; do
        # Extract key-value where key is a secret-like word
        if [[ "$line" =~ (password|passwd|pass|secret|token|api_key|apikey|api[-_]?secret|private[-_]?key|auth[-_]?token|access[-_]?key|secret[-_]?key|client[-_]?secret|db[-_]?password|database[-_]?password|mysql[-_]?password|admin[-_]?password)[[:space:]]*[:=][[:space:]]*(.*) ]]; then
            local key="${BASH_REMATCH[1]}"
            local val="${BASH_REMATCH[2]}"
            # Strip quotes
            val="${val#\"}"
            val="${val%\"}"
            val="${val#\'}"
            val="${val%\'}"
            # Trim whitespace
            val="${val#"${val%%[![:space:]]*}"}"
            val="${val%"${val##*[![:space:]]}"}"
            # Skip safe patterns
            [[ -z "$val" ]] && continue
            [[ "$val" == "{{"*"}}" ]] && continue
            [[ "$val" == "<%"*"%>" ]] && continue
            [[ "$val" == "<redacted>"* ]] && continue
            [[ "$val" == "REDACTED"* ]] && continue
            [[ "$val" == "***"* ]] && continue
            [[ "$val" == "..."* ]] && continue
            [[ "$val" == "null" ]] && continue
            [[ "$val" == "None" ]] && continue
            [[ "$val" == "undefined" ]] && continue
            [[ "$val" == "changeme" ]] && continue
            [[ "$val" == "CHANGEME" ]] && continue
            [[ "$val" == "your_"* ]] && continue
            [[ "$val" == "your-"* ]] && continue
            [[ "$val" == "example"* ]] && continue
            [[ "$val" == "placeholder"* ]] && continue
            [[ "$val" == "xxx"* ]] && continue
            [[ "$val" == "TODO"* ]] && continue
            FINDINGS+=("key-value secret pattern ('$key: ...')")
        fi
    done <<< "$PROMPT"
}

# Private keys
_check_private_keys() {
    if [[ "$PROMPT" =~ -----BEGIN[[:space:]]+(RSA|DSA|EC|OPENSSH|PGP|ENCRYPTED)?[[:space:]]*PRIVATE[[:space:]]+KEY----- ]]; then
        FINDINGS+=("private key block (-----BEGIN ... PRIVATE KEY-----)")
    fi
}

# Vault tokens
_check_vault_tokens() {
    if [[ "$PROMPT" =~ hvs\.[A-Za-z0-9_-]{24,} ]]; then
        FINDINGS+=("HashiCorp Vault token (hvs.*)")
    fi
    if [[ "$PROMPT" =~ s\.[A-Za-z0-9]{24,} ]]; then
        FINDINGS+=("HashiCorp Vault token (s.*)")
    fi
}

# Common API token formats
_check_api_tokens() {
    # GitHub PAT (classic and fine-grained)
    if [[ "$PROMPT" =~ ghp_[A-Za-z0-9]{36,} ]]; then
        FINDINGS+=("GitHub personal access token (ghp_*)")
    fi
    if [[ "$PROMPT" =~ github_pat_[A-Za-z0-9_]{22,} ]]; then
        FINDINGS+=("GitHub fine-grained PAT (github_pat_*)")
    fi
    if [[ "$PROMPT" =~ gho_[A-Za-z0-9]{36,} ]]; then
        FINDINGS+=("GitHub OAuth token (gho_*)")
    fi
    if [[ "$PROMPT" =~ ghu_[A-Za-z0-9]{36,} ]]; then
        FINDINGS+=("GitHub user-to-server token (ghu_*)")
    fi
    if [[ "$PROMPT" =~ ghs_[A-Za-z0-9]{36,} ]]; then
        FINDINGS+=("GitHub server-to-server token (ghs_*)")
    fi
    # Anthropic
    if [[ "$PROMPT" =~ sk-ant-api[0-9]{2}-[A-Za-z0-9_-]{40,} ]]; then
        FINDINGS+=("Anthropic API key (sk-ant-api*)")
    fi
    # OpenAI
    if [[ "$PROMPT" =~ sk-[A-Za-z0-9]{20,}T3BlbkFJ[A-Za-z0-9]{20,} ]]; then
        FINDINGS+=("OpenAI API key (sk-*T3BlbkFJ*)")
    fi
    if [[ "$PROMPT" =~ sk-proj-[A-Za-z0-9_-]{40,} ]]; then
        FINDINGS+=("OpenAI project key (sk-proj-*)")
    fi
    # AWS
    if [[ "$PROMPT" =~ AKIA[0-9A-Z]{16} ]]; then
        FINDINGS+=("AWS access key ID (AKIA*)")
    fi
    # Slack
    if [[ "$PROMPT" =~ xoxb-[0-9]{10,}-[A-Za-z0-9]+ ]]; then
        FINDINGS+=("Slack bot token (xoxb-*)")
    fi
    if [[ "$PROMPT" =~ xoxp-[0-9]{10,}-[A-Za-z0-9]+ ]]; then
        FINDINGS+=("Slack user token (xoxp-*)")
    fi
    if [[ "$PROMPT" =~ xoxs-[0-9]{10,}-[A-Za-z0-9]+ ]]; then
        FINDINGS+=("Slack session token (xoxs-*)")
    fi
    # Stripe
    if [[ "$PROMPT" =~ sk_live_[A-Za-z0-9]{24,} ]]; then
        FINDINGS+=("Stripe live secret key (sk_live_*)")
    fi
    # Generic long bearer token (40+ hex/base64 chars after "Bearer ")
    if [[ "$PROMPT" =~ Bearer[[:space:]]+[A-Za-z0-9+/._=-]{40,} ]]; then
        FINDINGS+=("Bearer token (40+ character token after 'Bearer')")
    fi
}

# Ansible-style output with embedded credentials
_check_ansible_output() {
    # Ansible failed loop item with password field
    if [[ "$PROMPT" =~ \"item\":[[:space:]]*\{ ]] && [[ "$PROMPT" =~ \"password\":[[:space:]]*\" ]]; then
        FINDINGS+=("Ansible output with embedded password in loop item")
    fi
}

_check_kv_secrets
_check_private_keys
_check_vault_tokens
_check_api_tokens
_check_ansible_output

# ── Layer 2: gitleaks (if available) ────────────────────────────────────────
GITLEAKS_CONFIG="${CLAUDE_PROJECT_DIR:-.}/.gitleaks.toml"
if command -v gitleaks >/dev/null 2>&1; then
    gitleaks_args=(stdin --no-banner --report-format json --report-path /dev/stdout)
    if [[ -f "$GITLEAKS_CONFIG" ]]; then
        gitleaks_args+=(--config "$GITLEAKS_CONFIG")
    fi
    gitleaks_out="$(printf '%s' "$PROMPT" | gitleaks "${gitleaks_args[@]}" 2>/dev/null)" || true
    if [[ -n "$gitleaks_out" && "$gitleaks_out" != "[]" ]]; then
        # Extract rule IDs from findings
        while IFS= read -r rule_id; do
            [[ -n "$rule_id" ]] && FINDINGS+=("gitleaks: $rule_id")
        done < <(printf '%s' "$gitleaks_out" | jq -r '.[].RuleID // empty' 2>/dev/null)
    fi
fi

# ── Verdict ─────────────────────────────────────────────────────────────────
if (( ${#FINDINGS[@]} == 0 )); then
    exit 0
fi

# Deduplicate findings
declare -A seen
unique=()
for f in "${FINDINGS[@]}"; do
    [[ -n "${seen[$f]:-}" ]] && continue
    seen[$f]=1
    unique+=("$f")
done

reason="BLOCKED — potential secret(s) detected in prompt. Patterns matched: "
for i in "${!unique[@]}"; do
    (( i > 0 )) && reason+="; "
    reason+="${unique[$i]}"
done
reason+=". Redact the sensitive values and re-submit. To bypass (false positive only): prefix prompt with NOSECRET:"

# Truncate for JSON safety (the protocol has no hard limit, but keep reasonable)
reason="${reason:0:2000}"
# Escape for JSON
reason_json="$(printf '%s' "$reason" | jq -Rs '.' | sed 's/^"//;s/"$//')"

printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","rejectInput":true,"rejectMessage":"%s"}}\n' "$reason_json"
exit 2
