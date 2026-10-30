#!/usr/bin/env bash
# test-cred-harvest-skill.sh — structure and content tests for the cred-harvest skill.
#
# Validates that the skill file exists, has correct frontmatter, covers the
# three-phase grounded approach, enforces OPSEC rules, and mandates
# reference-only credential storage.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok()   { echo "  OK  $1"; ((PASS++)) || true; }
bad()  { echo " FAIL $1"; ((FAIL++)) || true; }

SKILL="$ROOT/.claude/skills/red-team/cred-harvest.md"

# ============================================================================
echo "== file existence =="

if [[ -f "$SKILL" ]]; then
  ok "skill file exists"
else
  bad "skill file missing at .claude/skills/red-team/cred-harvest.md"
  echo "ABORT: cannot run remaining tests without the skill file"
  exit 1
fi

# ============================================================================
echo "== frontmatter =="

if head -5 "$SKILL" | grep -q '^---'; then
  ok "frontmatter delimiter present"
else
  bad "frontmatter delimiter missing"
fi

if grep -q '^name: cred-harvest' "$SKILL"; then
  ok "frontmatter name is cred-harvest"
else
  bad "frontmatter name missing or wrong"
fi

if grep -q '^description:' "$SKILL"; then
  ok "frontmatter description present"
else
  bad "frontmatter description missing"
fi

# ============================================================================
echo "== three-phase structure =="

if grep -qi 'GROUND' "$SKILL"; then
  ok "mentions GROUND / grounding phase"
else
  bad "missing GROUND / grounding phase"
fi

if grep -qi 'Phase 1.*GROUND\|GROUND.*Phase 1\|Phase 1 — GROUND' "$SKILL"; then
  ok "Phase 1 is the grounding phase"
else
  bad "Phase 1 grounding phase not clearly labeled"
fi

if grep -qi 'Phase 2.*HARVEST\|HARVEST.*Phase 2\|Phase 2 — HARVEST' "$SKILL"; then
  ok "Phase 2 is the harvest phase"
else
  bad "Phase 2 harvest phase not clearly labeled"
fi

if grep -qi 'Phase 3.*STORE\|STORE.*Phase 3\|Phase 3 — STORE' "$SKILL"; then
  ok "Phase 3 is the store phase"
else
  bad "Phase 3 store phase not clearly labeled"
fi

# ============================================================================
echo "== OPSEC rules =="

if grep -q 'RT-TGT-001' "$SKILL"; then
  ok "references RT-TGT-001 (target approval)"
else
  bad "missing RT-TGT-001 reference"
fi

if grep -q 'RT-TGT-002' "$SKILL"; then
  ok "references RT-TGT-002 (no tools on target)"
else
  bad "missing RT-TGT-002 reference"
fi

# ============================================================================
echo "== credential security =="

if grep -qi 'NEVER.*plaintext\|REFERENCES ONLY\|references only' "$SKILL"; then
  ok "mentions NEVER plaintext / references only"
else
  bad "missing NEVER plaintext / references only mandate"
fi

if grep -qi 'cred_ref' "$SKILL"; then
  ok "mentions cred_ref entries"
else
  bad "missing cred_ref entry format"
fi

# ============================================================================
echo "== credential spray safety =="

if grep -qi 'lockout policy\|lockout threshold' "$SKILL"; then
  ok "mentions lockout policy for spraying"
else
  bad "missing lockout policy mention for credential spraying"
fi

# ============================================================================
echo "== tuoni cred store =="

if grep -qi 'tuoni.*cred.*store\|tuoni credential store' "$SKILL"; then
  ok "mentions tuoni cred store"
else
  bad "missing tuoni cred store reference"
fi

# ============================================================================
echo "== platform coverage =="

if grep -qi 'Linux' "$SKILL"; then
  ok "covers Linux targets"
else
  bad "missing Linux target coverage"
fi

if grep -qi 'Windows' "$SKILL"; then
  ok "covers Windows targets"
else
  bad "missing Windows target coverage"
fi

if grep -qi 'Network Device\|network device\|running-config\|startup-config' "$SKILL"; then
  ok "covers network device targets"
else
  bad "missing network device target coverage"
fi

# ============================================================================
echo "== grounding sources =="

if grep -qi 'Providentia' "$SKILL"; then
  ok "grounding queries Providentia"
else
  bad "missing Providentia in grounding phase"
fi

if grep -qi 'vulns-docs' "$SKILL"; then
  ok "grounding queries vulns-docs"
else
  bad "missing vulns-docs in grounding phase"
fi

if grep -qi 'repo-docs' "$SKILL"; then
  ok "grounding queries repo-docs"
else
  bad "missing repo-docs in grounding phase"
fi

if grep -qi 'HackTricks' "$SKILL"; then
  ok "grounding queries HackTricks"
else
  bad "missing HackTricks in grounding phase"
fi

# ============================================================================
echo
echo "== summary =="
echo "  $PASS passed, $FAIL failed"
(( FAIL == 0 ))
