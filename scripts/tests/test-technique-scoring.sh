#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCORER="$SCRIPT_DIR/../technique-scoring.py"

if ! python3 -c "import yaml" 2>/dev/null; then
  echo "SKIP: PyYAML not found — technique scoring tests require it"
  exit 0
fi

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

ENGDIR="$TMPDIR/engagements"
ARCHDIR="$ENGDIR/archive"
mkdir -p "$ARCHDIR"

CONFIG="$TMPDIR/config.yaml"
cat > "$CONFIG" << 'EOF'
weights:
  empirical: 0.60
  epss: 0.25
  stealth: 0.15
partial_weight: 0.5
recency:
  enabled: false
deprioritize:
  min_engagements: 3
  penalty: -0.50
confidence_threshold: 3
accuracy_gap:
  enabled: true
  min_attempts: 2
EOF

PASS=0 FAIL=0
run_test() {
  local name="$1" expect="$2"
  shift 2
  local rc=0
  output="$("$@" 2>&1)" || rc=$?
  if [[ "$rc" -eq "$expect" ]]; then
    echo "PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $name (expected exit $expect, got $rc)"
    echo "  output: $output"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local name="$1" needle="$2"
  shift 2
  local rc=0
  output="$("$@" 2>&1)" || rc=$?
  if echo "$output" | grep -qF "$needle"; then
    echo "PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $name (expected output to contain '$needle')"
    echo "  output: $output"
    FAIL=$((FAIL + 1))
  fi
}

assert_json_field() {
  local name="$1" field="$2" expected="$3"
  shift 3
  local rc=0
  output="$("$@" 2>&1)" || rc=$?
  actual="$(echo "$output" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d${field})" 2>/dev/null || echo "__PARSE_ERROR__")"
  if [[ "$actual" == "$expected" ]]; then
    echo "PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $name (field $field: expected '$expected', got '$actual')"
    FAIL=$((FAIL + 1))
  fi
}

# --- Test 1: Empty engagements dir ---
EMPTYDIR="$TMPDIR/empty-eng"
mkdir -p "$EMPTYDIR"
run_test "empty engagements exits 0" 0 \
  python3 "$SCORER" --config "$CONFIG" --engagements "$EMPTYDIR"

# --- Test 2: Single engagement with mixed results ---
cat > "$ENGDIR/test-eng1.yaml" << 'EOF'
engagement_id: eng-001
start_date: "2026-10-01"
status: active
targets:
  - hostname: target-a
    approved: true
techniques_tried:
  - technique_id: T1003.001
    technique_name: "LSASS Memory Dump"
    target: target-a
    phase: cred-harvest
    result: success
    timestamp: "2026-10-15T10:00:00Z"
  - technique_id: T1003.001
    technique_name: "LSASS Memory Dump"
    target: target-b
    phase: cred-harvest
    result: failed
    timestamp: "2026-10-16T10:00:00Z"
  - technique_id: T1558.003
    technique_name: "Kerberoasting"
    target: target-a
    phase: cred-harvest
    result: success
    timestamp: "2026-10-15T11:00:00Z"
  - technique_id: T1021.006
    technique_name: "WinRM"
    target: target-b
    phase: lateral
    result: partial
    timestamp: "2026-10-16T12:00:00Z"
findings: []
EOF

assert_contains "single engagement produces ranked output" "T1558.003" \
  python3 "$SCORER" --config "$CONFIG" --engagements "$ENGDIR" --format table

# --- Test 3: Query single technique ---
assert_json_field "query T1003.001 returns correct attempts" \
  "['attempts']" "2" \
  python3 "$SCORER" --config "$CONFIG" --engagements "$ENGDIR" --query T1003.001 --format json

# --- Test 4: Kerberoasting 100% success = score 0.60 ---
assert_json_field "kerberoasting score is 0.6" \
  "['composite_score']" "0.6" \
  python3 "$SCORER" --config "$CONFIG" --engagements "$ENGDIR" --query T1558.003 --format json

# --- Test 5: Partial counts as 0.5 ---
assert_json_field "WinRM partial counts correctly" \
  "['empirical_rate']" "0.5" \
  python3 "$SCORER" --config "$CONFIG" --engagements "$ENGDIR" --query T1021.006 --format json

# --- Test 6: Low confidence flag ---
assert_json_field "WinRM flagged low_confidence" \
  "['flags'][0]" "low_confidence" \
  python3 "$SCORER" --config "$CONFIG" --engagements "$ENGDIR" --query T1021.006 --format json

# --- Test 7: Auto-deprioritization across 3 engagements ---
cat > "$ARCHDIR/arch-eng2.yaml" << 'EOF'
engagement_id: eng-002
start_date: "2026-09-01"
status: archived
targets: []
techniques_tried:
  - technique_id: T9999
    technique_name: "Never Works"
    target: target-x
    phase: initial-access
    result: failed
    timestamp: "2026-09-01T10:00:00Z"
findings: []
EOF

cat > "$ARCHDIR/arch-eng3.yaml" << 'EOF'
engagement_id: eng-003
start_date: "2026-08-01"
status: archived
targets: []
techniques_tried:
  - technique_id: T9999
    technique_name: "Never Works"
    target: target-y
    phase: initial-access
    result: failed
    timestamp: "2026-08-01T10:00:00Z"
findings: []
EOF

cat > "$ARCHDIR/arch-eng4.yaml" << 'EOF'
engagement_id: eng-004
start_date: "2026-07-01"
status: archived
targets: []
techniques_tried:
  - technique_id: T9999
    technique_name: "Never Works"
    target: target-z
    phase: initial-access
    result: failed
    timestamp: "2026-07-01T10:00:00Z"
findings: []
EOF

assert_contains "T9999 auto-deprioritized after 3 engagement failures" \
  "auto_deprioritized" \
  python3 "$SCORER" --config "$CONFIG" --engagements "$ENGDIR" --query T9999 --format json

# --- Test 8: JSON output is valid JSON ---
run_test "JSON output parses" 0 \
  bash -c "python3 '$SCORER' --config '$CONFIG' --engagements '$ENGDIR' --format json | python3 -m json.tool > /dev/null"

# --- Test 9: --top limits output ---
assert_json_field "top 2 returns 2 entries" \
  "" "2" \
  bash -c "python3 '$SCORER' --config '$CONFIG' --engagements '$ENGDIR' --format json --top 2 | python3 -c 'import sys,json; print(len(json.load(sys.stdin)))'"

# --- Test 10: Providentia accuracy gap detection ---
PROV_CACHE="$TMPDIR/prov-vulns.yaml"
cat > "$PROV_CACHE" << 'EOF'
- technique_id: T9999
  description: "Providentia says this should work"
EOF

assert_contains "Providentia gap flagged for T9999" \
  "providentia_gap" \
  python3 "$SCORER" --config "$CONFIG" --engagements "$ENGDIR" \
    --gaps --providentia-cache "$PROV_CACHE" --query T9999 --format json

# --- Test 11: Nonexistent technique query ---
run_test "query nonexistent technique exits 1" 1 \
  python3 "$SCORER" --config "$CONFIG" --engagements "$ENGDIR" --query T0000

echo ""
echo "Results: $PASS passed, $FAIL failed"
exit "$FAIL"
