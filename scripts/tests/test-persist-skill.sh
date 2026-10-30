#!/usr/bin/env bash
# Test: persist-swarm skill structure and content
set -euo pipefail

SKILL=".claude/skills/red-team/persist-swarm.md"
FAIL=0

pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=1; }

echo "=== persist-swarm skill tests ==="

# 1. File exists and is non-empty
if [[ -s "$SKILL" ]]; then
  pass "Skill file exists and is non-empty"
else
  fail "Skill file missing or empty: $SKILL"
fi

# 2. Frontmatter has name and description
if grep -q '^name:' "$SKILL" && grep -q '^description:' "$SKILL"; then
  pass "Frontmatter contains name and description"
else
  fail "Frontmatter missing name or description"
fi

# 3. OPSEC rules referenced
for rule in RT-SIG-002 RT-SIG-003 RT-SIG-004 RT-TGT-002; do
  if grep -q "$rule" "$SKILL"; then
    pass "References $rule"
  else
    fail "Missing reference to $rule"
  fi
done

# 4. Both OS platforms covered
for os in "Linux targets" "Windows targets"; do
  if grep -q "$os" "$SKILL"; then
    pass "Covers $os"
  else
    fail "Missing section for $os"
  fi
done

# 5. Both beacon types mentioned
for btype in operational sleeper; do
  if grep -qi "$btype" "$SKILL"; then
    pass "Mentions $btype beacon type"
  else
    fail "Missing $btype beacon type"
  fi
done

# 6. Persist-on-lateral rule
if grep -q "persist-on-lateral" "$SKILL"; then
  pass "Mentions persist-on-lateral rule"
else
  fail "Missing persist-on-lateral rule reference"
fi

echo ""
if [[ $FAIL -eq 0 ]]; then
  echo "All tests passed."
else
  echo "Some tests FAILED."
  exit 1
fi
