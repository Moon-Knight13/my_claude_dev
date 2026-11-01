#!/usr/bin/env bash
# Tests for export-report.sh and compile-report.mjs
#
# Creates a mock vault with wiki pages, runs the export, validates output.
# Usage: bash scripts/tests/test-report-export.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

fails=0
ok()   { echo "PASS $1"; }
bad()  { echo "FAIL $1: $2"; fails=$((fails + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

VAULT="$TMP/vault"
REPORTS="$TMP/reports"

# ── Build mock vault ──────────────────────────────────────────────────────
mkdir -p "$VAULT/.obsidian"
bash "$REPO_ROOT/scripts/init-wiki-structure.sh" "$VAULT" >/dev/null 2>&1

# Create engagement
cat > "$VAULT/wiki/engagements/test-ex.md" << 'EOF'
---
name: "Test Exercise"
start_date: "2026-10-30"
end_date: ""
team: "t02"
scope: [10.0.0.0/24]
status: active
tags: [engagement]
---

# Test Exercise

## Scope
- 10.0.0.0/24 network

## Objectives
- Validate export pipeline
EOF

# Create target
cat > "$VAULT/wiki/targets/dc01.md" << 'EOF'
---
hostname: "dc01"
ip: "10.0.0.10"
os: "Windows Server 2022"
domain: "test.local"
role: "Domain Controller"
team: "t02"
status: compromised
first_seen: "2026-10-30"
tags: [target]
---

# dc01

## Overview
Primary domain controller.

## Services
- 53/tcp DNS
- 88/tcp Kerberos
- 389/tcp LDAP
- 445/tcp SMB
EOF

# Create technique
cat > "$VAULT/wiki/techniques/kerberoasting.md" << 'EOF'
---
mitre_id: "T1558.003"
mitre_tactic: "Credential Access"
name: "Kerberoasting"
platforms: [Windows]
tools_used: [rubeus, hashcat]
tags: [technique]
---

# Kerberoasting

## Description
Request TGS tickets for service accounts, crack offline.

## Execution
1. Identify SPNs with LDAP query
2. Request TGS tickets
3. Crack with hashcat
EOF

# Create credential
cat > "$VAULT/wiki/creds/svc-sql.md" << 'EOF'
---
username: "svc-sql"
domain: "test.local"
type: "NTLM hash"
source_host: "dc01"
harvest_method: "kerberoasting"
cracked: true
tags: [credential]
---

# svc-sql@test.local

## Details
Service account for SQL Server.
EOF

# Create IOC
cat > "$VAULT/wiki/iocs/hash-rubeus.md" << 'EOF'
---
type: "hash"
value: "abc123def456"
first_seen: "2026-10-30"
context: "Rubeus execution artifact"
tags: [ioc]
---

# IOC: abc123def456

Rubeus binary hash observed on dc01.
EOF

# ── Test: export-report.sh --list ─────────────────────────────────────────
output=$(OBSIDIAN_VAULT_CONTAINER_PATH="$VAULT" bash "$REPO_ROOT/scripts/export-report.sh" --list 2>&1)
if echo "$output" | grep -q 'test-ex'; then
    ok list-shows-engagement
else
    bad list-shows-engagement "engagement not listed: $output"
fi

# ── Test: compile HTML report ──────────────────────────────────────────────
if OBSIDIAN_VAULT_CONTAINER_PATH="$VAULT" REPORTS_DIR="$REPORTS" \
   bash "$REPO_ROOT/scripts/export-report.sh" test-ex --format html >/dev/null 2>&1; then
    ok compile-runs
else
    bad compile-runs "export-report.sh failed"
fi

# ── Test: HTML file created ───────────────────────────────────────────────
html_file=$(find "$REPORTS" -name "*.html" -type f | head -1)
if [[ -n "$html_file" ]]; then
    ok html-file-created
else
    bad html-file-created "no HTML file in $REPORTS"
    # Remaining tests need the file
    echo "$fails test(s) FAILED."
    exit "$fails"
fi

# ── Test: HTML contains engagement title ──────────────────────────────────
if grep -q 'Test Exercise' "$html_file"; then
    ok html-has-title
else
    bad html-has-title "missing engagement title"
fi

# ── Test: HTML contains target ────────────────────────────────────────────
if grep -q 'dc01' "$html_file" && grep -q '10.0.0.10' "$html_file"; then
    ok html-has-target
else
    bad html-has-target "missing target dc01"
fi

# ── Test: HTML contains technique ─────────────────────────────────────────
if grep -q 'Kerberoasting' "$html_file" && grep -q 'T1558.003' "$html_file"; then
    ok html-has-technique
else
    bad html-has-technique "missing technique"
fi

# ── Test: HTML contains credential table ──────────────────────────────────
if grep -q 'svc-sql' "$html_file" && grep -q 'test.local' "$html_file"; then
    ok html-has-credential
else
    bad html-has-credential "missing credential"
fi

# ── Test: HTML contains IOC ───────────────────────────────────────────────
if grep -q 'abc123def456' "$html_file"; then
    ok html-has-ioc
else
    bad html-has-ioc "missing IOC"
fi

# ── Test: HTML is valid-ish (has doctype, head, body) ─────────────────────
if grep -q '<!DOCTYPE html>' "$html_file" && \
   grep -q '<head>' "$html_file" && \
   grep -q '<body>' "$html_file"; then
    ok html-structure-valid
else
    bad html-structure-valid "missing HTML structure elements"
fi

# ── Test: HTML has print-friendly styles ──────────────────────────────────
if grep -q '@media print' "$html_file"; then
    ok html-print-styles
else
    bad html-print-styles "missing print media query"
fi

# ── Test: HTML has metadata (date, team, status) ──────────────────────────
today=$(date +%Y-%m-%d)
if grep -q "$today" "$html_file"; then
    ok html-has-date
else
    bad html-has-date "missing generation date"
fi

if grep -q 't02' "$html_file"; then
    ok html-has-team
else
    bad html-has-team "missing team"
fi

# ── Test: missing engagement fails gracefully ─────────────────────────────
if OBSIDIAN_VAULT_CONTAINER_PATH="$VAULT" REPORTS_DIR="$REPORTS" \
   bash "$REPO_ROOT/scripts/export-report.sh" nonexistent --format html >/dev/null 2>&1; then
    bad missing-engagement-fails "should fail for nonexistent engagement"
else
    ok missing-engagement-fails
fi

# ── Test: empty sections handled ──────────────────────────────────────────
if grep -q 'No remediation pages found' "$html_file"; then
    ok empty-sections-handled
else
    bad empty-sections-handled "missing empty section message"
fi

# ── Test: DOCX skipped gracefully when no pandoc ──────────────────────────
output=$(OBSIDIAN_VAULT_CONTAINER_PATH="$VAULT" REPORTS_DIR="$TMP/reports2" \
   bash "$REPO_ROOT/scripts/export-report.sh" test-ex --format docx 2>&1)
if echo "$output" | grep -qi 'pandoc not available\|HTML:'; then
    ok docx-graceful-skip
else
    bad docx-graceful-skip "DOCX export didn't handle missing pandoc"
fi

# ── Summary ───────────────────────────────────────────────────────────────
echo ""
if (( fails == 0 )); then
    echo "All tests passed."
else
    echo "${fails} test(s) FAILED."
fi
exit "$fails"
