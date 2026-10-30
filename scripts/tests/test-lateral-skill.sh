#!/usr/bin/env bash
# test-lateral-skill.sh — content tests for the lateral movement skill file.
#
# Validates that the skill markdown contains required sections, rule
# references, methods, and the mandatory persist-on-lateral gate.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok()   { echo "  OK  $1"; ((PASS++)) || true; }
bad()  { echo " FAIL $1"; ((FAIL++)) || true; }

SKILL="$ROOT/.claude/skills/red-team/lateral.md"

# ============================================================================
echo "== file existence =="
if [[ -f "$SKILL" ]]; then ok "skill file exists"; else bad "skill file exists at $SKILL"; fi

# ============================================================================
echo "== frontmatter =="
if head -5 "$SKILL" | grep -q '^---'; then
    ok "frontmatter delimiter present"
else bad "frontmatter delimiter present"; fi

if grep -q '^name: lateral' "$SKILL"; then
    ok "frontmatter name is 'lateral'"
else bad "frontmatter name is 'lateral'"; fi

if grep -q '^description:' "$SKILL"; then
    ok "frontmatter has description"
else bad "frontmatter has description"; fi

# ============================================================================
echo "== persist-on-lateral rule =="
if grep -qi 'persist-on-lateral' "$SKILL"; then
    ok "mentions persist-on-lateral rule"
else bad "mentions persist-on-lateral rule"; fi

if grep -qi 'persist-swarm' "$SKILL"; then
    ok "mentions persist-swarm invocation"
else bad "mentions persist-swarm invocation"; fi

if grep -qi 'mandatory\|non-negotiable\|MUST run' "$SKILL"; then
    ok "persist-swarm described as mandatory"
else bad "persist-swarm described as mandatory"; fi

# ============================================================================
echo "== OPSEC rule references =="
if grep -q 'RT-TGT-001' "$SKILL"; then
    ok "references RT-TGT-001 (target approval)"
else bad "references RT-TGT-001 (target approval)"; fi

if grep -q 'RT-SIG-001' "$SKILL"; then
    ok "references RT-SIG-001 (no rt-prefixed users)"
else bad "references RT-SIG-001 (no rt-prefixed users)"; fi

if grep -q 'RT-TGT-002' "$SKILL"; then
    ok "references RT-TGT-002 (no tools on target)"
else bad "references RT-TGT-002 (no tools on target)"; fi

# ============================================================================
echo "== lateral methods =="
METHODS=("wmi" "psexec" "ssh-key" "ssh-pass" "dcom" "winrm" "smbexec")
for m in "${METHODS[@]}"; do
    if grep -qi "$m" "$SKILL"; then
        ok "mentions method: $m"
    else bad "mentions method: $m"; fi
done

# ============================================================================
echo "== credential validation =="
if grep -qi 'cred_ref' "$SKILL"; then
    ok "mentions cred_ref validation"
else bad "mentions cred_ref validation"; fi

if grep -qi 'credential' "$SKILL"; then
    ok "mentions credential checking"
else bad "mentions credential checking"; fi

# ============================================================================
echo "== engagement YAML =="
if grep -qi 'lateral_moves' "$SKILL"; then
    ok "mentions lateral_moves YAML section"
else bad "mentions lateral_moves YAML section"; fi

if grep -qi 'engagement.*yaml\|engagement YAML' "$SKILL"; then
    ok "mentions engagement YAML updates"
else bad "mentions engagement YAML updates"; fi

# ============================================================================
echo "== agent validation =="
if grep -qi 'active agent\|agent.*exist\|agent.*source' "$SKILL"; then
    ok "mentions agent validation on source"
else bad "mentions agent validation on source"; fi

if grep -qi 'tuoni-mcp\|tuoni_' "$SKILL"; then
    ok "mentions tuoni-mcp for agent checks"
else bad "mentions tuoni-mcp for agent checks"; fi

# ============================================================================
echo ""
echo "Result: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
