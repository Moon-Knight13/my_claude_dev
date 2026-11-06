# New MCP Integration Map: BloodHound, Hashcat, Nuclei

**Date:** 2026-11-06
**Mode:** red-dev (architecture analysis, read-only)
**Status:** Planning document — no code changes

---

## 1. Data Flow Diagram

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        ENGAGEMENT WORKFLOW CYCLE                        │
│                                                                         │
│  ┌──────────┐    ┌───────────────┐    ┌──────────────┐    ┌──────────┐ │
│  │  RECON   │───▶│ INITIAL ACCESS│───▶│  DISCOVERY   │───▶│CRED HARV.│ │
│  └────┬─────┘    └──────┬────────┘    └──────┬───────┘    └────┬─────┘ │
│       │                 │                    │                  │       │
│       │                 ▼                    │                  ▼       │
│       │          ┌──────────────┐            │          ┌──────────────┐│
│       │          │ PERSIST-SWARM│            │          │ LATERAL MOVE ││
│       │          └──────────────┘            │          └──────┬───────┘│
│       │                                      │                 │       │
│       └──────────────────┬───────────────────┴─────────────────┘       │
│                          ▼                                             │
│                  ┌───────────────┐                                      │
│                  │   REPORTING   │                                      │
│                  └───────────────┘                                      │
└─────────────────────────────────────────────────────────────────────────┘

Data sources feeding each phase:

RECON PHASE
  range-intel ──────────────────────────┐
  outline-readonly ─────────────────────┤
  obsidian-mcp ─────────────────────────┤
  tuoni-mcp (discovery hosts) ──────────┤
  ★ bloodhound-mcp (AD paths) ─────────┤──▶ Target profile + attack vectors
  ★ nuclei-mcp (vuln scan) ────────────┤
  cve-mcp ──────────────────────────────┤
  hacktricks-mcp ───────────────────────┤
  mitre-mcp ────────────────────────────┤
  lolbins-mcp ──────────────────────────┘

INITIAL ACCESS PHASE
  recon output ─────────────────────────┐
  ★ bloodhound-mcp (attack paths) ─────┤──▶ Technique selection + exploitation
  hacktricks-mcp ───────────────────────┤
  cve-mcp ──────────────────────────────┤
  lolbins-mcp ──────────────────────────┘

CRED HARVEST PHASE
  tuoni-mcp (agent commands) ───────────┐
  hacktricks-mcp ───────────────────────┤
  lolbins-mcp ──────────────────────────┤──▶ Creds stored in Tuoni
  ★ hashcat-mcp (hash crack) ──────────┤
  ★ bloodhound-mcp (kerberoast SPNs) ──┘

LATERAL MOVE PHASE
  tuoni-mcp (cred store + agents) ──────┐
  range-intel (topology) ───────────────┤──▶ Movement to next target
  ★ bloodhound-mcp (shortest paths) ───┤
  lolbins-mcp ──────────────────────────┘

REPORTING (all phases)
  obsidian-mcp (llm-wiki notes) ────────┐
  engagement-state (YAML) ──────────────┤──▶ /log-finding + MITRE notes
  ★ auto-log-finding hook (expanded) ───┘

★ = new MCP integration point
```

---

## 2. Per-MCP Integration Tables

### 2.1 bloodhound-mcp

| Aspect | Detail |
|--------|--------|
| **Phases served** | Recon (Tier 2 + Phase 3), Initial Access (Phase 1), Lateral Move (Phase 1), Discovery (AD enrichment) |
| **Prerequisite** | bloodhound-python collection data loaded into Neo4j from a compromised host |
| **Environment gate** | AD environments only — skip on pure Linux/network-device ranges |

**Data flows IN:**

| Source | Data | When |
|--------|------|------|
| range-intel (`range_host`) | Domain membership, DC identification | Recon Phase 1 — identify AD environment |
| tuoni-mcp (`tuoni_agents_list`) | Compromised users/hosts | Query "shortest path FROM compromised user" |
| cred-harvest (tuoni cred store) | Harvested accounts | Query paths FROM newly compromised accounts |
| engagement-state YAML | Approved targets, scope | Filter path results to in-scope targets |

**Data flows OUT:**

| Destination | Data | When |
|-------------|------|------|
| initial-access skill | Kerberoastable SPNs, delegation abuse chains, ADCS vectors (ESC1-8), NTLM relay targets | Phase 1 technique research — prioritize vectors |
| cred-harvest skill | SPNs to kerberoast, accounts on attack paths | Phase 3 targeting — which accounts to harvest |
| lateral-move skill | Shortest path to target, intermediate hop hosts | Phase 1 target selection — optimal movement path |
| engagement-state YAML | AD attack paths as findings | Record explored/exploited paths |
| obsidian-mcp | Attack path documentation | `llm-wiki/wiki/ad-paths/<domain>.md` |
| /log-finding | Each significant path discovery | Per finding |

**Interaction with tuoni-mcp:**
- Consumes: agent list (which users/hosts compromised) to parameterize path queries
- Does NOT directly feed tuoni — intermediate skills (initial-access, lateral-move) consume bloodhound output and then use tuoni for execution

**Interaction with engagement-state:**
- New YAML fields needed (see section 4)
- AD paths tracked as findings with `technique_id: T1087.002` (Account Discovery: Domain Account) and related
- Kerberoastable SPN list tracked for cred-harvest targeting

**Obsidian interaction:**
- New template: `ad-path.md` (attack path documentation)
- Findings go to existing target pages under new `## AD Attack Paths` section
- Domain overview page: `llm-wiki/wiki/ad-paths/<domain>.md`

---

### 2.2 hashcat-mcp

| Aspect | Detail |
|--------|--------|
| **Phases served** | Cred Harvest (Phase 1 research, Phase 3.5 auto-crack, Phase 4 storage, Phase 5 spray planning) |
| **Prerequisite** | Hashcat + GPU available on Kali spoke |
| **Environment gate** | None — any engagement with recoverable hashes |

**Data flows IN:**

| Source | Data | When |
|--------|------|------|
| cred-harvest (tuoni agent) | Raw hashes (NTLM, NTLMv2, Kerberos TGS, NetNTLMv2, etc.) | Phase 3 yields crackable hashes |
| bloodhound-mcp | Kerberoasted TGS hashes (via cred-harvest) | After kerberoasting accounts identified by bloodhound |
| engagement-state YAML | Hash type context, source host | Metadata for crack session tracking |

**Data flows OUT:**

| Destination | Data | When |
|-------------|------|------|
| tuoni-mcp (`tuoni_credential_add`) | Cracked plaintext passwords | Phase 4 — store cracked creds immediately |
| lateral-move skill | Usable credentials (via tuoni cred store) | Cracked creds enable new lateral moves |
| cred-harvest Phase 5 | Password pattern analysis (`analyze_cracked_passwords`) | Spray planning — common patterns, seasonal, company-name based |
| engagement-state YAML | Crack session status, results summary | Track active/completed sessions |
| obsidian-mcp | Crack results (NO plaintext — stats only) | `llm-wiki/wiki/targets/<host>.md` cred refs section |
| /log-finding | Each successful crack batch | Per significant result |

**Interaction with tuoni-mcp:**
- Indirect consumer: hashes come FROM tuoni agent commands (via cred-harvest skill)
- Direct producer: cracked passwords stored TO tuoni cred store
- Flow: tuoni agent → cred dump → hashes → hashcat crack → plaintext → `tuoni_credential_add`

**Interaction with engagement-state:**
- New YAML fields needed (see section 4)
- Crack sessions tracked: hash count, mode, status, cracked count
- Credential refs updated when cracks succeed

**Obsidian interaction:**
- NO new template needed — uses existing credential.md template
- Results documented as stats only (N hashes cracked, patterns found)
- NEVER write plaintext passwords to Obsidian (existing RT cred storage rules apply)

**OPSEC note:** `analyze_cracked_passwords` output contains password patterns but not raw passwords. Safe for Obsidian logging as spray-planning intelligence.

---

### 2.3 nuclei-mcp

| Aspect | Detail |
|--------|--------|
| **Phases served** | Recon (Phase 3 vuln analysis), Initial Access (Phase 1 vector identification) |
| **Prerequisite** | Nuclei binary on Kali spoke |
| **Environment gate** | None — scans any target with network services |

**Data flows IN:**

| Source | Data | When |
|--------|------|------|
| range-intel (`range_host`) | Target IP, exposed services, versions | Template selection — filter by service tags |
| recon Phase 2 (tuoni/Kali) | Active recon results — open ports, service fingerprints | Refine template selection based on actual vs expected |
| engagement-state YAML | Approved targets | Scan scope enforcement (RT-TGT-001) |
| tuoni-mcp (SOCKS proxy) | Proxy chain for internal targets | Route scans through footholds |

**Data flows OUT:**

| Destination | Data | When |
|-------------|------|------|
| initial-access skill | Confirmed vulnerabilities with severity, CVE IDs | Phase 1 — prioritize proven vulns over theoretical |
| cve-mcp (`cve_enrich`) | CVE IDs from nuclei findings | Enrich nuclei results with EPSS, KEV, exploit availability |
| recon Phase 4 | Ranked vuln list contributing to attack vector assessment | Feed target assessment |
| engagement-state YAML | Scan results as findings | Track what was scanned and found |
| obsidian-mcp | Vuln scan results | `llm-wiki/raw/<host>-nuclei-<date>.md` + target page update |
| /log-finding | Each critical/high finding | Per significant vuln |

**Interaction with tuoni-mcp:**
- Nuclei runs FROM Kali (not through tuoni agents on target)
- Tuoni provides SOCKS proxy when scanning internal targets behind footholds
- Complementary to tuoni `vuln-assess` plugin: nuclei scans FROM Kali, plugin runs ON target
- Different coverage: nuclei = network-layer HTTP/service vulns; vuln-assess = local config/patch analysis

**Interaction with engagement-state:**
- New YAML fields needed (see section 4)
- Scan results tracked: target, template set, findings by severity
- CVEs discovered feed into technique tracking

**Obsidian interaction:**
- Raw scan output: `llm-wiki/raw/<host>-nuclei-<date>.md` (immutable intake)
- Target page update: `llm-wiki/wiki/targets/<host>.md` under `## Vulnerability Scan Results`
- New template: `vuln-scan.md` for structured scan result pages
- Tag: `#tool/nuclei`, `#phase/recon`

---

## 3. Skill Update Plan

### 3.1 recon skill

**Current state:** Already references bloodhound-mcp (Tier 2, Phase 3) and nuclei-mcp (Tier 3, Phase 3). These sections exist in the skill text.

**Changes needed:**

| Change | Priority | Detail |
|--------|----------|--------|
| BloodHound data collection guidance | P1 | Add instructions: when BH data not loaded, guide operator through bloodhound-python collection from compromised host before BH queries work |
| Nuclei scan orchestration | P1 | Add `nuclei_scan` workflow to Phase 3: select templates by service tags from Phase 2 results, filter severity by target risk profile |
| Nuclei → cve-mcp pipeline | P2 | After nuclei finds CVEs, auto-feed to `cve_enrich` for full enrichment |
| BloodHound → lateral-move handoff | P2 | Phase 4 assessment: include AD attack paths in ranked vector list with prerequisite annotations |
| Template selection heuristic | P3 | Map service fingerprints to nuclei template tags (e.g. nginx → `tags: nginx`, SMB → `tags: smb`) |

### 3.2 initial-access skill

**Current state:** Already references bloodhound-mcp in Phase 1 (step 0b).

**Changes needed:**

| Change | Priority | Detail |
|--------|----------|--------|
| Nuclei-confirmed vuln prioritization | P1 | If nuclei already confirmed a CVE on target, promote it above theoretical vectors |
| BloodHound prerequisite tracking | P2 | When BH suggests kerberoasting path, verify cred-harvest can fulfill before committing |
| Nuclei template-to-exploit mapping | P3 | Map nuclei template IDs to exploitation technique (many templates test but don't exploit) |

### 3.3 cred-harvest skill

**Current state:** Already references hashcat-mcp in Phase 1 and Phase 3.5.

**Changes needed:**

| Change | Priority | Detail |
|--------|----------|--------|
| hashcat session tracking in YAML | P1 | After `crack_hash`, record session ID in engagement state for long-running jobs |
| BloodHound kerberoast targeting | P1 | Before generic kerberoasting, query BH for SPNs on shortest paths — crack those first |
| hashcat `get_session_status` polling guidance | P2 | For long-running cracks: poll interval, when to move on, background crack strategy |
| `analyze_cracked_passwords` → spray plan | P2 | Formalize: crack results pattern analysis feeds directly into Phase 5 spray planning |
| BloodHound AS-REP roast targeting | P3 | Query BH for accounts without preauth — supplement kerberoast targets |

### 3.4 lateral-move skill

**Current state:** Does NOT reference bloodhound-mcp.

**Changes needed:**

| Change | Priority | Detail |
|--------|----------|--------|
| BloodHound path-driven target selection | P1 | Phase 1: query BH for shortest path from current access to high-value targets (DA, EA, specific servers). Select targets along optimal path, not just by Providentia topology. |
| BloodHound intermediate hop identification | P1 | When BH shortest path goes A→B→C, lateral-move must chain: move to B first, then C |
| Credential-to-path matching | P2 | Cross-reference tuoni cred store against BH paths: "cred X unlocks hop Y on path to Z" |
| AD trust traversal guidance | P3 | BH cross-domain paths: when path crosses trust boundary, adjust proxy + credential strategy |

### 3.5 discovery skill

**Current state:** Does NOT reference bloodhound-mcp, hashcat-mcp, or nuclei-mcp.

**Changes needed:**

| Change | Priority | Detail |
|--------|----------|--------|
| BloodHound collection trigger | P1 | After persistence confirmed on AD-joined host: run bloodhound-python collector, ingest into Neo4j. This is the DATA COLLECTION step that enables all other BH queries. |
| Nuclei internal scan | P2 | After discovery, if new web services found, run nuclei from foothold (via SOCKS) against internal services not reachable from Kali |
| Hash extraction → hashcat handoff | P2 | When cred sources identified (Step 3), explicitly note hash types and pre-query `search_hash_types` for crack feasibility |

### 3.6 persist-swarm skill

**No changes needed.** Persist-swarm is mechanism-focused (beacon deployment). New MCPs don't interact with persistence directly.

### 3.7 engagement-state skill

**Changes needed:**

| Change | Priority | Detail |
|--------|----------|--------|
| Schema additions (see section 4) | P1 | New YAML fields for BH paths, hashcat sessions, nuclei scans |
| BloodHound data freshness tracking | P2 | Track when BH data was last collected, warn if stale (>24h during active engagement) |
| Cross-session hashcat resume | P2 | When resuming engagement with active hashcat sessions, check `get_session_status` |
| Nuclei scan dedup | P3 | Track what was scanned to prevent redundant re-scanning of same target/templates |

### 3.8 log-finding skill (/log-finding command)

**Changes needed:**

| Change | Priority | Detail |
|--------|----------|--------|
| BloodHound path findings | P1 | Accept BH attack path as finding type. Map to MITRE T1087 (Account Discovery), T1069 (Permission Groups Discovery), T1482 (Domain Trust Discovery) as appropriate |
| Nuclei vuln findings | P1 | Accept nuclei scan results as finding type. Auto-extract CVE, severity, template ID |
| Hashcat crack findings | P2 | Accept crack results as finding type. Log stats only (N cracked of M, patterns), NEVER plaintext |
| Tool tag in Obsidian | P2 | Add `#tool/<mcp-name>` tag for provenance tracking |

---

## 4. Engagement-State Schema Changes

New fields to add to `engagements/<id>.yaml`:

```yaml
# ── NEW: BloodHound AD intelligence ──
ad_intelligence:
  domain: <domain name>
  collection_source: <hostname where bloodhound-python ran>
  collected_at: <ISO 8601>
  data_stale: false  # set true if >24h old
  paths_explored:
    - from: <compromised user/host>
      to: <target (DA, EA, specific host)>
      hops: <number>
      path: [<node1>, <node2>, ...]
      status: identified | in_progress | exploited | blocked
      technique_refs: [<technique_id references>]
  kerberoastable_spns:
    - spn: <SPN string>
      account: <sAMAccountName>
      on_path_to: <target if on shortest path>
      status: identified | roasted | cracked
      cred_ref: <tuoni_cred_id if cracked>
  delegation_abuse:
    - type: unconstrained | constrained | rbcd
      source: <host/account>
      target: <exploitable target>
      status: identified | exploited
  adcs_vectors:
    - template: <cert template name>
      esc_type: ESC1 | ESC2 | ... | ESC8
      status: identified | exploited

# ── NEW: Hashcat crack sessions ──
hashcat_sessions:
  - session_id: <hashcat session name>
    target_host: <source of hashes>
    hash_type: <hashcat mode number>
    hash_type_name: <human readable>
    hash_count: <total hashes>
    cracked_count: <cracked so far>
    status: running | completed | exhausted | paused
    started_at: <ISO 8601>
    completed_at: <ISO 8601 | null>
    attack_type: dictionary | mask | rules | combinator
    cred_refs: [<tuoni_cred_ids for cracked passwords>]
    patterns_found: <summary from analyze_cracked_passwords>

# ── NEW: Nuclei vulnerability scans ──
vuln_scans:
  - target: <hostname or IP>
    scan_type: basic | filtered | full
    templates_used: <tag filter or "default">
    scanned_at: <ISO 8601>
    findings:
      critical: <count>
      high: <count>
      medium: <count>
      low: <count>
      info: <count>
    cves_found: [<CVE-IDs>]
    fed_to_initial_access: true | false
```

**Existing fields to extend:**

```yaml
# credentials[] — add crack provenance
credentials:
  - ref_id: <slug>
    tuoni_cred_id: <id>
    type: password | hash | ticket | key | token
    username: <user>
    domain: <domain>
    source_host: <host>
    source_technique: <technique>
    # NEW fields:
    cracked_from: <hashcat_session_id | null>  # link to hashcat session
    on_attack_path: true | false                # identified by bloodhound

# findings[] — add tool provenance
findings:
  - id: <slug>
    target: <host>
    technique_id: <MITRE ID>
    technique_name: <name>
    result: success | partial | failed | blocked
    timestamp: <ISO 8601>
    # NEW field:
    source_tool: tuoni | bloodhound | hashcat | nuclei | manual
```

---

## 5. Obsidian Note Template Additions

### 5.1 New template: `llm-wiki/templates/ad-path.md`

```markdown
---
tags: [wiki, ad-path, engagement]
domain: {{domain}}
collected_at: {{date}}
---

# AD Attack Path: {{domain}}

## Collection Info
- **Source host:** {{collection_host}}
- **Collector:** bloodhound-python
- **Date:** {{date}}
- **Data freshness:** current | stale

## Shortest Paths to DA
{{paths}}

## Kerberoastable Accounts
| Account | SPN | On Attack Path | Status |
|---------|-----|----------------|--------|
{{kerberoastable_rows}}

## Delegation Abuse Vectors
{{delegation_vectors}}

## ADCS Vectors
{{adcs_vectors}}

## NTLM Relay Opportunities
{{ntlm_relay}}

## Exploitation Log
{{exploitation_entries}}
```

### 5.2 New template: `llm-wiki/templates/vuln-scan.md`

```markdown
---
tags: [wiki, vuln-scan, engagement]
target: {{hostname}}
scanner: nuclei
scanned_at: {{date}}
---

# Vulnerability Scan: {{hostname}}

## Scan Configuration
- **Scanner:** Nuclei
- **Templates:** {{template_filter}}
- **Scan type:** {{basic|filtered|full}}

## Findings by Severity
| Severity | Count | Notable |
|----------|-------|---------|
| Critical | {{n}} | {{details}} |
| High     | {{n}} | {{details}} |
| Medium   | {{n}} | {{details}} |
| Low      | {{n}} | {{details}} |

## CVEs Identified
{{cve_list}}

## Fed to Initial Access
{{whether findings were passed to initial-access skill}}

## Raw Output Reference
→ `llm-wiki/raw/{{hostname}}-nuclei-{{date}}.md`
```

### 5.3 Existing template updates

**`llm-wiki/templates/target.md`** — add sections:

```markdown
## AD Attack Paths
{{if AD environment: paths from/to this host, link to ad-path page}}

## Vulnerability Scan Results
{{nuclei findings summary, link to vuln-scan page}}

## Hash Cracking Results
{{stats only: N of M cracked, patterns, NO plaintext — link to cred refs}}
```

**`llm-wiki/templates/credential.md`** — add field:

```markdown
- **Cracked from session:** {{hashcat_session_id | "direct recovery"}}
- **On attack path:** {{yes/no — from bloodhound analysis}}
```

### 5.4 New Obsidian tags

| Tag | When |
|-----|------|
| `#tool/bloodhound` | Any note with bloodhound-sourced data |
| `#tool/hashcat` | Any note with hashcat results |
| `#tool/nuclei` | Any note with nuclei scan results |
| `#ad/kerberoast` | Kerberoasting findings |
| `#ad/delegation` | Delegation abuse findings |
| `#ad/adcs` | ADCS certificate abuse findings |

---

## 6. auto-log-finding Hook Expansion Plan

### Current state

Hook watches ONE tool:
```
matcher: "mcp__tuoni-mcp__tuoni_command_get"
```

Pattern matching: regex for credentials, host discovery, access gained, service enumeration, sensitive files, lateral movement indicators in tuoni command output.

### Expansion options

**Option A: Add matchers for new MCPs (RECOMMENDED)**

Add three new PostToolUse hook entries in `.claude/settings.json`:

```json
{
  "matcher": "mcp__bloodhound-mcp__*",
  "hooks": [{
    "type": "command",
    "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/auto-log-finding-bloodhound.sh"
  }]
},
{
  "matcher": "mcp__hashcat-mcp__crack_hash",
  "hooks": [{
    "type": "command",
    "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/auto-log-finding-hashcat.sh"
  }]
},
{
  "matcher": "mcp__hashcat-mcp__crack_multiple_hashes",
  "hooks": [{
    "type": "command",
    "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/auto-log-finding-hashcat.sh"
  }]
},
{
  "matcher": "mcp__nuclei-mcp__nuclei_scan",
  "hooks": [{
    "type": "command",
    "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/auto-log-finding-nuclei.sh"
  }]
},
{
  "matcher": "mcp__nuclei-mcp__basic_scan",
  "hooks": [{
    "type": "command",
    "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/auto-log-finding-nuclei.sh"
  }]
}
```

**Per-MCP hook scripts:**

| Script | Triggers on | Detects |
|--------|-------------|---------|
| `auto-log-finding-bloodhound.sh` | Any bloodhound query result | Attack paths found, kerberoastable SPNs, delegation abuse, ADCS vectors |
| `auto-log-finding-hashcat.sh` | `crack_hash`, `crack_multiple_hashes` results | Cracked passwords (log stat: "N cracked", NEVER plaintext) |
| `auto-log-finding-nuclei.sh` | `nuclei_scan`, `basic_scan` results | Critical/high severity findings, CVE matches |

**Why separate scripts per MCP:**
- Different output formats require different pattern matchers
- Tuoni outputs raw command text; new MCPs return structured JSON
- OPSEC: hashcat hook MUST strip plaintext passwords before notification
- Easier to maintain and test independently

**Option B: Single unified hook with tool-name routing**

Single `auto-log-finding-unified.sh` that reads tool name from hook input and routes internally. Simpler config, harder to maintain.

**Recommendation: Option A.** Separate scripts. Each MCP has different output format and OPSEC requirements. The hashcat hook in particular MUST NOT leak plaintext into hook output.

### Hook detection patterns per MCP

**bloodhound-mcp:**
```
- "shortest path" / "attack path" → log AD path finding
- "kerberoastable" / "SPN" → log kerberoast target
- "delegation" / "unconstrained" / "constrained" / "RBCD" → log delegation abuse
- "ESC1" through "ESC8" / "ADCS" / "certificate" → log ADCS vector
- "NTLM relay" → log relay opportunity
```

**hashcat-mcp:**
```
- "cracked" / "recovered" → log crack result (COUNT only)
- "session complete" / "exhausted" → log session end
- STRIP: any field matching password/plaintext patterns before notification
```

**nuclei-mcp:**
```
- severity: "critical" or "high" → log immediately
- "CVE-" pattern → log CVE finding
- severity: "medium" → log if count > 5 (batch)
- severity: "low"/"info" → do not trigger (noise)
```

---

## 7. Priority Order for Implementation

### Phase 1 — Foundation (implement first)

| # | Task | Effort | Rationale |
|---|------|--------|-----------|
| 1.1 | engagement-state schema additions (section 4) | S | All other changes write to these fields |
| 1.2 | Obsidian templates: `ad-path.md`, `vuln-scan.md` | S | Templates needed before log-finding can write structured pages |
| 1.3 | Update `target.md` template with new sections | S | Existing template needs AD/vuln/hashcat sections |
| 1.4 | Update `/log-finding` command to accept BH/nuclei/hashcat finding types | M | Core logging pipeline must handle new data |

### Phase 2 — Skill integration (core workflow)

| # | Task | Effort | Rationale |
|---|------|--------|-----------|
| 2.1 | lateral-move: add BloodHound path-driven target selection | M | Highest-impact: BH attack paths directly improve lateral targeting |
| 2.2 | cred-harvest: add BH kerberoast targeting + hashcat session tracking | M | Direct cred-harvest improvement: target the right SPNs, track cracks |
| 2.3 | discovery: add BH collection trigger on AD-joined hosts | M | BH data collection is prerequisite for all BH queries |
| 2.4 | recon: add nuclei scan orchestration with template selection | M | Nuclei vuln scan feeds initial-access with confirmed vulns |

### Phase 3 — Hook expansion (automation)

| # | Task | Effort | Rationale |
|---|------|--------|-----------|
| 3.1 | Write `auto-log-finding-bloodhound.sh` | S | Auto-detect BH findings |
| 3.2 | Write `auto-log-finding-hashcat.sh` (with OPSEC plaintext stripping) | M | Auto-detect crack results, critical OPSEC for plaintext |
| 3.3 | Write `auto-log-finding-nuclei.sh` | S | Auto-detect vuln findings |
| 3.4 | Add hook matchers to settings.json | S | Wire hooks into PostToolUse |

### Phase 4 — Refinement (nice to have)

| # | Task | Effort | Rationale |
|---|------|--------|-----------|
| 4.1 | initial-access: nuclei-confirmed vuln prioritization | S | Promote proven vulns over theoretical |
| 4.2 | cred-harvest: `analyze_cracked_passwords` → spray plan formalization | S | Better spray targeting from crack patterns |
| 4.3 | discovery: nuclei internal scan via SOCKS | S | Scan internal services not reachable from Kali |
| 4.4 | engagement-state: BH data freshness tracking + nuclei scan dedup | S | Prevent stale data and redundant scans |
| 4.5 | Obsidian tag additions (`#tool/*`, `#ad/*`) | S | Better cross-engagement knowledge retrieval |

### Effort key
- **S** = small — single file edit, <30 min
- **M** = medium — multi-section skill rewrite, 1-2 hours

### Dependency graph

```
1.1 (schema) ──┬──▶ 2.1 (lateral-move BH)
               ├──▶ 2.2 (cred-harvest BH+hashcat)
               ├──▶ 2.3 (discovery BH collection)
               └──▶ 2.4 (recon nuclei)

1.2 (templates) ─┬──▶ 1.4 (log-finding update)
1.3 (target.md) ─┘         │
                            ▼
                    3.1-3.4 (hooks)
                            │
                            ▼
                    4.1-4.5 (refinement)
```

Phase 1 items are parallelizable (no dependencies between them).
Phase 2 items are parallelizable (each skill is independent).
Phase 3 depends on Phase 1.4 (log-finding must understand new types).
Phase 4 depends on Phase 2 (skills must exist before refinement).

---

## Appendix: MCP Connection Status (2026-11-06)

| MCP | Status | Note |
|-----|--------|------|
| bloodhound-mcp | CONNECTION_CLOSED | Configured but failed to connect this session |
| hashcat-mcp | Connected | Tools loaded and available |
| nuclei-mcp | CONNECTION_CLOSED | Configured but failed to connect this session |

Both BH and nuclei need connection fixes before operational use. Hashcat is ready.
Skills already reference all three MCPs in their text — the integration points are documented in skill files but untested against live MCP responses. Validate tool output formats when connections stabilize.
