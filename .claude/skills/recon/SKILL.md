---
name: recon
description: "Phase-based reconnaissance skill for red-team and purple modes. Queries authoritative sources first (Providentia, GitLab READMEs, wiki collections), then reference MCPs. Use when operator says 'recon', 'target', 'research <hostname>', or starts an engagement."
modes: [red-team, purple]
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
6. **BloodHound** via bloodhound-mcp (AD environments only)
   - Attack path queries: shortest path to DA, kerberoastable users, delegation abuse
   - NTLM relay vectors, certificate services vulns, AD hygiene
   - Natural language queries — no manual Cypher needed
   - Requires bloodhound-python collection data loaded into Neo4j
7. **Obsidian notes** via obsidian-mcp
   - Operator tactical knowledge from prior engagements
   - Check raw/ for prior recon dumps, wiki/ for compiled intel

### Tier 3 — Reference (research)

8. **Nuclei** via nuclei-mcp — template-filtered vuln scanning with structured findings
9. **HackTricks** via hacktricks-mcp — attack techniques for this platform/service
10. **MITRE ATT&CK** via mitre-mcp — technique IDs, detection strategies
11. **LOLBins** via lolbins-mcp — living-off-the-land binary abuse (Windows + Linux)
12. **CVE intelligence** via cve-mcp — CVE details, EPSS scores, KEV, exploits
13. **Web research** — last resort when all above insufficient

## Phases

### Phase 0: Network Reachability (MANDATORY before any target work)

**Run ONCE per engagement start, from Kali self-agent.** Determines what Kali
can actually see. Providentia lists what SHOULD exist — this phase finds what
IS reachable. Do not skip this phase. Do not assume Providentia IPs are routable.

1. **Identify Kali's network position**: `ip route`, `ip addr` on self-agent
2. **Enumerate routable subnets**: which ranges have routes from Kali?
3. **Sweep reachable subnets**: ICMP ping sweep + TCP SYN on common ports
   (22, 80, 443, 445, 3389) per routable subnet. Use net-recon plugin or
   nmap from Kali.
4. **Cross-reference with Providentia**: match responding hosts against
   `range_targets_summary`. Categorize each target as:
   - **REACHABLE** — responds to ping or has open ports
   - **FILTERED** — route exists but all ports filtered (firewall blocks)
   - **UNREACHABLE** — no route or no response at all
   - **NOT_DEPLOYED** — Providentia lists it but tagged not_ready/no IP
5. **Document reachability matrix** in engagement YAML and Obsidian
6. **Only REACHABLE targets proceed** to Phase 1+. FILTERED targets need
   a pivot host or firewall bypass first. UNREACHABLE/NOT_DEPLOYED targets
   are deferred until conditions change.

This prevents wasting threads on targets behind firewalls or not yet deployed.
When lateral movement opens new network segments, re-run Phase 0 from the
new foothold to discover newly reachable targets.

### Phase 1: Passive Recon

Query ALL Tier 1 + Tier 2 sources. Build target profile:

**Providentia query strategy:** Use `range_host(env, host_id, team)` for
individual host lookups. Use `range_targets_summary(env, team)` for inventory
overview (lightweight, no vuln enrichment). Avoid `range_targets` without
filters on large environments (>50 hosts) — use tag/role filters or pagination
(`offset`/`limit`). If bulk query exceeds MCP token limit, fall back to
per-host queries iterated over known host IDs.

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

### Phase 2: Active Recon — Service Enumeration (requires operator approval)

**OPSEC GATE: RT-TGT-001** — confirm exact target before ANY scan.

**This phase produces the GROUND TRUTH for attack vector selection.**
Providentia says what should exist. This phase finds what actually runs.

Execute from Kali agent (tuoni plugins + Kali tools):

1. **Full port scan**: `net-recon routing_recon` + `nmap -sV -sC` for versions
2. **Service fingerprint**: exact version strings for every open port
3. **Web fingerprint**: `net-recon web_fingerprint` for HTTP/HTTPS services
4. **Banner grab**: SSH, SMTP, FTP, database banners
5. **Compare against Providentia**: what IS running vs what SHOULD BE
   - Services in Providentia but not found = non-functional or hardened
   - Services found but not in Providentia = undocumented attack surface (HIGH VALUE)

**Output:** service:version table per target. This table — not Providentia vuln
names — feeds into initial-access Phase 1 technique research.

Discrepancies between Providentia (expected) and enumeration (actual) are
high-value findings — document them. They reveal hardening, misconfiguration,
or undocumented services.

### Phase 3: Vulnerability Analysis

Cross-reference active recon results with Tier 3 sources:

**Nuclei template scanning** (nuclei-mcp — structured vuln scan from Kali):
- `basic_scan`: quick scan against target with default templates
- `nuclei_scan`: full scan with severity/template filters based on recon findings
  - Filter by severity: critical, high, medium based on target risk profile
  - Filter by template tags matching identified services (e.g. apache, nginx, ssh)
- `list_templates` / `get_template`: review available templates before scanning
- Nuclei complements tuoni `vuln-assess` plugin: nuclei scans FROM Kali, plugin runs ON target

**BloodHound AD path analysis** (bloodhound-mcp — AD environments only):
- Query shortest paths from compromised user to high-value targets (DA, EA)
- Identify kerberoastable accounts on attack paths
- Detect NTLM relay opportunities and delegation abuse chains
- Map certificate services (ADCS) vulnerabilities
- Example NL queries: "shortest path from kerberoastable to DA",
  "find NTLM relay-vulnerable DCs", "show delegation abuse paths"

**CVE enrichment pipeline** (cve-mcp — run for each identified service version):
- `cve_by_product`: search CVEs by product name + version from Providentia/recon
- `cve_enrich`: full enrichment for top CVE candidates (NVD + EPSS + KEV + exploits)
- `cve_prioritize`: rank multiple CVEs by exploitation risk
- `kev_check`: flag CVEs in Known Exploited Vulnerabilities catalog
- `exploit_search`: check public exploit availability across sources

**Technique research** (use efficient tool workflows):
- HackTricks: `hacktricks_quick_lookup` for first-pass, then `search→outline→section` for depth
- MITRE: `search_techniques` + `get_technique` for IDs and detection info
- lolbins-mcp: `analyze_environment` if enumeration data available, then `discover_chains`
- `analyze_opsec_risk`: assess detection risk for each candidate technique

**OPSEC: opsec-exploit-hygiene** — flag any Metasploit modules as
REFERENCE ONLY. Extract technique, note for custom implementation.
Use `cve-mcp msf_check` + `nuclei_check` to verify module existence for technique research.

### Phase 4: Target Assessment

Produce ranked attack vector list:
1. Vector name + technique ID + CVE (if applicable)
2. Likelihood of success (from EPSS score, KEV status, prior findings, config analysis)
3. Stealth rating (from `lolbins analyze_opsec_risk`, MITRE `get_data_sources` — if mitre-mcp unavailable, rely on lolbins OPSEC score + HackTricks detection notes)
4. Prerequisites (creds needed? auth required? adjacent access?)

Present to operator for initial-access skill handoff.

## Thread Orchestration

**Recon runs as a SEPARATE thread from exploitation.** Do not combine recon
and initial-access in one thread. Recon thread produces Obsidian target page.
Master reviews. Separate initial-access thread consumes it.

This prevents threads from shortcutting research to jump to credential testing.

## Exit criteria

- Target profile complete (all Tier 1 sources queried)
- Active recon results documented (Phase 2 service:version table)
- Per-service CVE research complete (Phase 3 — ALL services, not just first one)
- Attack vectors ranked with PoC details (not just CVE numbers)
- Obsidian target page fully populated (services, CVEs, vectors, PoCs)
- Engagement YAML updated: phase=recon, status only (detail in Obsidian)
- `/log-finding` invoked for each significant recon result

## State writes

**Obsidian is primary output** (shared state between threads).
**Engagement YAML is lean** — phase status + refs only.

```yaml
# engagement.yaml — LEAN, status only
targets:
  - hostname: <target>
    phase: recon
    status: complete
    wiki_page: llm-wiki/wiki/targets/<hostname>.md
```

### Obsidian writes (llm-wiki paths — ENFORCED)

After Phase 2 (active recon) completes, invoke `/log-finding` for each
significant result. This auto-writes to correct llm-wiki paths:

- `llm-wiki/raw/<hostname>-recon-<date>.md` — immutable scan dump
- `llm-wiki/wiki/targets/<hostname>.md` — structured target page
  (uses template: `llm-wiki/templates/target.md`)
- `llm-wiki/wiki/techniques/<technique>.md` — if technique page needed
- `llm-wiki/log.md` — changelog entry appended

Manual fallback (if `/log-finding` unavailable):
- `obsidian_create_note` to `llm-wiki/raw/` with frontmatter `tags: [raw, intake]`
- `obsidian_create_note` or `obsidian_edit_note` to `llm-wiki/wiki/targets/`
  using field structure from `llm-wiki/templates/target.md`

## Degraded Mode (Router-Only Active Recon)

When `degraded_mode: router-only` is set in engagement YAML (no Kali spoke):

**Phase 2 alternative — active recon from router agents:**
- Port scanning: Python socket `connect_ex` via Tuoni agent commands.
  Scan top 100 ports per target. Do NOT use bash `/dev/tcp` (false negatives).
- Web fingerprint: `curl -sk` for HTTP headers, status codes, server banners
- Banner grab: Python socket `recv` after TCP connect to open ports
- Service detection: infer from port + banner (no nmap service detection)

**Limitations in degraded mode:**
- No nmap: service version detection unreliable, OS fingerprint unavailable
- No UDP scanning: only TCP ports discoverable
- No vulnerability scanning: cannot run Nuclei/nikto from router
- Slower: sequential Python socket connections vs nmap parallel scanning

**Phase 2 output format remains the same.** Mark recon as `degraded` in
engagement YAML to indicate reduced confidence.

## Prior Engagement Knowledge Retrieval

Before starting Phase 2 active recon, check llm-wiki for prior engagement
data on targets:

1. Search `obsidian_search_vault` for `#target/<hostname>`
2. If prior target page exists: read exhausted vectors, known ports, failed
   techniques
3. Skip techniques already marked `#result/failed` on same target (unless
   operator overrides)
4. Prioritize techniques marked `#result/partial` (may succeed with different
   approach)

## Failure modes

- **Providentia unreachable**: warn operator, proceed with cached data or
  README only. Never proceed with NO authoritative source.
- **Kali spoke unreachable**: passive recon only (Tier 1+2). Cannot do
  active recon without weapons platform. If `degraded_mode: router-only`,
  use degraded active recon above.
- **Target not in Providentia**: warn operator — target may not exist on
  range. Require explicit confirmation before proceeding.
- **Prior engagement shows all vectors exhausted**: report to operator.
  Recommend: different source IP, different timing, or target deprioritization.
