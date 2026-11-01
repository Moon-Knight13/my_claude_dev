#!/usr/bin/env bash
# shellcheck disable=SC2015
# test-secret-scan.sh — UserPromptSubmit secret scan hook tests.
# Secrets in fixtures are split across fragments so the committed test file
# holds no literal secret that trips CI gates.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$ROOT/scripts/hooks/secret-scan.sh"
PASS=0; FAIL=0
ok()  { echo "  OK  $1"; ((PASS++)) || true; }
bad() { echo " FAIL $1"; ((FAIL++)) || true; }

command -v jq >/dev/null 2>&1 || { echo "jq required; skipping"; exit 0; }
[[ -x "$HOOK" ]]             || { echo "hook not found at $HOOK"; exit 1; }

# Helper: feed a prompt to the hook, capture exit code + stdout
run_hook() {
    local prompt="$1"
    local input
    input="$(jq -n --arg p "$prompt" '{prompt: $p}')"
    HOOK_OUT="$(printf '%s' "$input" | CLAUDE_PROJECT_DIR="$ROOT" bash "$HOOK" 2>/dev/null)"; HOOK_RC=$?
}

# ── 1. Clean prompt passes ────────────────────────────────────────────────────
run_hook "How do I fix a segfault in my parser?"
[[ $HOOK_RC -eq 0 ]]                    && ok "clean prompt: exit 0"                   || bad "clean prompt: exit $HOOK_RC"
[[ -z "$HOOK_OUT" || "$HOOK_OUT" != *rejectInput* ]] \
                                         && ok "clean prompt: no rejection"             || bad "clean prompt: unexpected rejection"

# ── 2. Password key-value blocked ─────────────────────────────────────────────
run_hook "config: password: SuperS3cret!123"
[[ $HOOK_RC -eq 2 ]]                    && ok "password kv: blocked (exit 2)"          || bad "password kv: exit $HOOK_RC"
[[ "$HOOK_OUT" == *rejectInput* ]]       && ok "password kv: rejectInput in output"    || bad "password kv: no rejectInput"
[[ "$HOOK_OUT" != *SuperS3cret* ]]       && ok "password kv: value NOT echoed"         || bad "LEAK: password value in output"

# ── 3. Jinja template value allowed ───────────────────────────────────────────
run_hook 'password: "{{ vault_password }}"'
[[ $HOOK_RC -eq 0 ]]                    && ok "jinja template: allowed"                || bad "jinja template: blocked (exit $HOOK_RC)"

# ── 4. Redacted value allowed ─────────────────────────────────────────────────
run_hook "password: <redacted>"
[[ $HOOK_RC -eq 0 ]]                    && ok "redacted value: allowed"                || bad "redacted value: blocked (exit $HOOK_RC)"

# ── 5. Placeholder values allowed ─────────────────────────────────────────────
run_hook "password: changeme"
[[ $HOOK_RC -eq 0 ]]                    && ok "changeme: allowed"                      || bad "changeme: blocked"
run_hook "token: your_token_here"
[[ $HOOK_RC -eq 0 ]]                    && ok "your_token: allowed"                    || bad "your_token: blocked"
run_hook "secret: placeholder"
[[ $HOOK_RC -eq 0 ]]                    && ok "placeholder: allowed"                   || bad "placeholder: blocked"

# ── 6. Private key blocked ────────────────────────────────────────────────────
PKEY="-----BEGIN RSA"" PRIVATE KEY-----
MIIEowIBAA...fake...
-----END RSA PRIVATE KEY-----"
run_hook "$PKEY"
[[ $HOOK_RC -eq 2 ]]                    && ok "private key: blocked"                   || bad "private key: exit $HOOK_RC"
[[ "$HOOK_OUT" == *"private key"* ]]     && ok "private key: named in reason"          || bad "private key: not named"

# ── 7. Vault token blocked ────────────────────────────────────────────────────
run_hook "export VAULT_TOKEN=hvs.""CAESIJIk3r7faketoken1234567890abcdefg"
[[ $HOOK_RC -eq 2 ]]                    && ok "vault token: blocked"                   || bad "vault token: exit $HOOK_RC"

# ── 8. GitHub PAT blocked ────────────────────────────────────────────────────
GH_PAT="ghp_""Zx9Kq2mNvBcD4fGhJkLpQrStUvWxYz012345678"
run_hook "git clone https://${GH_PAT}@github.com/user/repo"
[[ $HOOK_RC -eq 2 ]]                    && ok "github PAT: blocked"                    || bad "github PAT: exit $HOOK_RC"
[[ "$HOOK_OUT" != *"$GH_PAT"* ]]        && ok "github PAT: value NOT echoed"          || bad "LEAK: github PAT in output"

# ── 9. Anthropic key blocked ─────────────────────────────────────────────────
ANTHR="sk-ant-""api03-""Zx9Kq2mNvBcD4fGhJkLpQrStUvWxYz0123456789abcdefghijklm"
run_hook "ANTHROPIC_API_KEY=$ANTHR"
[[ $HOOK_RC -eq 2 ]]                    && ok "anthropic key: blocked"                 || bad "anthropic key: exit $HOOK_RC"

# ── 10. AWS access key blocked ───────────────────────────────────────────────
run_hook "aws_access_key_id = AKIA""IOSFODNN7EXAMPLE"
[[ $HOOK_RC -eq 2 ]]                    && ok "AWS key: blocked"                       || bad "AWS key: exit $HOOK_RC"

# ── 11. Slack token blocked ──────────────────────────────────────────────────
run_hook "SLACK_TOKEN=xoxb-""1234567890123-""AbCdEfGhIjKlMn"
[[ $HOOK_RC -eq 2 ]]                    && ok "slack token: blocked"                   || bad "slack token: exit $HOOK_RC"

# ── 12. Ansible loop item with password blocked ──────────────────────────────
ANSIBLE_OUT='TASK [create users] ***
fatal: [host1]: FAILED! => {"msg": "error", "item": {"username": "admin", "password": "RealP@ss123"}, "changed": false}'
run_hook "$ANSIBLE_OUT"
[[ $HOOK_RC -eq 2 ]]                    && ok "ansible output: blocked"                || bad "ansible output: exit $HOOK_RC"

# ── 13. Bearer token blocked ─────────────────────────────────────────────────
BEARER="Bearer eyJhbGciOiJSUzI1NiIs""InR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.fakesig"
run_hook "Authorization: $BEARER"
[[ $HOOK_RC -eq 2 ]]                    && ok "bearer token: blocked"                  || bad "bearer token: exit $HOOK_RC"

# ── 14. NOSECRET bypass works ────────────────────────────────────────────────
run_hook "NOSECRET: password: RealP@ss123"
[[ $HOOK_RC -eq 0 ]]                    && ok "NOSECRET bypass: allowed"               || bad "NOSECRET bypass: blocked"
[[ "$HOOK_OUT" == *modifiedPrompt* ]]    && ok "NOSECRET bypass: prompt rewritten"     || bad "NOSECRET bypass: no rewrite"
[[ "$HOOK_OUT" != *NOSECRET* ]]          && ok "NOSECRET prefix stripped"              || bad "NOSECRET prefix not stripped"

# ── 15. Empty prompt passes ──────────────────────────────────────────────────
run_hook ""
[[ $HOOK_RC -eq 0 ]]                    && ok "empty prompt: allowed"                  || bad "empty prompt: exit $HOOK_RC"

# ── 16. Null/no password values pass ─────────────────────────────────────────
run_hook "password: null"
[[ $HOOK_RC -eq 0 ]]                    && ok "null value: allowed"                    || bad "null value: blocked"
run_hook "password: "
[[ $HOOK_RC -eq 0 ]]                    && ok "empty value: allowed"                   || bad "empty value: blocked"

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "secret-scan: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
