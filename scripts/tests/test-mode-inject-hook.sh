#!/usr/bin/env bash
# Tests for mode-inject.sh hook — skill filtering, JSON output, edge cases.
#
# Runs the hook against a temp copy of .claude/ with synthetic .active-mode
# files. No side effects on the real config.
#
# Usage: bash scripts/tests/test-mode-inject-hook.sh
# Exit: 0 pass, non-zero = number of failures.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
HOOK="$REPO_ROOT/scripts/hooks/mode-inject.sh"

fails=0
ok()   { echo "PASS $1"; }
bad()  { echo "FAIL $1: $2"; fails=$((fails + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Build minimal project tree for hook testing
mkdir -p "$TMP/.claude"
cp -r "$REPO_ROOT/.claude/modes" "$TMP/.claude/modes"
cp -r "$REPO_ROOT/.claude/skills" "$TMP/.claude/skills"

# Helper: run hook with given mode, return output
_run_hook() {
    local mode="$1"
    echo "$mode" > "$TMP/.claude/.active-mode"
    CLAUDE_PROJECT_DIR="$TMP" bash "$HOOK" <<< '{}' 2>/dev/null
}

# Helper: extract additionalContext from hook JSON
_get_context() {
    local mode="$1"
    _run_hook "$mode" | jq -r '.hookSpecificOutput.additionalContext // empty'
}

# ── 1. Hook produces valid JSON for each mode ─────────────────────────────────
for mode in red-team purple red-dev green-dev platform-ops; do
    output="$(_run_hook "$mode")"
    if echo "$output" | jq empty 2>/dev/null; then
        ok "hook-valid-json-$mode"
    else
        bad "hook-valid-json-$mode" "hook output is not valid JSON for mode $mode"
    fi
done

# ── 2. Hook exits 0 with no .active-mode file ────────────────────────────────
rm -f "$TMP/.claude/.active-mode"
output="$(CLAUDE_PROJECT_DIR="$TMP" bash "$HOOK" <<< '{}' 2>/dev/null)"
rc=$?
if [[ $rc -eq 0 ]] && [[ -z "$output" ]]; then
    ok hook-no-mode-silent
else
    bad hook-no-mode-silent "expected silent exit 0 without .active-mode (rc=$rc, output=$output)"
fi

# ── 3. Hook exits 0 with empty .active-mode file ─────────────────────────────
echo "" > "$TMP/.claude/.active-mode"
output="$(CLAUDE_PROJECT_DIR="$TMP" bash "$HOOK" <<< '{}' 2>/dev/null)"
rc=$?
if [[ $rc -eq 0 ]] && [[ -z "$output" ]]; then
    ok hook-empty-mode-silent
else
    bad hook-empty-mode-silent "expected silent exit 0 with empty .active-mode (rc=$rc)"
fi

# ── 4. Hook exits 0 with invalid mode name ───────────────────────────────────
echo "nonexistent" > "$TMP/.claude/.active-mode"
output="$(CLAUDE_PROJECT_DIR="$TMP" bash "$HOOK" <<< '{}' 2>/dev/null)"
rc=$?
if [[ $rc -eq 0 ]] && [[ -z "$output" ]]; then
    ok hook-invalid-mode-silent
else
    bad hook-invalid-mode-silent "expected silent exit 0 with invalid mode (rc=$rc)"
fi

# ── 5. Context contains MODE ACTIVE header ────────────────────────────────────
ctx="$(_get_context red-team)"
if echo "$ctx" | grep -q "^MODE ACTIVE: red-team"; then
    ok hook-mode-header
else
    bad hook-mode-header "missing 'MODE ACTIVE: red-team' header"
fi

# ── 6. Context contains system-prompt content ─────────────────────────────────
if echo "$ctx" | grep -q "Kill Chain"; then
    ok hook-injects-system-prompt
else
    bad hook-injects-system-prompt "system-prompt content not in hook output"
fi

# ── 7. Skill filter block present for red-team ───────────────────────────────
if echo "$ctx" | grep -q "Skill Filter for red-team mode"; then
    ok hook-skill-filter-present
else
    bad hook-skill-filter-present "missing skill filter block in red-team output"
fi

# ── 8. Skill filter contains expected skills for red-team ────────────────────
rt_expected="recon discovery cred-harvest lateral-move persist-swarm engagement-state pre-engagement-cache initial-access kali-bootstrap lolbins opsec-cred-spray opsec-exploit-hygiene spoke-health"
rt_missing=""
for skill in $rt_expected; do
    if ! echo "$ctx" | grep -q "$skill"; then
        rt_missing="$rt_missing $skill"
    fi
done
if [[ -z "$rt_missing" ]]; then
    ok hook-red-team-skills-complete
else
    bad hook-red-team-skills-complete "missing skills:$rt_missing"
fi

# ── 9. Skill filter for green-dev has only its skills ────────────────────────
gd_ctx="$(_get_context green-dev)"
if echo "$gd_ctx" | grep -q "Skill Filter for green-dev mode"; then
    gd_expected="ctp-deploy range-build spoke-health"
    gd_missing=""
    for skill in $gd_expected; do
        if ! echo "$gd_ctx" | grep -q "$skill"; then
            gd_missing="$gd_missing $skill"
        fi
    done
    if [[ -z "$gd_missing" ]]; then
        ok hook-green-dev-skills-correct
    else
        bad hook-green-dev-skills-correct "missing skills:$gd_missing"
    fi
else
    bad hook-green-dev-skills-correct "no skill filter block for green-dev"
fi

# ── 10. Green-dev does NOT get red-team skills ───────────────────────────────
if echo "$gd_ctx" | grep "Preferred skills:" | grep -q "cred-harvest"; then
    bad hook-green-dev-no-offensive-skills "green-dev filter includes cred-harvest"
else
    ok hook-green-dev-no-offensive-skills
fi

# ── 11. Platform-ops gets only spoke-health ──────────────────────────────────
po_ctx="$(_get_context platform-ops)"
if echo "$po_ctx" | grep -q "Skill Filter for platform-ops mode"; then
    if echo "$po_ctx" | grep "Preferred skills:" | grep -q "spoke-health"; then
        ok hook-platform-ops-has-spoke-health
    else
        bad hook-platform-ops-has-spoke-health "platform-ops filter missing spoke-health"
    fi
else
    bad hook-platform-ops-has-spoke-health "no skill filter block for platform-ops"
fi

# ── 12. Skill filter contains bmad suppression ───────────────────────────────
if echo "$ctx" | grep -q "Do NOT invoke bmad-"; then
    ok hook-bmad-suppression
else
    bad hook-bmad-suppression "missing bmad suppression directive"
fi

# ── 13. All skills with modes: field reference valid mode directories ────────
bad_modes=""
for skill_file in "$REPO_ROOT/.claude/skills"/*/SKILL.md; do
    [[ -f "$skill_file" ]] || continue
    modes_line="$(sed -n '/^---$/,/^---$/{/^modes:/p}' "$skill_file" 2>/dev/null)"
    [[ -n "$modes_line" ]] || continue
    for m in $(printf '%s' "$modes_line" | sed 's/modes://;s/\[//;s/\]//;s/,/ /g'); do
        if [[ ! -d "$REPO_ROOT/.claude/modes/$m" ]]; then
            bad_modes="$bad_modes $(basename "$(dirname "$skill_file")"):$m"
        fi
    done
done
if [[ -z "$bad_modes" ]]; then
    ok skill-modes-all-valid
else
    bad skill-modes-all-valid "invalid mode refs:$bad_modes"
fi

# ── 14. All skills with modes: field have valid YAML frontmatter ─────────────
bad_frontmatter=""
for skill_file in "$REPO_ROOT/.claude/skills"/*/SKILL.md; do
    [[ -f "$skill_file" ]] || continue
    skill_name="$(basename "$(dirname "$skill_file")")"
    # Check frontmatter exists (two --- lines)
    fence_count="$(grep -c '^---$' "$skill_file" 2>/dev/null || true)"
    if [[ "$fence_count" -lt 2 ]]; then
        bad_frontmatter="$bad_frontmatter $skill_name(no-frontmatter)"
        continue
    fi
    # If has modes: line, verify bracket format
    modes_line="$(sed -n '/^---$/,/^---$/{/^modes:/p}' "$skill_file" 2>/dev/null)"
    if [[ -n "$modes_line" ]]; then
        if ! printf '%s' "$modes_line" | grep -qE '^\s*modes:\s*\[.*\]\s*$'; then
            bad_frontmatter="$bad_frontmatter $skill_name(bad-format)"
        fi
    fi
done
if [[ -z "$bad_frontmatter" ]]; then
    ok skill-frontmatter-valid
else
    bad skill-frontmatter-valid "bad frontmatter:$bad_frontmatter"
fi

# ── 15. Deep-dive reference files exist ──────────────────────────────────────
ref_missing=""
for ref in docs/SAFETY_GATES.md docs/TROUBLESHOOTING.md docs/SAFETY_HARNESS.md; do
    if [[ ! -f "$REPO_ROOT/$ref" ]]; then
        ref_missing="$ref_missing $ref"
    fi
done
if [[ -z "$ref_missing" ]]; then
    ok deep-dive-refs-exist
else
    bad deep-dive-refs-exist "missing:$ref_missing"
fi

# ── 16. CLAUDE.md references deep-dive files ─────────────────────────────────
claude_md="$REPO_ROOT/CLAUDE.md"
ref_check_ok=true
for ref in SAFETY_GATES.md TROUBLESHOOTING.md SAFETY_HARNESS.md; do
    if ! grep -q "$ref" "$claude_md" 2>/dev/null; then
        ref_check_ok=false
    fi
done
if $ref_check_ok; then
    ok claude-md-has-deep-dive-pointers
else
    bad claude-md-has-deep-dive-pointers "CLAUDE.md missing deep-dive reference pointers"
fi

# ── 17. Red-team skill count within expected range ───────────────────────────
rt_skill_line="$(_get_context red-team | grep "Preferred skills:")"
rt_count="$(echo "$rt_skill_line" | tr ',' '\n' | wc -l)"
if [[ "$rt_count" -ge 10 && "$rt_count" -le 20 ]]; then
    ok hook-red-team-skill-count
else
    bad hook-red-team-skill-count "expected 10-20 skills, got $rt_count"
fi

# ── 18. Green-dev skill count within expected range ──────────────────────────
gd_skill_line="$(_get_context green-dev | grep "Preferred skills:")"
gd_count="$(echo "$gd_skill_line" | tr ',' '\n' | wc -l)"
if [[ "$gd_count" -ge 2 && "$gd_count" -le 6 ]]; then
    ok hook-green-dev-skill-count
else
    bad hook-green-dev-skill-count "expected 2-6 skills, got $gd_count"
fi

echo ""
if [[ "$fails" -eq 0 ]]; then
    echo "ALL PASS"
else
    echo "$fails FAILED"
fi
exit "$fails"
