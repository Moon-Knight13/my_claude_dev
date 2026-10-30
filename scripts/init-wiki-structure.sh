#!/usr/bin/env bash
# Initialize LLM Wiki directory structure inside an Obsidian vault.
# Idempotent — creates missing directories and templates without overwriting.
#
# Pattern: Karpathy LLM Wiki / Second Brain
#   raw/    — immutable intake (recon output, Providentia data, OSINT dumps)
#   wiki/   — AI-maintained structured pages, cross-linked
#   index.md — master index (AI keeps updated)
#   log.md  — change log
#
# Usage:
#   bash scripts/init-wiki-structure.sh /path/to/vault
#   bash scripts/init-wiki-structure.sh               # uses $OBSIDIAN_VAULT_CONTAINER_PATH
set -euo pipefail

VAULT="${1:-${OBSIDIAN_VAULT_CONTAINER_PATH:-/home/node/vault}}"

readonly GREEN='\033[0;32m' YELLOW='\033[1;33m' NC='\033[0m'
created() { printf "${GREEN}+${NC} %s\n" "$*"; }
exists() { printf "${YELLOW}=${NC} %s (exists)\n" "$*"; }

if [[ ! -d "$VAULT" ]]; then
    echo "Vault directory not found: ${VAULT}" >&2
    exit 1
fi

# ── Directories ───────────────────────────────────────────────────────────
dirs=(
    "raw"
    "raw/recon"
    "raw/providentia"
    "raw/osint"
    "raw/captures"
    "wiki"
    "wiki/targets"
    "wiki/techniques"
    "wiki/creds"
    "wiki/iocs"
    "wiki/remediation"
    "wiki/purple"
    "wiki/engagements"
    "templates"
)

for dir in "${dirs[@]}"; do
    target="${VAULT}/${dir}"
    if [[ -d "$target" ]]; then
        exists "$dir/"
    else
        mkdir -p "$target"
        created "$dir/"
    fi
done

# ── Template: target page ─────────────────────────────────────────────────
write_if_missing() {
    local file="$1"
    local content="$2"
    if [[ -f "${VAULT}/${file}" ]]; then
        exists "$file"
    else
        printf '%s' "$content" > "${VAULT}/${file}"
        created "$file"
    fi
}

write_if_missing "templates/target.md" '---
hostname: ""
ip: ""
os: ""
domain: ""
role: ""
team: ""
status: unknown
first_seen: ""
last_updated: ""
tags: [target]
---

# {{hostname}}

## Overview
- **IP:** {{ip}}
- **OS:** {{os}}
- **Domain:** {{domain}}
- **Role:** {{role}}

## Access
<!-- Credentials, sessions, persistence -->

## Services
<!-- Open ports, running services -->

## Findings
<!-- Vulnerabilities, misconfigurations -->

## Timeline
<!-- Key events in chronological order -->

## Related
<!-- Links to techniques, creds, IOCs -->
'

write_if_missing "templates/technique.md" '---
mitre_id: ""
mitre_tactic: ""
name: ""
platforms: []
tools_used: []
tags: [technique]
---

# {{name}}

## Description

## Execution
<!-- Step-by-step, tool commands, parameters -->

## Detection
<!-- What defenders see, log sources -->

## Targets Used On
<!-- Links to target pages where this was applied -->

## References
<!-- HackTricks, MITRE, external links -->
'

write_if_missing "templates/credential.md" '---
username: ""
domain: ""
type: ""
source_host: ""
harvest_method: ""
cracked: false
tags: [credential]
---

# {{username}}@{{domain}}

## Details
- **Type:** {{type}}
- **Source:** {{source_host}}
- **Method:** {{harvest_method}}

## Access Grants
<!-- What this credential unlocks -->

## Used In
<!-- Links to lateral movement, target pages -->
'

write_if_missing "templates/ioc.md" '---
type: ""
value: ""
first_seen: ""
context: ""
tags: [ioc]
---

# IOC: {{value}}

## Details
- **Type:** {{type}} (hash/ip/domain/filename/registry/service)
- **Context:** {{context}}

## Associated Targets
<!-- Where this IOC was observed -->
'

write_if_missing "templates/engagement.md" '---
name: ""
start_date: ""
end_date: ""
team: ""
scope: []
status: active
tags: [engagement]
---

# Engagement: {{name}}

## Scope
<!-- Authorized targets and networks -->

## Objectives

## Timeline
<!-- Key milestones and findings -->

## Findings Summary

## Report
<!-- Link to exported report -->
'

# ── Index ─────────────────────────────────────────────────────────────────
write_if_missing "index.md" '---
tags: [index, wiki]
---

# LLM Wiki — Master Index

> AI-maintained index. Updated automatically when wiki pages change.

## Engagements
<!-- Active and past engagements -->

## Targets
<!-- Links to all target pages, grouped by network/team -->

## Techniques
<!-- Links to technique pages, grouped by MITRE tactic -->

## Credentials
<!-- Links to credential pages -->

## IOCs
<!-- Links to IOC pages -->

## Remediation
<!-- Links to remediation notes -->

## Purple Team
<!-- Links to purple team findings -->
'

# ── Change Log ────────────────────────────────────────────────────────────
write_if_missing "log.md" '---
tags: [log, wiki]
---

# Wiki Change Log

> Append-only log. Each entry: date, page, action, summary.

| Date | Page | Action | Summary |
|------|------|--------|---------|
'

# ── Raw intake README ─────────────────────────────────────────────────────
write_if_missing "raw/README.md" '---
tags: [raw, intake]
---

# Raw Intake

Immutable intake directory. Files dropped here are source material — never
edited after initial placement.

## Subdirectories
- `recon/` — reconnaissance output (nmap, enum, discovery)
- `providentia/` — Providentia CMDB exports
- `osint/` — OSINT collection dumps
- `captures/` — packet captures, screenshots

## Convention
Filename format: `YYYY-MM-DD_<source>_<target>.<ext>`
Example: `2026-10-30_nmap_dc01.xml`
'

echo ""
echo "Wiki structure initialized at ${VAULT}"
