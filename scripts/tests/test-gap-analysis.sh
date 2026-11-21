#!/usr/bin/env bash
# Validate gap analysis implementation (GLOSSARY, invocation flag, mini variants)
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

PASS=0
FAIL=0

check() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $label"
    FAIL=$((FAIL + 1))
  fi
}

check_expr() {
  local label="$1"
  shift
  if [ "$@" ]; then
    echo "PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $label"
    FAIL=$((FAIL + 1))
  fi
}

# GLOSSARY.md
check "GLOSSARY.md exists" test -f GLOSSARY.md
check "CLAUDE.md references GLOSSARY" grep -q 'GLOSSARY' CLAUDE.md
check_expr "GLOSSARY has 30+ terms" "$(grep -c "^|" GLOSSARY.md)" -gt 30

# disable-model-invocation
check "engagement-orchestration has disable-model-invocation" \
  grep -q 'disable-model-invocation: true' .claude/skills/engagement-orchestration/SKILL.md

# Mini variants exist
for skill in recon initial-access discovery; do
  check "$skill mini exists" test -f ".claude/skills/$skill/SKILL.mini.md"
done

# Mini variants under size targets
check_expr "recon mini <150 lines" "$(wc -l < .claude/skills/recon/SKILL.mini.md)" -lt 150
check_expr "initial-access mini <150 lines" "$(wc -l < .claude/skills/initial-access/SKILL.mini.md)" -lt 150
check_expr "discovery mini <100 lines" "$(wc -l < .claude/skills/discovery/SKILL.mini.md)" -lt 100

# Safety rules preserved in minis
for skill in recon initial-access discovery; do
  mini_count=$(grep -c "ENFORCED" ".claude/skills/$skill/SKILL.mini.md" || true)
  check_expr "$skill mini has ENFORCED rules (count=$mini_count)" "$mini_count" -gt 0
done

# Mini variants have header comment
for skill in recon initial-access discovery; do
  check "$skill mini has header comment" \
    grep -q 'Mini variant for subagent dispatch' ".claude/skills/$skill/SKILL.mini.md"
done

echo "---"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
