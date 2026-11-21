<!-- Mini variant for subagent dispatch. Full version: SKILL.md -->
---
name: recon
description: "Phase-based reconnaissance skill for red-team and purple modes. Queries authoritative sources first (Providentia, GitLab READMEs, wiki collections), then reference MCPs. Use when operator says 'recon', 'target', 'research <hostname>', or starts an engagement."
modes: [red-team, purple, ctf]
---

# Recon — Mini

## Entry criteria

- Mode is red-team, purple, or ctf
- Operator has named a target (hostname, IP, or role description)
- Engagement YAML exists or will be created

## Source Priority (ENFORCED)

Query in order. Only proceed to next tier when current is insufficient.

1. **Tier 1 — Authoritative:** Providentia (`range_host`, `range_networks`), GitLab READMEs (`range_host` with `include_readme=true`), Outline wiki (repo-docs, vulns-docs)
2. **Tier 2 — Operational:** Tuoni Discovery (`tuoni_hosts_list`), BloodHound (AD environments), Obsidian notes
3. **Tier 3 — Reference:** Nuclei, HackTricks, MITRE ATT&CK, LOLBins, CVE intelligence, web research

## Black-Box / Blind Mode

Activates when engagement YAML has `type: black-box`, Providentia returns empty, or range-intel unreachable. Skip Tier 1 entirely for black-box. Set `intel_source: blind_scan` on engagement page.

Blind pipeline: network discovery (`nmap -sn`) → service scan (`nmap -sV -sC -p-`) → per-service CVE/HackTricks/Nuclei research → write to Obsidian in same format as Providentia-enriched data.

## Phases

### Phase 0: Reachability + Service Enumeration (MANDATORY, RUN ONCE)

Run ONCE per engagement from Kali. ALL scanning from Kali — NEVER from hub.

1. Network position + pivot classification (OFFENSIVE-PIVOT vs C2-ONLY)
2. Host discovery: `nmap -sn <subnet> --min-rate 1000`
3. Full service enum: `nmap -sV -sC -p- <host>` per live host
4. Cross-reference with Providentia, reclassify targets via engagement-state: confirmed / unreachable / different-than-expected
5. Write to Obsidian: per-host target pages + engagement reachability matrix
6. Target selection: only `confirmed` targets proceed. Master gets RT-TGT-001 approval.

### Phase 1: Passive Recon

Query ALL Tier 1 + Tier 2 sources. Build target profile (OS, IPs, services, role, deploy notes, known defaults, prior vulns, existing agents). Present to operator.

### Phase 2: Verify Obsidian Data (NO RE-SCAN)

Read Obsidian target page `## Services`. Confirm service:version table exists. If missing for a host not covered by Phase 0, run ONE targeted scan.

### Phase 3: Vulnerability Analysis (WRITES TO OBSIDIAN — initial-access reads this)

Per identified service:version:
- Nuclei template scanning from Kali
- BloodHound AD path analysis (if AD environment)
- CVE enrichment: `cve_by_product` → `cve_enrich` → `cve_prioritize` → `exploit_search`
- HackTricks technique research
- MITRE ATT&CK technique IDs + detection info
- LOLBins OPSEC risk assessment

**OPSEC: opsec-exploit-hygiene** — Metasploit modules are REFERENCE ONLY.

### Phase 4: Target Assessment

Produce ranked attack vector list: vector name + technique ID + CVE, likelihood, stealth rating, prerequisites. Present to operator for initial-access handoff.

## Thread Orchestration

Recon runs as SEPARATE thread from exploitation. Do not combine recon and initial-access in one thread. Recon produces Obsidian target page; initial-access consumes it.

## Exit criteria

- All targets reclassified (no stale candidates)
- Per-service CVE research complete (ALL services, not just first)
- Attack vectors ranked with PoC details (not just CVE numbers)
- Obsidian target page fully populated
- `/log-finding` invoked for each significant result

## State writes

**Obsidian is primary output.** Engagement YAML is lean — phase status + refs only.

```yaml
targets:
  - hostname: <target>
    classification: confirmed
    phase: recon
    status: complete
    wiki_page: llm-wiki/wiki/targets/<hostname>.md
```

Obsidian paths (ENFORCED): `llm-wiki/raw/<hostname>-recon-<date>.md`, `llm-wiki/wiki/targets/<hostname>.md`, `llm-wiki/log.md`.

## Degraded mode

When `degraded_mode: router-only`: use Python socket `connect_ex` for port scanning, `curl -sk` for web fingerprint. No nmap, no UDP, no Nuclei. See full SKILL.md for details.
