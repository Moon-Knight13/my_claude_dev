#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$PROJECT_DIR/.claude/hooks/session-end-sync.sh"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

PASS=0 FAIL=0
run_test() {
  local name="$1" expect="$2"
  shift 2
  local rc=0
  output=$("$@" 2>&1) || rc=$?
  if [[ "$rc" -eq "$expect" ]]; then
    echo "PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $name (expected exit $expect, got $rc)"
    echo "  output: $output"
    FAIL=$((FAIL + 1))
  fi
}

# Test 1: hook is executable
if [[ -x "$HOOK" ]]; then
  echo "PASS: hook is executable"
  PASS=$((PASS + 1))
else
  echo "FAIL: hook is not executable"
  FAIL=$((FAIL + 1))
fi

# Test 2: hook registered in settings.json
if grep -q 'session-end-sync.sh' "$PROJECT_DIR/.claude/settings.json" 2>/dev/null; then
  echo "PASS: hook registered in settings.json Stop event"
  PASS=$((PASS + 1))
else
  echo "FAIL: hook not found in settings.json"
  FAIL=$((FAIL + 1))
fi

# Test 3: no engagement — exits cleanly with no output
FAKE_DIR="$TMPDIR/no-eng"
mkdir -p "$FAKE_DIR/engagements"
run_test "no engagement exits 0 silently" 0 \
  env CLAUDE_PROJECT_DIR="$FAKE_DIR" "$HOOK"

# Test 4: with engagement YAML — produces sync reminder
FAKE_DIR2="$TMPDIR/with-eng"
mkdir -p "$FAKE_DIR2/engagements"
cat > "$FAKE_DIR2/engagements/test-001.yaml" << 'EOF'
metadata:
  id: test-001
  operator: tester
phase: discovery
targets:
  - hostname: target-a
    approved: true
  - hostname: target-b
    approved: true
agents: []
cred_refs:
  - ref_id: cr-001
    tuoni_cred_id: tc-abc
findings:
  - id: f1
    target: target-a
persistence: []
lateral_moves: []
handoff: ""
EOF

output=$(env CLAUDE_PROJECT_DIR="$FAKE_DIR2" "$HOOK" 2>&1) || true
if echo "$output" | grep -q "SESSION-END SYNC REQUIRED"; then
  echo "PASS: sync reminder produced for active engagement"
  PASS=$((PASS + 1))
else
  echo "FAIL: no sync reminder for active engagement"
  echo "  output: $output"
  FAIL=$((FAIL + 1))
fi

# Test 5: output mentions both Obsidian and memory
if echo "$output" | grep -q "Obsidian" && echo "$output" | grep -q "memory"; then
  echo "PASS: output mentions both Obsidian and Claude memory sync"
  PASS=$((PASS + 1))
else
  echo "FAIL: output missing Obsidian or memory mention"
  echo "  output: $output"
  FAIL=$((FAIL + 1))
fi

# Test 6: output includes engagement state fields
if echo "$output" | grep -q "phase=" && echo "$output" | grep -q "targets="; then
  echo "PASS: output includes engagement state summary"
  PASS=$((PASS + 1))
else
  echo "FAIL: output missing state summary fields"
  echo "  output: $output"
  FAIL=$((FAIL + 1))
fi

# Test 7: black-box type engagement handled
FAKE_DIR3="$TMPDIR/bb-eng"
mkdir -p "$FAKE_DIR3/engagements"
cat > "$FAKE_DIR3/engagements/bb-001.yaml" << 'EOF'
metadata:
  id: bb-001
  operator: tester
phase: recon
type: black-box
targets: []
agents: []
cred_refs: []
findings: []
persistence: []
lateral_moves: []
handoff: ""
EOF

output3=$(env CLAUDE_PROJECT_DIR="$FAKE_DIR3" "$HOOK" 2>&1) || true
if echo "$output3" | grep -q "SESSION-END SYNC REQUIRED" && echo "$output3" | grep -q "type=black-box"; then
  echo "PASS: black-box engagement produces sync reminder with type"
  PASS=$((PASS + 1))
else
  echo "FAIL: black-box engagement sync output incorrect"
  echo "  output: $output3"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
exit "$FAIL"
