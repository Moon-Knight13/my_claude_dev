#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VALIDATOR="$SCRIPT_DIR/../validate-engagement.sh"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

PASS=0 FAIL=0
run_test() {
  local name="$1" file="$2" expect="$3"
  local rc=0
  output="$("$VALIDATOR" "$file" 2>&1)" || rc=$?
  if [[ "$rc" -eq "$expect" ]]; then
    echo "PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $name (expected exit $expect, got $rc)"
    echo "  output: $output"
    FAIL=$((FAIL + 1))
  fi
}

# Minimal valid engagement YAML
VALID="$TMPDIR/valid.yaml"
cat > "$VALID" << 'EOF'
metadata:
  id: test-001
  operator: tester
phase: recon
targets:
  - hostname: host-a
    approved: true
agents:
  - agent_id: a1
    payload_id: pl-001
cred_refs:
  - ref_id: cr-001
    tuoni_cred_id: tc-abc
findings: []
persistence:
  - target: host-a
    method: cron
lateral_moves:
  - from_host: host-a
    to_host: host-b
    cred_ref: cr-001
handoff: "Next steps here"
EOF

run_test "valid file passes" "$VALID" 0

# Missing required keys
MISSING="$TMPDIR/missing.yaml"
cat > "$MISSING" << 'EOF'
metadata:
  id: test-002
  operator: tester
phase: recon
EOF
run_test "missing keys fail" "$MISSING" 1

# Invalid phase
BAD_PHASE="$TMPDIR/bad-phase.yaml"
cat > "$BAD_PHASE" << 'EOF'
metadata:
  id: test-003
  operator: tester
phase: pwned
targets: []
agents: []
cred_refs: []
findings: []
persistence: []
lateral_moves: []
handoff: ""
EOF
run_test "invalid phase fails" "$BAD_PHASE" 1

# Duplicate payload_id
DUP_PID="$TMPDIR/dup-pid.yaml"
cat > "$DUP_PID" << 'EOF'
metadata:
  id: test-004
  operator: tester
phase: lateral
targets: []
agents:
  - agent_id: a1
    payload_id: pl-dup
  - agent_id: a2
    payload_id: pl-dup
cred_refs: []
findings: []
persistence: []
lateral_moves: []
handoff: ""
EOF
run_test "duplicate payload_id fails" "$DUP_PID" 1

# Plaintext cred field (SECURITY)
PLAINTEXT="$TMPDIR/plaintext.yaml"
cat > "$PLAINTEXT" << 'EOF'
metadata:
  id: test-005
  operator: tester
phase: recon
targets: []
agents: []
cred_refs:
  - ref_id: cr-bad
    tuoni_cred_id: tc-xyz
    password: "hunter2"
findings: []
persistence: []
lateral_moves: []
handoff: ""
EOF
run_test "plaintext cred field fails" "$PLAINTEXT" 1

# Missing tuoni_cred_id
NO_TCID="$TMPDIR/no-tcid.yaml"
cat > "$NO_TCID" << 'EOF'
metadata:
  id: test-006
  operator: tester
phase: recon
targets: []
agents: []
cred_refs:
  - ref_id: cr-noid
    type: ldap
findings: []
persistence: []
lateral_moves: []
handoff: ""
EOF
run_test "missing tuoni_cred_id fails" "$NO_TCID" 1

# Broken YAML
BROKEN="$TMPDIR/broken.yaml"
printf '{\ninvalid: [yaml\n' > "$BROKEN"
run_test "broken YAML fails" "$BROKEN" 1

# Empty file
EMPTY="$TMPDIR/empty.yaml"
touch "$EMPTY"
run_test "empty file fails" "$EMPTY" 1

echo ""
echo "Results: $PASS passed, $FAIL failed"
exit "$FAIL"
