#!/usr/bin/env bash
# test-opsec-classifier.sh — Tests for OPSEC classifier schema and validation.
#
# Tests the classifier YAML, the validation script, and Python helper.
# Uses only bash + python3 (PyYAML). No external test framework.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLASSIFIER="$PROJECT_DIR/config/opsec-classifier.yaml"
VALIDATOR="$PROJECT_DIR/scripts/ci/check-opsec-classifier.sh"
HELPER="$PROJECT_DIR/scripts/opsec-classify.sh"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  PASS  $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL  $1"; }

echo "OPSEC Classifier Tests"
echo "======================"
echo ""

# ── Prerequisite ────────────────────────────────────────────────────────
if ! python3 -c "import yaml" 2>/dev/null; then
    echo "SKIP  python3 + PyYAML not available"
    exit 0
fi

# ── Test 1: Classifier file exists ──────────────────────────────────────
echo "--- File structure ---"
if [[ -f "$CLASSIFIER" ]]; then
    pass "config/opsec-classifier.yaml exists"
else
    fail "config/opsec-classifier.yaml missing"
fi

# ── Test 2: Validator script exists and is executable ───────────────────
if [[ -f "$VALIDATOR" ]]; then
    pass "check-opsec-classifier.sh exists"
else
    fail "check-opsec-classifier.sh missing"
fi

# ── Test 3: Helper script exists and is executable ──────────────────────
if [[ -f "$HELPER" ]]; then
    pass "opsec-classify.sh exists"
else
    fail "opsec-classify.sh missing"
fi

# ── Test 4: Validator passes on real file ───────────────────────────────
echo ""
echo "--- Validation ---"
cd "$PROJECT_DIR"
if bash "$VALIDATOR" >/dev/null 2>&1; then
    pass "Validator passes on config/opsec-classifier.yaml"
else
    fail "Validator rejects config/opsec-classifier.yaml"
fi

# ── Test 5: Schema version present ─────────────────────────────────────
echo ""
echo "--- Schema checks ---"
sv=$(python3 -I -c "
import yaml
with open('$CLASSIFIER') as f:
    d = yaml.safe_load(f)
print(d.get('schema_version', 'MISSING'))
")
if [[ "$sv" =~ ^[0-9]+$ ]]; then
    pass "schema_version is numeric ($sv)"
else
    fail "schema_version invalid: $sv"
fi

# ── Test 6: All 16 deploy-expected commands present ─────────────────────
expected_commands=(
    tuoni_ad_enum
    tuoni_agent_watcher
    tuoni_collect_intel
    tuoni_cred_dump
    tuoni_exfil_stage
    tuoni_get_system
    tuoni_host_id
    tuoni_ioc_cleanup
    tuoni_lateral_move
    tuoni_lateral_wmi
    tuoni_log_clear
    tuoni_net_recon
    tuoni_payload_gen
    tuoni_persist_swarm
    tuoni_route_hijack
    tuoni_vuln_assess
)

mapped_commands=$(python3 -I -c "
import yaml
with open('$CLASSIFIER') as f:
    d = yaml.safe_load(f)
for k in sorted(d.get('commands', {}).keys()):
    print(k)
")

for cmd in "${expected_commands[@]}"; do
    if echo "$mapped_commands" | grep -qx "$cmd"; then
        pass "$cmd mapped"
    else
        fail "$cmd MISSING from classifier"
    fi
done

# ── Test 7: Rating values are valid ────────────────────────────────────
echo ""
echo "--- Rating validation ---"
invalid_ratings=$(python3 -I -c "
import yaml
with open('$CLASSIFIER') as f:
    d = yaml.safe_load(f)
valid = set(d.get('ratings', {}).keys())
for name, cmd in d.get('commands', {}).items():
    r = cmd.get('opsec_rating', '')
    if r not in valid:
        print(f'{name}: {r}')
")
if [[ -z "$invalid_ratings" ]]; then
    pass "All ratings from valid set"
else
    while IFS= read -r line; do
        fail "Invalid rating: $line"
    done <<< "$invalid_ratings"
fi

# ── Test 8: Detection surfaces are from vocabulary ──────────────────────
invalid_surfaces=$(python3 -I -c "
import yaml
with open('$CLASSIFIER') as f:
    d = yaml.safe_load(f)
vocab = set(d.get('detection_surfaces', {}).keys())
for name, cmd in d.get('commands', {}).items():
    for s in cmd.get('detection_surface', []):
        if s not in vocab:
            print(f'{name}: {s}')
")
if [[ -z "$invalid_surfaces" ]]; then
    pass "All detection surfaces from vocabulary"
else
    while IFS= read -r line; do
        fail "Unknown surface: $line"
    done <<< "$invalid_surfaces"
fi

# ── Test 9: Confirmation policy enforced ────────────────────────────────
echo ""
echo "--- Policy checks ---"
policy_violations=$(python3 -I -c "
import yaml
with open('$CLASSIFIER') as f:
    d = yaml.safe_load(f)
ratings = d.get('ratings', {})
confirm_required = {r for r, v in ratings.items()
                    if isinstance(v, dict) and v.get('requires_confirmation')}
for name, cmd in d.get('commands', {}).items():
    r = cmd.get('opsec_rating')
    if r in confirm_required and cmd.get('requires_confirmation') is not True:
        print(f'{name}: {r} needs confirmation')
")
if [[ -z "$policy_violations" ]]; then
    pass "Confirmation policy consistent"
else
    while IFS= read -r line; do
        fail "Policy violation: $line"
    done <<< "$policy_violations"
fi

# ── Test 10: Critical/high commands have alternatives ───────────────────
no_alternatives=$(python3 -I -c "
import yaml
with open('$CLASSIFIER') as f:
    d = yaml.safe_load(f)
for name, cmd in d.get('commands', {}).items():
    r = cmd.get('opsec_rating', '')
    alts = cmd.get('alternatives', [])
    if r in ('critical', 'high') and len(alts) == 0:
        print(name)
")
if [[ -z "$no_alternatives" ]]; then
    pass "All critical/high commands have alternatives"
else
    while IFS= read -r line; do
        fail "$line: critical/high with no alternatives"
    done <<< "$no_alternatives"
fi

# ── Test 11: MITRE references present ───────────────────────────────────
echo ""
echo "--- MITRE coverage ---"
missing_mitre=$(python3 -I -c "
import yaml, re
with open('$CLASSIFIER') as f:
    d = yaml.safe_load(f)
for name, cmd in d.get('commands', {}).items():
    tactic = cmd.get('mitre_tactic', '')
    tech = cmd.get('mitre_technique', '')
    if not re.match(r'^TA\d{4}$', str(tactic)):
        print(f'{name}: bad/missing mitre_tactic ({tactic})')
    if not re.match(r'^T\d{4}', str(tech)):
        print(f'{name}: bad/missing mitre_technique ({tech})')
")
if [[ -z "$missing_mitre" ]]; then
    pass "All commands have valid MITRE tactic + technique IDs"
else
    while IFS= read -r line; do
        fail "$line"
    done <<< "$missing_mitre"
fi

# ── Test 12: Helper lookup works ────────────────────────────────────────
echo ""
echo "--- Helper script ---"
if [[ -f "$HELPER" ]]; then
    # Lookup known critical command (strip ANSI codes for matching)
    out=$(bash "$HELPER" tuoni_cred_dump 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g') || true
    if echo "$out" | grep -qi "critical"; then
        pass "Helper returns critical for tuoni_cred_dump"
    else
        fail "Helper did not return critical for tuoni_cred_dump"
    fi

    # Lookup known low command (strip ANSI codes for matching)
    out=$(bash "$HELPER" tuoni_host_id 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g') || true
    if echo "$out" | grep -qi "low"; then
        pass "Helper returns low for tuoni_host_id"
    else
        fail "Helper did not return low for tuoni_host_id"
    fi

    # Unknown command returns error/unknown
    out=$(bash "$HELPER" tuoni_nonexistent 2>&1) || true
    if echo "$out" | grep -qi "unknown\|not found\|error"; then
        pass "Helper rejects unknown command"
    else
        fail "Helper did not reject unknown command"
    fi

    # JSON output mode
    out=$(bash "$HELPER" --json tuoni_log_clear 2>/dev/null) || true
    if echo "$out" | python3 -I -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
        pass "Helper --json produces valid JSON"
    else
        fail "Helper --json output is not valid JSON"
    fi
else
    fail "Helper script missing — skipping helper tests"
fi

# ── Test 13: Validator rejects broken YAML ──────────────────────────────
echo ""
echo "--- Negative tests ---"
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

# Missing commands block
cat > "$tmpdir/bad1.yaml" << 'EOF'
schema_version: 1
ratings:
  critical:
    description: "test"
    requires_confirmation: true
detection_surfaces:
  process_name: "test"
EOF

(cd "$tmpdir" && mkdir -p config && cp bad1.yaml config/opsec-classifier.yaml)
if ! (cd "$tmpdir" && bash "$VALIDATOR") >/dev/null 2>&1; then
    pass "Validator rejects YAML with missing commands"
else
    fail "Validator accepted YAML with missing commands"
fi

# Invalid rating value
cat > "$tmpdir/bad2.yaml" << 'EOF'
schema_version: 1
ratings:
  critical:
    description: "test"
    requires_confirmation: true
  low:
    description: "test"
    requires_confirmation: false
detection_surfaces:
  process_name: "test"
commands:
  test_cmd:
    description: "test"
    opsec_rating: extreme
    detection_surface: [process_name]
    alternatives: []
    requires_confirmation: true
EOF

(cd "$tmpdir" && cp bad2.yaml config/opsec-classifier.yaml)
if ! (cd "$tmpdir" && bash "$VALIDATOR") >/dev/null 2>&1; then
    pass "Validator rejects invalid opsec_rating value"
else
    fail "Validator accepted invalid opsec_rating value"
fi

# ── Summary ─────────────────────────────────────────────────────────────
echo ""
echo "==========================="
echo "Result: $PASS passed, $FAIL failed"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
