#!/usr/bin/env bash
# test-deploy-hq.sh — test deploy-hq.sh deploys to temp HOME correctly.
# Runs all checks inside a subshell with overridden HOME to avoid
# interaction between set -euo pipefail, trap, and HOME reassignment.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEPLOY="$REPO_DIR/scripts/deploy-hq.sh"

[[ -f "$DEPLOY" ]] || { echo "FAIL: deploy-hq.sh not found"; exit 1; }

echo "=== deploy-hq.sh tests ==="

# All tests run in a child bash with isolated HOME
bash -c '
set -euo pipefail
PASS=0; FAIL=0
ok()   { echo "  PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

DEPLOY="$1"
TMP="$(mktemp -d)"
trap "rm -rf \"$TMP\"" EXIT
export HOME="$TMP"

# Test 1: dry-run does not create dirs
bash "$DEPLOY" --dry-run >/dev/null 2>&1 || true
[[ ! -d "$TMP/.claude/hooks" ]] && ok "dry-run does not create hooks dir" || fail "dry-run created hooks dir"

# Test 2: real deploy creates hooks dir
bash "$DEPLOY" >/dev/null 2>&1
[[ -d "$TMP/.claude/hooks" ]] && ok "hooks dir created" || fail "hooks dir missing"

# Test 3: hooks dir permissions
perms="$(stat -c %a "$TMP/.claude/hooks" 2>/dev/null || echo "unknown")"
[[ "$perms" == "700" ]] && ok "hooks dir 700" || fail "hooks dir perms: $perms"

# Test 4: all hooks present and executable
for hook in master-dispatch-guard.sh pretooluse-ctp.sh tuoni-secret-guard.sh dispatch-wakeup-enforcer.sh; do
    [[ -x "$TMP/.claude/hooks/$hook" ]] && ok "$hook deployed" || fail "$hook missing"
done

# Test 5: settings.json valid JSON
python3 -I -c "import json; json.load(open(\"$TMP/.claude/settings.json\"))" 2>/dev/null \
    && ok "settings.json valid JSON" || fail "settings.json invalid"

# Test 6: settings.json has hooks wiring
python3 -I -c "
import json
with open(\"$TMP/.claude/settings.json\") as f:
    s = json.load(f)
assert \"hooks\" in s
assert \"PreToolUse\" in s[\"hooks\"]
assert \"PostToolUse\" in s[\"hooks\"]
print(\"ok\")
" 2>/dev/null | grep -q "ok" && ok "settings.json has hooks wiring" || fail "settings.json missing hooks"

# Test 7: no secrets in hooks
count=$(grep -rl "TOKEN\|SECRET\|PASSWORD" "$TMP/.claude/hooks/" 2>/dev/null | wc -l || true)
[[ "$count" -eq 0 ]] && ok "no secrets in hooks" || fail "secrets found"

# Test 8: no hardcoded paths
count=$(grep -rl "/home/chris\|/Users/" "$TMP/.claude/hooks/" 2>/dev/null | wc -l || true)
[[ "$count" -eq 0 ]] && ok "no hardcoded paths" || fail "hardcoded paths found"

# Test 9: verify-only reports correct state
result="$(bash "$DEPLOY" --verify-only 2>&1)" || true
echo "$result" | grep -qi "ok\|pass\|verified\|match" && ok "verify-only healthy" || fail "verify-only unhealthy: $result"

# Test 10: deploy preserves existing settings keys
python3 -I -c "
import json
with open(\"$TMP/.claude/settings.json\") as f:
    s = json.load(f)
s[\"customKey\"] = \"preserved\"
with open(\"$TMP/.claude/settings.json\", \"w\") as f:
    json.dump(s, f, indent=2)
"
bash "$DEPLOY" >/dev/null 2>&1
python3 -I -c "
import json
with open(\"$TMP/.claude/settings.json\") as f:
    s = json.load(f)
assert s.get(\"customKey\") == \"preserved\"
print(\"ok\")
" 2>/dev/null | grep -q "ok" && ok "preserves existing settings" || fail "overwrites settings"

# Test 11: kill switch in output
result="$(bash "$DEPLOY" 2>&1)"
echo "$result" | grep -qi "kill switch" && ok "kill switch printed" || fail "no kill switch"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
' -- "$DEPLOY"
