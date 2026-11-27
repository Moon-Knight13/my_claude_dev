#!/usr/bin/env bash
# test-provenance-hook.sh — verify pretooluse-provenance.sh hook enforcement
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$PROJECT_DIR/.claude/hooks/pretooluse-provenance.sh"

PASS=0; FAIL=0

ok()   { echo "  PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

[[ -x "$HOOK" ]] || { echo "FAIL: hook not executable"; exit 1; }

# --- Setup test fixtures ---
TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# Copy policy file to temp project dir
TEST_PROJECT="$TEST_TMPDIR/project"
mkdir -p "$TEST_PROJECT/.claude/hooks"
mkdir -p "$TEST_PROJECT/.claude/sessions"
mkdir -p "$TEST_PROJECT/.claude/audit"
cp "$PROJECT_DIR/.claude/provenance-policy.yaml" "$TEST_PROJECT/.claude/"
cp "$HOOK" "$TEST_PROJECT/.claude/hooks/"

# Make the hook find the policy in the test project
_call_hook() {
    local session_id="$1" mode="$2" tool_name="$3" tool_input="${4:-{}}"
    local mode_file="$TEST_PROJECT/.claude/.active-mode"

    mkdir -p "$(dirname "$mode_file")"
    echo "$mode" > "$mode_file"

    local result
    result="$(printf '{"tool_name":"%s","tool_input":%s}' "$tool_name" "$tool_input" | \
        CLAUDE_PROJECT_DIR="$TEST_PROJECT" \
        CLAUDE_CODE_SESSION_ID="$session_id" \
        bash "$TEST_PROJECT/.claude/hooks/pretooluse-provenance.sh" 2>/dev/null)" || true
    echo "$result"
}

_register_session() {
    local session_id="$1" mode="$2"
    local session_file="$TEST_PROJECT/.claude/sessions/$session_id"
    cat > "$session_file" <<EOF
session_id: ${session_id}
mode: ${mode}
registered: $(date -u +%Y-%m-%dT%H:%M:%SZ)
origin: primary
EOF
}

_is_denied() {
    echo "$1" | grep -q '"permissionDecision":"deny"'
}

_is_allowed() {
    [[ -z "$1" ]] || ! echo "$1" | grep -q '"permissionDecision":"deny"'
}

echo "=== Provenance Hook Tests ==="
echo ""

# -----------------------------------------------------------------------
echo "--- Critical tool WITHOUT session registration = denied ---"
result="$(_call_hook "test-session-001" "red-team" "mcp__tuoni-mcp__tuoni_command_prepare")"
if _is_denied "$result"; then
    ok "unregistered session denied for critical tool"
else
    fail "unregistered session should be denied for critical tool"
fi

# -----------------------------------------------------------------------
echo ""
echo "--- Critical tool WITH registered session in correct mode = allowed ---"
_register_session "test-session-002" "red-team"
result="$(_call_hook "test-session-002" "red-team" "mcp__tuoni-mcp__tuoni_command_prepare")"
if _is_allowed "$result"; then
    ok "registered session in red-team allowed for critical tool"
else
    fail "registered session in red-team should be allowed for critical tool"
fi

# -----------------------------------------------------------------------
echo ""
echo "--- Critical tool in wrong mode = denied ---"
_register_session "test-session-003" "green-dev"
result="$(_call_hook "test-session-003" "green-dev" "mcp__tuoni-mcp__tuoni_command_prepare")"
if _is_denied "$result"; then
    ok "green-dev mode denied for critical tool"
else
    fail "green-dev should be denied for critical tool"
fi

# -----------------------------------------------------------------------
echo ""
echo "--- Critical tool with no session ID = denied ---"
result="$(_call_hook "" "red-team" "mcp__tuoni-mcp__tuoni_command_prepare")"
if _is_denied "$result"; then
    ok "no session ID denied for critical tool"
else
    fail "no session ID should be denied for critical tool"
fi

# -----------------------------------------------------------------------
echo ""
echo "--- Sensitive tool in allowed mode with session = allowed ---"
_register_session "test-session-004" "platform-ops"
result="$(_call_hook "test-session-004" "platform-ops" "mcp__range-intel__query_hosts")"
if _is_allowed "$result"; then
    ok "registered session in platform-ops allowed for sensitive tool"
else
    fail "registered session in platform-ops should allow sensitive tool"
fi

# -----------------------------------------------------------------------
echo ""
echo "--- Monitored tool = always allowed (log only) ---"
result="$(_call_hook "unregistered-999" "base" "mcp__hacktricks-mcp__search")"
if _is_allowed "$result"; then
    ok "monitored tool allowed without registration"
else
    fail "monitored tool should be allowed (log only)"
fi

# -----------------------------------------------------------------------
echo ""
echo "--- Unclassified tool = no opinion (allowed) ---"
result="$(_call_hook "any-session" "base" "Read")"
if _is_allowed "$result"; then
    ok "unclassified tool gets no opinion"
else
    fail "unclassified tool should pass through"
fi

result="$(_call_hook "any-session" "base" "Edit")"
if _is_allowed "$result"; then
    ok "Edit tool passes through"
else
    fail "Edit should pass through"
fi

# -----------------------------------------------------------------------
echo ""
echo "--- Bash commands pass through (ctp guard handles Bash gating) ---"
result="$(_call_hook "any-session" "base" "Bash" '{"command":"ls -la /tmp"}')"
if _is_allowed "$result"; then
    ok "Bash passes through to other guards"
else
    fail "Bash should pass through provenance hook"
fi

# -----------------------------------------------------------------------
echo ""
echo "--- Stale session = denied ---"
_register_session "test-session-stale" "red-team"
# Backdate the session file by 25h
touch -d "25 hours ago" "$TEST_PROJECT/.claude/sessions/test-session-stale"
result="$(_call_hook "test-session-stale" "red-team" "mcp__tuoni-mcp__tuoni_command_prepare")"
if _is_denied "$result"; then
    ok "stale session denied"
else
    fail "stale session should be denied"
fi

# -----------------------------------------------------------------------
echo ""
echo "--- Provenance audit log written ---"
LOG_FILE="$TEST_PROJECT/.claude/audit/provenance.jsonl"
if [[ -f "$LOG_FILE" ]]; then
    ENTRIES=$(wc -l < "$LOG_FILE")
    if [[ "$ENTRIES" -gt 0 ]]; then
        ok "provenance audit log has $ENTRIES entries"
    else
        fail "provenance audit log should have entries"
    fi
    # Verify JSON structure
    if python3 -I -c '
import json, sys
with open(sys.argv[1]) as f:
    for line in f:
        entry = json.loads(line)
        assert "t" in entry
        assert "session" in entry
        assert "mode" in entry
        assert "tool" in entry
        assert "class" in entry
' "$LOG_FILE" 2>/dev/null; then
        ok "provenance log entries are valid JSON with required fields"
    else
        fail "provenance log entries should be valid JSON"
    fi
else
    fail "provenance audit log should exist"
fi

# -----------------------------------------------------------------------
echo ""
echo "--- Deny message includes tool and mode ---"
result="$(_call_hook "test-session-003" "green-dev" "mcp__tuoni-mcp__tuoni_command_prepare")"
if echo "$result" | grep -q "green-dev"; then
    ok "deny message includes mode name"
else
    fail "deny message should include mode name"
fi
if echo "$result" | grep -q "tuoni_command"; then
    ok "deny message includes tool name"
else
    fail "deny message should include tool name"
fi

# -----------------------------------------------------------------------
echo ""
echo "--- Previously-bypassed critical tools now gated ---"
_register_session "test-session-bypass" "green-dev"

for tool in tuoni_operation_execute tuoni_payload_create tuoni_payload_delete \
            tuoni_payload_rename tuoni_user_set_password tuoni_settings_update_bulk \
            tuoni_credential_add tuoni_credential_archive tuoni_credential_update \
            tuoni_host_add tuoni_host_archive tuoni_host_update \
            tuoni_job_pause tuoni_job_restart tuoni_job_resume; do
    result="$(_call_hook "test-session-bypass" "green-dev" "mcp__tuoni-mcp__${tool}")"
    if _is_denied "$result"; then
        ok "green-dev denies mcp__tuoni-mcp__${tool}"
    else
        fail "green-dev should deny mcp__tuoni-mcp__${tool}"
    fi
done

echo ""
echo "--- Previously-bypassed critical tools allowed in red-team ---"
_register_session "test-session-rt" "red-team"

for tool in tuoni_operation_execute tuoni_payload_create tuoni_credential_add \
            tuoni_host_add tuoni_job_pause tuoni_settings_update_bulk; do
    result="$(_call_hook "test-session-rt" "red-team" "mcp__tuoni-mcp__${tool}")"
    if _is_allowed "$result"; then
        ok "red-team allows mcp__tuoni-mcp__${tool}"
    else
        fail "red-team should allow mcp__tuoni-mcp__${tool}"
    fi
done

echo ""
echo "--- Sensitive read-only tools allowed in green-dev ---"
for tool in tuoni_credentials_list tuoni_hosts_list tuoni_agents_list \
            tuoni_listeners_list tuoni_capabilities tuoni_aliases_list \
            tuoni_jobs_list tuoni_commands_list; do
    result="$(_call_hook "test-session-bypass" "green-dev" "mcp__tuoni-mcp__${tool}")"
    if _is_allowed "$result"; then
        ok "green-dev (sensitive mode) allows mcp__tuoni-mcp__${tool}"
    else
        fail "green-dev should allow sensitive tool mcp__tuoni-mcp__${tool}"
    fi
done

echo ""
echo "--- Sensitive tuoni tools denied in base mode ---"
_register_session "test-session-base" "base"
for tool in tuoni_credentials_list tuoni_hosts_list tuoni_agents_list; do
    result="$(_call_hook "test-session-base" "base" "mcp__tuoni-mcp__${tool}")"
    if _is_denied "$result"; then
        ok "base mode denies sensitive mcp__tuoni-mcp__${tool}"
    else
        fail "base mode should deny sensitive mcp__tuoni-mcp__${tool}"
    fi
done

# -----------------------------------------------------------------------
echo ""
echo "--- No policy file = no enforcement ---"
mv "$TEST_PROJECT/.claude/provenance-policy.yaml" "$TEST_PROJECT/.claude/provenance-policy.yaml.bak"
result="$(_call_hook "" "red-team" "mcp__tuoni-mcp__tuoni_command_prepare")"
if _is_allowed "$result"; then
    ok "no policy file = no enforcement"
else
    fail "no policy file should mean no enforcement"
fi
mv "$TEST_PROJECT/.claude/provenance-policy.yaml.bak" "$TEST_PROJECT/.claude/provenance-policy.yaml"

# -----------------------------------------------------------------------
echo ""
echo "--- All critical_modes allow critical tools ---"
for mode in red-team purple red-dev pentest ctf bounty; do
    _register_session "test-mode-$mode" "$mode"
    result="$(_call_hook "test-mode-$mode" "$mode" "mcp__tuoni-mcp__tuoni_agent_list")"
    if _is_allowed "$result"; then
        ok "$mode allows critical tools"
    else
        fail "$mode should allow critical tools"
    fi
done

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
