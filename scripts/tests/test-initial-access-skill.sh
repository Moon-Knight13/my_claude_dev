#!/usr/bin/env bash
# Tests for the initial-access skill — validates structure and required content.
#
# Usage: bash scripts/tests/test-initial-access-skill.sh
# Exit: 0 = all pass, non-zero = number of failures.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

fails=0
ok()   { echo "PASS $1"; }
bad()  { echo "FAIL $1: $2"; fails=$((fails + 1)); }

SKILL="$REPO_ROOT/.claude/skills/red-team/initial-access.md"

# --- 1. Skill file exists ----------------------------------------------------
if [[ -f "$SKILL" ]]; then
    ok skill-file-exists
else
    bad skill-file-exists "$SKILL not found"
    echo "Cannot continue without skill file."
    exit 1
fi

# --- 2. Frontmatter present --------------------------------------------------
if head -5 "$SKILL" | grep -q '^---' && grep -q '^name:' "$SKILL" && grep -q '^description:' "$SKILL"; then
    ok frontmatter-present
else
    bad frontmatter-present "missing YAML frontmatter (---, name:, description:)"
fi

# --- 3. Exploit hygiene — no Metasploit defaults ------------------------------
if grep -qi 'MUST NOT.*Metasploit\|NO Metasploit\|not.*default.*Metasploit\|Metasploit.*reference\|Metasploit.*learning' "$SKILL"; then
    ok exploit-hygiene-no-metasploit
else
    bad exploit-hygiene-no-metasploit "must mention no Metasploit defaults / exploit hygiene"
fi

# --- 4. RT-TGT-001 — target approval -----------------------------------------
if grep -q 'RT-TGT-001' "$SKILL"; then
    ok rt-tgt-001-target-approval
else
    bad rt-tgt-001-target-approval "must reference RT-TGT-001 (target approval)"
fi

# --- 5. RT-TGT-002 — no tools on target --------------------------------------
if grep -q 'RT-TGT-002' "$SKILL"; then
    ok rt-tgt-002-no-tools-on-target
else
    bad rt-tgt-002-no-tools-on-target "must reference RT-TGT-002 (no tools on target)"
fi

# --- 6. Lockout policy -------------------------------------------------------
if grep -qi 'lockout.*policy\|lockout.*threshold\|enumerate.*lockout' "$SKILL"; then
    ok lockout-policy-mentioned
else
    bad lockout-policy-mentioned "must mention lockout policy enumeration"
fi

# --- 7. Persist-swarm after success -------------------------------------------
if grep -qi 'persist-swarm\|persist.on.landing\|persist.*after.*access\|persistence.*before' "$SKILL"; then
    ok persist-swarm-after-success
else
    bad persist-swarm-after-success "must mention persist-swarm or persist-on-landing after successful access"
fi

# --- 8. Multiple technique types ----------------------------------------------
technique_count=0
for technique in "web.exploit|web.application|CVE" \
                 "weak.cred|default.cred|credential.spray" \
                 "service.exploit|SSH|RDP|SMB" \
                 "social.eng|phishing" \
                 "config.abuse|misconfig"; do
    if grep -qiE "$technique" "$SKILL"; then
        technique_count=$((technique_count + 1))
    fi
done

if [[ "$technique_count" -ge 3 ]]; then
    ok "multiple-technique-types ($technique_count found)"
else
    bad "multiple-technique-types" "expected at least 3 technique types, found $technique_count"
fi

# --- 9. Engagement YAML mentioned ---------------------------------------------
if grep -qi 'engagement.*YAML\|engagement.yaml' "$SKILL"; then
    ok engagement-yaml-referenced
else
    bad engagement-yaml-referenced "must reference engagement YAML for state tracking"
fi

# --- 10. Recon prerequisite ---------------------------------------------------
if grep -qi 'recon.*complet\|recon.*phase\|phase.*recon' "$SKILL"; then
    ok recon-prerequisite
else
    bad recon-prerequisite "must check recon completion as prerequisite"
fi

# --- 11. OPSEC identity rules ------------------------------------------------
if grep -q 'RT-SIG-001' "$SKILL" && grep -q 'RT-SIG-002' "$SKILL"; then
    ok opsec-identity-rules
else
    bad opsec-identity-rules "must reference RT-SIG-001 (root agent) and RT-SIG-002 (unique payload)"
fi

# --- 12. Failure modes documented ---------------------------------------------
if grep -qi 'failure.mode\|exploit.fails\|ABORT\|wrong.target' "$SKILL"; then
    ok failure-modes-documented
else
    bad failure-modes-documented "must document failure modes"
fi

echo ""
if [[ "$fails" -eq 0 ]]; then
    echo "ALL PASS"
else
    echo "$fails FAILED"
fi
exit "$fails"
