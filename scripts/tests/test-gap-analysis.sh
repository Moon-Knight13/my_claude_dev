#!/usr/bin/env bash
# Validate gap analysis implementation (GLOSSARY, invocation flag, mini variants)
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# GLOSSARY.md
test -f GLOSSARY.md && pass "GLOSSARY.md exists" || fail "GLOSSARY.md exists"
grep -q 'GLOSSARY' CLAUDE.md && pass "CLAUDE.md references GLOSSARY" || fail "CLAUDE.md references GLOSSARY"
[ "$(grep -c "^|" GLOSSARY.md)" -gt 30 ] && pass "GLOSSARY has 30+ terms" || fail "GLOSSARY has 30+ terms"

# disable-model-invocation
grep -q 'disable-model-invocation: true' .claude/skills/engagement-orchestration/SKILL.md \
  && pass "engagement-orchestration has disable-model-invocation" \
  || fail "engagement-orchestration has disable-model-invocation"

# Mini variants exist
for skill in recon initial-access discovery; do
  test -f ".claude/skills/$skill/SKILL.mini.md" \
    && pass "$skill mini exists" || fail "$skill mini exists"
done

# Mini variants under size targets
[ "$(wc -l < .claude/skills/recon/SKILL.mini.md)" -lt 150 ] \
  && pass "recon mini <150 lines" || fail "recon mini <150 lines"
[ "$(wc -l < .claude/skills/initial-access/SKILL.mini.md)" -lt 150 ] \
  && pass "initial-access mini <150 lines" || fail "initial-access mini <150 lines"
[ "$(wc -l < .claude/skills/discovery/SKILL.mini.md)" -lt 100 ] \
  && pass "discovery mini <100 lines" || fail "discovery mini <100 lines"

# Safety rules preserved in minis
for skill in recon initial-access discovery; do
  mini_count=$(grep -c "ENFORCED" ".claude/skills/$skill/SKILL.mini.md" || true)
  [ "$mini_count" -gt 0 ] \
    && pass "$skill mini has ENFORCED rules (count=$mini_count)" \
    || fail "$skill mini has ENFORCED rules (count=$mini_count)"
done

# Mini variants have header comment
for skill in recon initial-access discovery; do
  grep -q 'Mini variant for subagent dispatch' ".claude/skills/$skill/SKILL.mini.md" \
    && pass "$skill mini has header comment" || fail "$skill mini has header comment"
done

echo "---"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
