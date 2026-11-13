---
name: recon
description: "Phase-based reconnaissance skill for red-team and purple modes. Queries authoritative sources first (Providentia, GitLab READMEs, wiki collections), then reference MCPs. Use when operator says 'recon', 'target', 'research <hostname>', or starts an engagement."
modes: [red-team, purple, ctf]
---

# Recon Skill — Source-Priority Phased Reconnaissance

## When to use

Operator asks to research a target, start an engagement, or perform recon.
Active in: **red-team**, **purple**, **ctf** modes.

## Entry criteria

- Mode is red-team, purple, or ctf
- Operator has named a target (hostname, IP, or role description)
- Engagement YAML exists or will be created

## Black-Box Engagement Handling

When engagement YAML has `type: black-box`:
- **Skip Tier 1 entirely** — no Providentia, GitLab, or Outline queries
- **Enter Blind Mode immediately** — do not wait for empty responses
- Set `intel_source: blind_scan` on engagement page at start
- Proceed directly to Blind Recon Pipeline (network discovery → service scan → research)
- All downstream output format identical — consuming skills do not care about source

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

## Blind Mode (Providentia Unavailable / Empty / Black-Box)

Activates automatically when:
- Providentia returns empty results for all queried hosts
- range-intel MCP is unreachable or errors
- Operator provides CIDR/range without pre-cached intel (CTF, pentest, ad-hoc)
- **Engagement YAML has `type: black-box`** — immediate activation, no Tier 1 queries attempted

**Detection:** When `type: black-box`, enter blind mode immediately without
querying Tier 1. Otherwise, after Tier 1 queries, if Providentia returned zero
hosts AND GitLab READMEs returned nothing, enter blind mode. Log to Obsidian
engagement page: `intel_source: blind_scan`.

### Blind Recon Pipeline

Replaces Tier 1 authoritative data with live scanning. All downstream output
format stays identical — skills consuming Obsidian target pages do not care
whether data came from Providentia or blind scanning.

**Step 1: Network discovery**
- `nmap -sn <CIDR>` sweep of operator-provided range(s)
- If no CIDR given: ask operator for target range. Do not guess.
- Output: list of live IPs

**Step 2: Service scan**
- `nmap -sV -sC -p- <host>` per live host (full port scan + versions)
- For large ranges (>50 hosts): `nmap -sV -sC --top-ports 1000` first pass,
  full `-p-` on high-value hosts only
- Output: service:version table per host

**Step 3: Per-service research** (replaces Providentia+README enrichment)
- For each service:version found:
  - `cve_by_product` (cve-mcp) → find CVEs for exact product+version
  - `cve_enrich` (cve-mcp) → full enrichment for HIGH/CRITICAL CVEs
  - `exploit_search` (cve-mcp) → public exploit availability
  - `search_hacktricks` (hacktricks-mcp) → attack techniques by service+version
  - `nuclei_scan` (nuclei-mcp) → template-based vuln scan, if available
- This step produces equivalent data to what Providentia+README would give

**Step 4: Write results to Obsidian** (SAME format as Providentia-enriched)
- Per host → `llm-wiki/wiki/targets/<hostname-or-ip>.md`
  - Use IP as identifier when hostname unknown
  - `## Services` section: full service:version table from nmap
  - `## Attack Vectors` section: CVE research results
- Engagement page → `## Reachability` matrix (all hosts, status)
- Raw dump → `llm-wiki/raw/blind-scan-<date>.md`
- Frontmatter includes `intel_source: blind_scan` (not `providentia`)

**Step 5: Continue to normal phases**
- Phase 1 (passive recon) queries remaining Tier 2+3 sources as usual
- Phase 2 reads Obsidian — data is there regardless of source
- Phase 3 (vuln analysis) runs identically

### Blind Mode Constraints

- OS detection less reliable without Providentia — rely on nmap `-O` fingerprint
  and service banners
- No team/role metadata — treat all hosts as equal priority unless operator
  specifies
- No GitLab README deploy notes — service defaults unknown, test broader
  credential sets (still max 3-5 per service)
- Hostname may be unknown — use IP address as target identifier throughout

### Mixed Mode

If Providentia returns SOME hosts but not all discovered by scan:
- Providentia-known hosts: use Providentia data (authoritative)
- Scan-only hosts: use blind pipeline for those hosts
- Flag scan-only hosts as `intel_source: blind_scan` in Obsidian
- These are HIGH VALUE findings — undocumented hosts on the network

## Phases

### Phase 0: Reachability + Service Enumeration (ONE SCAN, ONCE)

**Run ONCE per engagement start, from Kali self-agent.** Combines reachability
check AND full service enumeration in a single pass. Results go to Obsidian.
No subsequent phase re-scans — all later threads READ Obsidian instead.

Do not skip this phase. Do not assume Providentia IPs are routable.
ALL scanning from Kali — NEVER from hub.

**Step 1: Network position**
- `ip route`, `ip addr` on self-agent → routable subnets

**Step 2: Host discovery** (fast sweep)
- `nmap -sn <subnet> --min-rate 1000` per routable subnet
- Identifies live hosts without full port scan (OPSEC: minimal footprint)

**Step 3: Full service enumeration** (per live host)
- `nmap -sV -sC -p- <host>` → all ports + service versions + default scripts
- Also: `net-recon routing_recon` + `net-recon web_fingerprint` via tuoni plugins
- Capture: every open port, every service version string, every banner

**Step 4: Cross-reference with Providentia**
- Match responding hosts against `range_targets_summary`
- Categorize each Providentia host:
  - **REACHABLE** — responds, has service:version table
  - **FILTERED** — route exists but all ports filtered (firewall)
  - **UNREACHABLE** — no route or no response
  - **NOT_DEPLOYED** — Providentia lists it but tagged not_ready/no IP
- Flag discrepancies: services found but not in Providentia = HIGH VALUE

**Step 5: Write to Obsidian** (the ONLY place scan results live)
- Per reachable host → create/update `llm-wiki/wiki/targets/<hostname>.md`
  with `## Services` section containing full service:version table
- Engagement page → update `## Reachability` matrix
- Raw dump → `llm-wiki/raw/network-sweep-<date>.md`

**Step 6: Target selection**
- Only REACHABLE hosts with open ports proceed to research
- FILTERED hosts need pivot/firewall bypass first
- Master reviews, gets RT-TGT-001 approval for selected targets

**Re-run after lateral movement** opens new network segments — from new
foothold, not Kali. New hosts get same treatment: scan once, write to Obsidian.

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

### Phase 2: Verify Obsidian Data (NO RE-SCAN)

**Service enumeration already done in Phase 0.** This phase does NOT scan.
It reads the Obsidian target page `## Services` section and verifies data
is complete before proceeding to vulnerability analysis.

If target page `## Services` is missing or incomplete:
- Check if Phase 0 sweep covered this host
- If not covered (e.g., new target added after sweep): run ONE targeted
  `nmap -sV -sC -p- <host>` from Kali, write results to Obsidian
- If covered but data missing: re-read Obsidian page, may be write failure

**Output:** Confirmation that service:version table exists in Obsidian.
This table feeds Phase 3 vulnerability analysis.

### Phase 3: Vulnerability Analysis (writes to Obsidian — initial-access reads this)

Cross-reference active recon results with Tier 3 sources. **This phase does
the CVE/technique research.** Initial-access thread reads results from Obsidian
target page — it does NOT re-run this research unless the page is missing it.

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

- **Providentia unreachable**: activate Blind Mode (see above). Warn operator
  that intel source is scanning only. Proceed with blind recon pipeline.
  No longer blocks engagement — scanning replaces authoritative data.
- **Providentia returns empty**: same as unreachable — activate Blind Mode.
  Log `intel_source: blind_scan` on engagement page.
- **Kali spoke unreachable**: passive recon only (Tier 1+2). Cannot do
  active recon without weapons platform. If `degraded_mode: router-only`,
  use degraded active recon above.
- **Target not in Providentia**: if blind mode active, this is expected —
  all targets come from scanning. If Providentia IS available but target
  not found: warn operator, require explicit confirmation before proceeding.
- **Prior engagement shows all vectors exhausted**: report to operator.
  Recommend: different source IP, different timing, or target deprioritization.
