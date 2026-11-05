#!/usr/bin/env bash
# test-mcp-secret-scoping.sh — verify per-MCP secret isolation in mcp-wrapper.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0; FAIL=0

ok()   { echo "  PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

# Create temp dir with .env and wrapper copies
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

cat > "$TMPDIR_TEST/.env" <<'DOTENV'
TUONI_USERNAME=test-tuoni-user
TUONI_PASSWORD=test-tuoni-pass
PROVIDENTIA_TOKEN=test-prov-token
GITLAB_TOKEN=test-gitlab-token
GITLAB_PROJECT=test-project
OUTLINE_API_KEY=test-outline-key
OUTLINE_TOKEN=test-outline-token
SPOKE_KALI_HOST=10.0.0.1
PROVIDENTIA_HOST=10.0.0.2
OUTLINE_HOST=10.0.0.3
RANGE_GIT_HOST=10.0.0.4
DOTENV

# Copy scripts structure so load-env.sh finds .env at ../../.env
mkdir -p "$TMPDIR_TEST/scripts/lib"
cp "$PROJECT_DIR/scripts/lib/load-env.sh" "$TMPDIR_TEST/scripts/lib/"
cp "$PROJECT_DIR/scripts/mcp-wrapper.sh" "$TMPDIR_TEST/scripts/"

# Helper: run wrapper with MCP_SERVER_NAME override, exec `env` to dump vars
_run_as_mcp() {
    local mcp_name="$1"
    (
        cd "$TMPDIR_TEST"
        # Clear secrets + loader guard from parent
        unset TUONI_USERNAME TUONI_PASSWORD PROVIDENTIA_TOKEN GITLAB_TOKEN \
              GITLAB_PROJECT OUTLINE_API_KEY OUTLINE_TOKEN _CLAUDE_ENV_LOADED \
              2>/dev/null || true
        MCP_SERVER_NAME="$mcp_name" bash scripts/mcp-wrapper.sh env 2>/dev/null
    )
}

echo "=== MCP Secret Scoping Tests ==="
echo ""

echo "--- tuoni-mcp gets only TUONI_* ---"
env_out="$(_run_as_mcp tuoni-mcp)"
if echo "$env_out" | grep -q "TUONI_USERNAME=test-tuoni-user"; then
    ok "tuoni-mcp sees TUONI_USERNAME"
else
    fail "tuoni-mcp should see TUONI_USERNAME"
fi
if echo "$env_out" | grep -q "TUONI_PASSWORD=test-tuoni-pass"; then
    ok "tuoni-mcp sees TUONI_PASSWORD"
else
    fail "tuoni-mcp should see TUONI_PASSWORD"
fi
if echo "$env_out" | grep -q "PROVIDENTIA_TOKEN=test-prov-token"; then
    fail "tuoni-mcp should NOT see PROVIDENTIA_TOKEN"
else
    ok "tuoni-mcp does not see PROVIDENTIA_TOKEN"
fi
if echo "$env_out" | grep -q "GITLAB_TOKEN=test-gitlab-token"; then
    fail "tuoni-mcp should NOT see GITLAB_TOKEN"
else
    ok "tuoni-mcp does not see GITLAB_TOKEN"
fi
if echo "$env_out" | grep -q "OUTLINE_API_KEY=test-outline-key"; then
    fail "tuoni-mcp should NOT see OUTLINE_API_KEY"
else
    ok "tuoni-mcp does not see OUTLINE_API_KEY"
fi

echo ""
echo "--- hacktricks-mcp gets zero secrets ---"
env_out="$(_run_as_mcp hacktricks-mcp)"
if echo "$env_out" | grep -q "TUONI_PASSWORD="; then
    fail "hacktricks-mcp should NOT see TUONI_PASSWORD"
else
    ok "hacktricks-mcp does not see TUONI_PASSWORD"
fi
if echo "$env_out" | grep -q "PROVIDENTIA_TOKEN="; then
    fail "hacktricks-mcp should NOT see PROVIDENTIA_TOKEN"
else
    ok "hacktricks-mcp does not see PROVIDENTIA_TOKEN"
fi
if echo "$env_out" | grep -q "GITLAB_TOKEN="; then
    fail "hacktricks-mcp should NOT see GITLAB_TOKEN"
else
    ok "hacktricks-mcp does not see GITLAB_TOKEN"
fi
if echo "$env_out" | grep -q "OUTLINE_API_KEY="; then
    fail "hacktricks-mcp should NOT see OUTLINE_API_KEY"
else
    ok "hacktricks-mcp does not see OUTLINE_API_KEY"
fi

echo ""
echo "--- range-intel gets only PROVIDENTIA_* + GITLAB_* ---"
env_out="$(_run_as_mcp range-intel)"
if echo "$env_out" | grep -q "PROVIDENTIA_TOKEN=test-prov-token"; then
    ok "range-intel sees PROVIDENTIA_TOKEN"
else
    fail "range-intel should see PROVIDENTIA_TOKEN"
fi
if echo "$env_out" | grep -q "GITLAB_TOKEN=test-gitlab-token"; then
    ok "range-intel sees GITLAB_TOKEN"
else
    fail "range-intel should see GITLAB_TOKEN"
fi
if echo "$env_out" | grep -q "TUONI_PASSWORD=test-tuoni-pass"; then
    fail "range-intel should NOT see TUONI_PASSWORD"
else
    ok "range-intel does not see TUONI_PASSWORD"
fi
if echo "$env_out" | grep -q "OUTLINE_API_KEY=test-outline-key"; then
    fail "range-intel should NOT see OUTLINE_API_KEY"
else
    ok "range-intel does not see OUTLINE_API_KEY"
fi

echo ""
echo "--- outline-readonly gets only OUTLINE_* ---"
env_out="$(_run_as_mcp outline-readonly)"
if echo "$env_out" | grep -q "OUTLINE_API_KEY=test-outline-key"; then
    ok "outline-readonly sees OUTLINE_API_KEY"
else
    fail "outline-readonly should see OUTLINE_API_KEY"
fi
if echo "$env_out" | grep -q "TUONI_PASSWORD=test-tuoni-pass"; then
    fail "outline-readonly should NOT see TUONI_PASSWORD"
else
    ok "outline-readonly does not see TUONI_PASSWORD"
fi
if echo "$env_out" | grep -q "PROVIDENTIA_TOKEN=test-prov-token"; then
    fail "outline-readonly should NOT see PROVIDENTIA_TOKEN"
else
    ok "outline-readonly does not see PROVIDENTIA_TOKEN"
fi

echo ""
echo "--- obsidian-mcp gets zero secrets ---"
env_out="$(_run_as_mcp obsidian-mcp)"
if echo "$env_out" | grep -qE "(TUONI_PASSWORD|PROVIDENTIA_TOKEN|GITLAB_TOKEN|OUTLINE_API_KEY)=test-"; then
    fail "obsidian-mcp should get zero secrets"
else
    ok "obsidian-mcp gets zero secrets"
fi

echo ""
echo "--- unknown MCP gets zero secrets (fail-closed) ---"
env_out="$(_run_as_mcp unknown)"
if echo "$env_out" | grep -qE "(TUONI_PASSWORD|PROVIDENTIA_TOKEN|GITLAB_TOKEN|OUTLINE_API_KEY)=test-"; then
    fail "unknown MCP should get zero secrets"
else
    ok "unknown MCP gets zero secrets (fail-closed)"
fi

echo ""
echo "--- auto-detection from args ---"
# Simulate real .mcp.json usage: mcp-wrapper.sh python3 -m tuoni_mcp
# Use env with a tuoni-identifying assignment so exec succeeds and detection fires
env_out="$(
    cd "$TMPDIR_TEST"
    unset TUONI_USERNAME TUONI_PASSWORD PROVIDENTIA_TOKEN GITLAB_TOKEN \
          GITLAB_PROJECT OUTLINE_API_KEY OUTLINE_TOKEN _CLAUDE_ENV_LOADED \
          MCP_SERVER_NAME 2>/dev/null || true
    bash scripts/mcp-wrapper.sh env _MCP_DETECT=tuoni_mcp 2>/dev/null
)"
if echo "$env_out" | grep -q "TUONI_USERNAME=test-tuoni-user"; then
    ok "auto-detect: tuoni_mcp in args routes tuoni secrets"
else
    fail "auto-detect: tuoni_mcp in args should route tuoni secrets"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
