---
name: recon
description: "Phase-based reconnaissance skill for red-team and purple modes. Queries authoritative sources first (Providentia, GitLab READMEs, wiki collections), then reference MCPs. Use when operator says 'recon', 'target', 'research <hostname>', or starts an engagement."
---

# Recon Skill — Source-Priority Phased Reconnaissance

## When to use

Operator asks to research a target, start an engagement, or perform recon.
Active in: **red-team**, **purple** modes only.

## Entry criteria

- Mode is red-team or purple
- Operator has named a target (hostname, IP, or role description)
- Engagement YAML exists or will be created

## Source Priority (ENFORCED)

Query sources in this order. Only proceed to next tier when current tier
is insufficient for the question.

### Tier 1 — Authoritative (ground truth)

1. **Providentia** via range-intel MCP (`range_host`, `range_networks`)
   - What the box IS: OS, IPs, services, team, role
   - Network topology: subnets, gateways, DNS
2. **GitLab READMEs** via range-intel MCP (`range_host` with `include_readme=true`)
   - What the box SHOULD have: deploy notes, config, known defaults
3. **Wiki — repo-docs collection** via outline-readonly MCP
   - GitLab READMEs mirrored to wiki, broader context
4. **Wiki — vulns-docs collection** via outline-readonly MCP
   - Vulnerability research, exploit notes, prior engagement findings

### Tier 2 — Operational state

5. **Tuoni Discovery** via tuoni-mcp (`tuoni_discovery_hosts_list`)
   - Live C2 state: existing agents, discovered hosts from prior ops
   - ALWAYS queried fresh, never cached
6. **Obsidian notes** via obsidian-mcp
   - Operator tactical knowledge from prior engagements
   - Check raw/ for prior recon dumps, wiki/ for compiled intel

### Tier 3 — Reference (research)

7. **HackTricks** via hacktricks-mcp — attack techniques for this platform/service
8. **MITRE ATT&CK** via mitre-mcp — technique IDs, detection strategies
9. **GTFOBins** via gtfobins-mcp — Unix binary abuse (post-exploit)
10. **eip-mcp** — CVE details, EPSS scores, exploit availability
11. **Web research** — last resort when all above insufficient

## Phases

### Phase 1: Passive Recon

Query ALL Tier 1 + Tier 2 sources. Build target profile:

```
Target: <hostname>
OS: <from Providentia>
IPs: <from Providentia>
Services: <from Providentia>
Team: <from Providentia>
Role: <from Providentia>
Deploy notes: <from GitLab README>
Known defaults: <from README/wiki>
Prior vulns: <from vulns-docs>
Existing agents: <from Tuoni Discovery>
Prior engagement notes: <from Obsidian>
```

Present profile to operator. Ask: "Proceed to active recon?"

### Phase 2: Active Recon (requires operator approval)

**OPSEC GATE: RT-TGT-001** — confirm exact target before ANY scan.

Execute net-recon from Kali agent (tuoni-mcp):
- Port scan + service fingerprint
- Web fingerprint (if HTTP/HTTPS exposed)
- Banner grab
- Compare results against Providentia data (what IS vs what SHOULD BE)

Discrepancies between Providentia (expected) and net-recon (actual) are
high-value findings — document them.

### Phase 3: Vulnerability Analysis

Cross-reference active recon results with Tier 3 sources:
- HackTricks: platform-specific attack techniques
- MITRE: technique IDs for each finding
- eip-mcp: CVE details, EPSS scores for identified versions

**OPSEC: opsec-exploit-hygiene** — flag any Metasploit modules as
REFERENCE ONLY. Extract technique, note for custom implementation.

### Phase 4: Target Assessment

Produce ranked attack vector list:
1. Vector name + technique ID
2. Likelihood of success (from EPSS, prior findings, config analysis)
3. Stealth rating (noise level, detection probability)
4. Prerequisites (creds needed? auth required? adjacent access?)

Present to operator for initial-access skill handoff.

## Exit criteria

- Target profile complete (all Tier 1 sources queried)
- Active recon results documented (if Phase 2 approved)
- Attack vectors ranked and presented
- Engagement YAML updated: phase=recon, target data cached
- Obsidian raw/: recon dump saved
- Obsidian wiki/<hostname>.md: structured target page created/updated

## State writes

```yaml
# engagement.yaml updates
phase: recon
targets:
  - hostname: <target>
    providentia_data: <cached>
    net_recon: <results>
    attack_vectors: <ranked list>
```

```
# Obsidian writes
raw/<hostname>-recon-<date>.md    # immutable dump
wiki/<hostname>.md                # structured page (create or update)
```

## Failure modes

- **Providentia unreachable**: warn operator, proceed with cached data or
  README only. Never proceed with NO authoritative source.
- **Kali spoke unreachable**: passive recon only (Tier 1+2). Cannot do
  active recon without weapons platform.
- **Target not in Providentia**: warn operator — target may not exist on
  range. Require explicit confirmation before proceeding.
