#!/usr/bin/env bash
# test-recon-skill.sh — structural validation of the recon skill file.
#
# Verifies the skill markdown exists, has correct frontmatter, enforces
# RT-TGT-001, and references all required sources in priority order.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok()   { echo "  OK  $1"; ((PASS++)) || true; }
bad()  { echo " FAIL $1"; ((FAIL++)) || true; }

SKILL="$ROOT/.claude/skills/recon/recon.md"

# --- existence and size ---
echo "== recon skill file =="
if [[ -f "$SKILL" ]]; then ok "skill file exists"; else bad "skill file missing"; fi
if [[ -s "$SKILL" ]]; then ok "skill file is non-empty"; else bad "skill file is empty"; fi

# --- frontmatter ---
echo "== frontmatter =="
if head -5 "$SKILL" | grep -q '^name:'; then
  ok "frontmatter has name"
else
  bad "frontmatter missing name"
fi
if head -5 "$SKILL" | grep -q '^description:'; then
  ok "frontmatter has description"
else
  bad "frontmatter missing description"
fi

# --- OPSEC: RT-TGT-001 target approval ---
echo "== OPSEC enforcement =="
if grep -q 'RT-TGT-001' "$SKILL"; then
  ok "mentions RT-TGT-001 (target approval)"
else
  bad "missing RT-TGT-001 reference"
fi
if grep -q 'RT-TGT-002' "$SKILL"; then
  ok "mentions RT-TGT-002 (no tools on target)"
else
  bad "missing RT-TGT-002 reference"
fi

# --- source priority: all required sources present ---
echo "== source priority chain =="
sources=(
  "Providentia"
  "GitLab"
  "repo-docs"
  "vulns-docs"
  "Tuoni"
  "Obsidian"
  "HackTricks"
  "MITRE"
  "GTFOBins"
)
for src in "${sources[@]}"; do
  if grep -qi "$src" "$SKILL"; then
    ok "mentions source: $src"
  else
    bad "missing source: $src"
  fi
done

# --- source ordering: Providentia before HackTricks (priority enforced) ---
echo "== source ordering =="
prov_line=$(grep -n -i 'Providentia' "$SKILL" | head -1 | cut -d: -f1)
hack_line=$(grep -n -i 'HackTricks' "$SKILL" | head -1 | cut -d: -f1)
if [[ -n "$prov_line" && -n "$hack_line" && "$prov_line" -lt "$hack_line" ]]; then
  ok "Providentia appears before HackTricks (correct priority)"
else
  bad "source priority order wrong: Providentia should precede HackTricks"
fi

# --- report structure ---
echo "== report structure =="
if grep -q 'Compile Report' "$SKILL"; then
  ok "has report compilation section"
else
  bad "missing report compilation section"
fi

# --- summary ---
echo ""
echo "== results: $PASS passed, $FAIL failed =="
if ((FAIL > 0)); then exit 1; fi
