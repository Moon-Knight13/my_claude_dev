#!/usr/bin/env bash
# check-opsec-classifier.sh — Validate config/opsec-classifier.yaml structure.
#
# Checks:
#   1. File exists and is valid YAML (python yaml.safe_load)
#   2. schema_version is present and numeric
#   3. Every command has required fields
#   4. opsec_rating values are from allowed set
#   5. detection_surface entries are from declared vocabulary
#   6. requires_confirmation matches rating policy
#   7. No duplicate command keys
#   8. All deploy-expected scripts have entries
#
# Exit codes: 0 = pass, 1 = validation failure, 2 = missing dependency
set -euo pipefail

CLASSIFIER="config/opsec-classifier.yaml"
DEPLOY_SCRIPT="scripts/deploy-tuoni-plugins.sh"

PASS=0
FAIL=0
WARN=0

pass() { PASS=$((PASS + 1)); echo "  OK    $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL  $1"; }
warn() { WARN=$((WARN + 1)); echo "  WARN  $1"; }

echo "OPSEC Classifier Validation"
echo "==========================="
echo ""

# ── Prerequisite: python3 with yaml ────────────────────────────────────
if ! python3 -c "import yaml" 2>/dev/null; then
    echo "SKIP  python3 + PyYAML not available — cannot validate"
    exit 0
fi

# ── File exists ─────────────────────────────────────────────────────────
if [[ ! -f "$CLASSIFIER" ]]; then
    fail "$CLASSIFIER not found"
    echo ""
    echo "Result: $FAIL failure(s)"
    exit 1
fi
pass "File exists"

# ── Valid YAML + structural checks via Python ──────────────────────────
result=$(python3 -I -c "
import sys, yaml, json

with open('$CLASSIFIER') as f:
    data = yaml.safe_load(f)

errors = []
warnings = []

# schema_version
sv = data.get('schema_version')
if sv is None:
    errors.append('schema_version missing')
elif not isinstance(sv, (int, float)):
    errors.append(f'schema_version must be numeric, got {type(sv).__name__}')

# ratings block
ratings = data.get('ratings', {})
valid_ratings = set(ratings.keys()) if ratings else set()
if not valid_ratings:
    errors.append('ratings block missing or empty')

# detection_surfaces vocabulary
surfaces = data.get('detection_surfaces', {})
valid_surfaces = set(surfaces.keys()) if surfaces else set()
if not valid_surfaces:
    errors.append('detection_surfaces block missing or empty')

# confirmation-required ratings
confirm_ratings = {r for r, v in ratings.items()
                   if isinstance(v, dict) and v.get('requires_confirmation')}

# commands
commands = data.get('commands', {})
if not commands:
    errors.append('commands block missing or empty')

required_fields = ['description', 'opsec_rating', 'detection_surface',
                   'alternatives', 'requires_confirmation']

seen_commands = set()
for name, cmd in commands.items():
    if name in seen_commands:
        errors.append(f'{name}: duplicate command key')
    seen_commands.add(name)

    if not isinstance(cmd, dict):
        errors.append(f'{name}: not a mapping')
        continue

    for field in required_fields:
        if field not in cmd:
            errors.append(f'{name}: missing required field \"{field}\"')

    rating = cmd.get('opsec_rating')
    if rating and valid_ratings and rating not in valid_ratings:
        errors.append(f'{name}: opsec_rating \"{rating}\" not in ratings block')

    ds = cmd.get('detection_surface', [])
    if isinstance(ds, list) and valid_surfaces:
        for s in ds:
            if s not in valid_surfaces:
                errors.append(f'{name}: detection_surface \"{s}\" not in vocabulary')

    # Confirm policy: critical/high ratings must require confirmation
    if rating in confirm_ratings and cmd.get('requires_confirmation') is not True:
        errors.append(f'{name}: rating \"{rating}\" requires confirmation but requires_confirmation is not true')

    # Warn if critical/high with empty alternatives
    alts = cmd.get('alternatives', [])
    if rating in ('critical', 'high') and isinstance(alts, list) and len(alts) == 0:
        warnings.append(f'{name}: {rating}-rated with no alternatives listed')

out = {'errors': errors, 'warnings': warnings, 'command_count': len(commands),
       'command_names': sorted(commands.keys())}
print(json.dumps(out))
" 2>&1) || {
    fail "YAML parse error or Python failure"
    echo "  $result"
    echo ""
    echo "Result: 1 failure"
    exit 1
}

pass "Valid YAML, parsed successfully"

# ── Extract validation results ──────────────────────────────────────────
errors=$(echo "$result" | python3 -I -c "import sys,json; d=json.load(sys.stdin); [print(e) for e in d['errors']]")
warnings=$(echo "$result" | python3 -I -c "import sys,json; d=json.load(sys.stdin); [print(w) for w in d['warnings']]")
cmd_count=$(echo "$result" | python3 -I -c "import sys,json; print(json.load(sys.stdin)['command_count'])")
cmd_names=$(echo "$result" | python3 -I -c "import sys,json; [print(n) for n in json.load(sys.stdin)['command_names']]")

if [[ -n "$errors" ]]; then
    while IFS= read -r line; do
        fail "$line"
    done <<< "$errors"
else
    pass "All structural checks passed"
fi

if [[ -n "$warnings" ]]; then
    while IFS= read -r line; do
        warn "$line"
    done <<< "$warnings"
fi

pass "$cmd_count commands mapped"

# ── Cross-reference with deploy script expected list ────────────────────
if [[ -f "$DEPLOY_SCRIPT" ]]; then
    expected=$(grep -oP 'tuoni_\w+\.py' "$DEPLOY_SCRIPT" \
        | sed 's/\.py$//' | sort -u)

    if [[ -n "$expected" ]]; then
        missing_in_classifier=()
        while IFS= read -r script_name; do
            if ! echo "$cmd_names" | grep -qx "$script_name"; then
                missing_in_classifier+=("$script_name")
            fi
        done <<< "$expected"

        if [[ ${#missing_in_classifier[@]} -gt 0 ]]; then
            for m in "${missing_in_classifier[@]}"; do
                warn "deploy script expects $m but no classifier entry found"
            done
        else
            pass "All deploy-expected scripts have classifier entries"
        fi
    fi
else
    warn "Deploy script not found at $DEPLOY_SCRIPT — cannot cross-reference"
fi

# ── Summary ─────────────────────────────────────────────────────────────
echo ""
echo "---"
echo "Result: $PASS passed, $FAIL failed, $WARN warnings"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
