#!/usr/bin/env bash
# shellcheck disable=SC2015
# test-discovery-skill.sh — validates the discovery skill file structure,
# required OPSEC references, platform sections, and integration points.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

fails=0
ok()  { echo "  OK  $1"; }
bad() { echo " FAIL $1: $2"; fails=$((fails + 1)); }

SKILL="$REPO_ROOT/.claude/skills/red-team/discovery.md"

# ── 1. Skill file exists ────────────────────────────────────────────────────
[[ -f "$SKILL" ]] \
  && ok "skill file exists" \
  || bad "skill file exists" "$SKILL not found"

# bail early if no file
[[ -f "$SKILL" ]] || { echo "ABORT: skill file missing"; exit 1; }


# ── 2. Valid frontmatter ────────────────────────────────────────────────────
head -1 "$SKILL" | grep -q '^---' \
  && ok "frontmatter opening delimiter" \
  || bad "frontmatter opening delimiter" "first line is not ---"

grep -q '^name: discovery' "$SKILL" \
  && ok "frontmatter name field" \
  || bad "frontmatter name field" "missing name: discovery"

grep -q '^description:' "$SKILL" \
  && ok "frontmatter description field" \
  || bad "frontmatter description field" "missing description:"

# ── 3. OPSEC references ────────────────────────────────────────────────────
grep -q 'RT-TGT-001' "$SKILL" \
  && ok "references RT-TGT-001 (scope discipline)" \
  || bad "references RT-TGT-001" "RT-TGT-001 not mentioned"

grep -q 'RT-TGT-002' "$SKILL" \
  && ok "references RT-TGT-002 (no tools on target)" \
  || bad "references RT-TGT-002" "RT-TGT-002 not mentioned"

# ── 4. Platform sections ───────────────────────────────────────────────────
grep -q 'Linux Discovery' "$SKILL" \
  && ok "has Linux Discovery section" \
  || bad "has Linux Discovery section" "section not found"

grep -q 'Windows Discovery' "$SKILL" \
  && ok "has Windows Discovery section" \
  || bad "has Windows Discovery section" "section not found"

grep -q 'Network Device' "$SKILL" \
  && ok "has Network Device section" \
  || bad "has Network Device section" "section not found"

# ── 5. Engagement YAML integration ────────────────────────────────────────
grep -qi 'engagement.yaml\|engagement YAML' "$SKILL" \
  && ok "mentions engagement YAML update" \
  || bad "mentions engagement YAML update" "no engagement YAML reference"

# ── 6. Structured output sections ──────────────────────────────────────────
for section in "Host Profile" "Network Position" "Users and Access" \
               "Services and Processes" "Attack Surface" "Recommended Next Steps"; do
  grep -q "$section" "$SKILL" \
    && ok "output section: $section" \
    || bad "output section: $section" "section not found in output format"
done

# ── 7. Skill integration references ───────────────────────────────────────
grep -q 'cred-harvest' "$SKILL" \
  && ok "references cred-harvest integration" \
  || bad "references cred-harvest integration" "cred-harvest not mentioned"

grep -qi 'lateral.move\|lateral-move\|lateral movement' "$SKILL" \
  && ok "references lateral movement integration" \
  || bad "references lateral movement integration" "lateral move/movement not mentioned"

# ── Summary ────────────────────────────────────────────────────────────────
echo
if [[ $fails -eq 0 ]]; then
  echo "ALL PASSED"
else
  echo "FAILURES: $fails"
fi
exit "$fails"
