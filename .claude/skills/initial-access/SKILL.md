---
name: initial-access
description: "Guided initial access skill for red-team mode. Takes recon output, researches exploit techniques via reference MCPs, enforces OPSEC exploit hygiene (no Metasploit defaults), and stages custom exploitation from Kali."
---

# Initial Access Skill — OPSEC-Compliant Exploitation

## When to use

Operator ready to exploit a target after recon phase. Takes ranked attack
vectors from recon skill output or engagement YAML.

Active in: **red-team** mode only.

## Entry criteria

- Recon complete for target (Phase 4 assessment exists)
- Attack vectors ranked and operator-approved
- Target explicitly in scope (RT-TGT-001 confirmed)
- Engagement YAML has target entry with `phase: recon` or later

## OPSEC Rules — ENFORCED

### Exploit Hygiene (CRITICAL)

- **NO Metasploit modules** as deployment tools. Extract technique only.
- **NO public exploit scripts** run unmodified. Understand, adapt, custom-build.
- **NO tools uploaded to target** (RT-TGT-002). Run everything from Kali.
- Payload naming follows RT-SIG-003 (platform-appropriate cover names).
- Payload sizing follows RT-SIG-004 (Linux 1-5MB, Windows 120-180MB).
- Unique payload ID per target (RT-SIG-002).

### Identity

- All outbound connections use `root` agent (RT-SIG-001).
- No `rt`-prefixed usernames in any target-facing traffic.

## Phases

### Phase 1: Technique Research

For each operator-approved attack vector from recon:

0. **Range vuln profiles** (range-intel `range_vuln_lookup`): check if range-intel
   already has vulnerability data for this target before external research
1. **HackTricks** (hacktricks-mcp): use efficient workflow:
   - `hacktricks_quick_lookup` for first-pass exploitation overview
   - `search_hacktricks` → `get_hacktricks_outline` → `get_hacktricks_section` for depth
   - `get_hacktricks_cheatsheet` to extract all code blocks for adaptation
   - NEVER use `get_hacktricks_page` (3000-15000 tokens) when `get_hacktricks_section` suffices
2. **CVE intelligence** (cve-mcp) — full enrichment pipeline:
   - `cve_enrich`: NVD + EPSS + KEV + GHSA + Shodan + VulnCheck + Nuclei + MSF in parallel
   - `kev_check`: if in KEV catalog, actively exploited = high success probability
   - `exploit_search`: check for public exploits across multiple sources
   - `cve_to_attack`: map CVE's CWE to ATT&CK techniques (bridges to mitre-mcp)
   - `cve_prioritize`: when multiple CVEs found, rank by exploitation risk
3. **MITRE ATT&CK** (mitre-mcp): technique ID, sub-techniques, plus:
   - `get_data_sources`: what detection sources apply (OPSEC assessment)
   - `get_mitigations`: what defenses exist (predict failure, choose alternatives)
   - **Fallback if mitre-mcp unavailable**: use `cve_to_attack` (cve-mcp) for
     CWE→ATT&CK mapping, `lolbins analyze_opsec_risk` for detection assessment,
     and `hacktricks_quick_lookup` for mitigation/detection notes
4. **LOLBins OPSEC check** (lolbins-mcp `analyze_opsec_risk`): assess noise level
   and EDR trigger probability BEFORE executing any exploit
5. **Wiki vulns-docs** (outline-readonly): prior team research on this vuln
6. **Metasploit module** (if exists): READ for technique understanding ONLY.
   Extract: target verification method, payload delivery mechanism, post-exploit
   actions. Document what it does. Do NOT use it.

Present research summary to operator with:
- Technique name + MITRE ID
- Steps to reproduce (manual)
- Detection risk assessment
- Recommended custom implementation approach

### Phase 2: Payload Preparation

Build or configure payload on Kali (via tuoni-mcp agent commands):

1. **Select listener**: match target network position
   - Direct connect: target can reach C2
   - Reverse: target behind NAT/firewall
   - SOCKS: through existing foothold proxy
2. **Generate payload** (tuoni-mcp `tuoni_payload_create`):
   - Cover filename per RT-SIG-003
   - Padded to platform size per RT-SIG-004
   - Unique ID per RT-SIG-002
3. **Stage delivery mechanism** on Kali:
   - Web server for HTTP delivery
   - SMB share for Windows lateral
   - SCP for direct SSH access
4. **Verify payload**: test on similar non-target system if available

### Phase 3: Exploitation

Execute from Kali (NEVER from target):

1. **Pre-flight check**:
   - Confirm target IP matches Providentia record
   - Confirm target in approved scope
   - Confirm payload unique to this target
   - Confirm listener active and receiving

2. **Execute exploit**:
   - Run from Kali agent via tuoni-mcp
   - If using SSH tunnel: through existing foothold SOCKS proxy
   - Monitor for callback/connection

3. **Verify access**:
   - Agent check-in confirmed
   - Basic enumeration (whoami, hostname, network)
   - Compare actual vs expected (Providentia data)

### Phase 4: Post-Access Immediate Actions

**PERSIST-ON-LANDING RULE**: Before ANY other operation:

1. **Deploy persistence** — invoke `persist-swarm` skill (MANDATORY):
   - Operational beacon: short callback interval
   - Sleeper beacon: long callback interval (survival)
   - If persist-swarm skill fails: deploy manually, but DO NOT skip
2. **Discovery sweep** (tuoni-mcp agent commands):
   - Local users, groups, privileges
   - Network connections, routing table
   - Running services, scheduled tasks
   - Credential stores (location only — do not harvest yet)
3. **Update engagement YAML**:
   - Target phase: `initial_access`
   - Agent ID, access level
   - Persistence status
   - Discovery findings summary

## Documentation Outputs — ENFORCED (llm-wiki paths)

After each technique attempt (success OR failure), BEFORE moving to next
action, invoke `/log-finding` with the outcome. This writes to:

- `llm-wiki/wiki/techniques/<technique_slug>.md` (template: technique.md)
- `llm-wiki/wiki/targets/<hostname>.md` (template: target.md)
- `llm-wiki/log.md` (changelog row)
- `Notes_Mitre_ATTack_Framework/` (MITRE cross-link)

After successful initial access, also produce:

1. **Technique writeup** (`llm-wiki/wiki/techniques/<technique>.md`):
   - Vulnerability exploited + CVE/MITRE ID
   - Custom exploit approach (what was adapted from references)
   - Exact steps to reproduce
   - Time to exploit

2. **IoC report** (`llm-wiki/wiki/targets/<hostname>.md` under ## IOCs):
   - Artifacts created on target (files, registry, services)
   - Network signatures (callback patterns, ports)
   - Log entries expected (auth, service, application)

3. **Raw dump** (`llm-wiki/raw/<hostname>-initial-access-<date>.md`):
   - Command output, exploit output, agent callback confirmation
   - Frontmatter: `tags: [raw, intake, initial-access]`

4. **Red team pickup card** (appended to target wiki page):
   - Current access level and agent info
   - Persistence mechanisms in place
   - Next suggested actions (priv esc, lateral)
   - Known constraints or risks

**Failed techniques get documented too.** Invoke `/log-finding` with failure
outcome. This prevents re-trying exhausted vectors in future sessions.

## State writes

```yaml
# engagement.yaml updates
targets:
  - hostname: <target>
    phase: initial_access
    access:
      agent_id: <tuoni agent ID>
      user: <username achieved>
      privilege: <user|admin|root|SYSTEM>
    persistence:
      operational: <beacon ID>
      sleeper: <beacon ID>
    technique:
      cve: <CVE-ID>
      mitre: <technique ID>
      method: <brief description>
```

## Failure modes

- **Exploit fails**: document failure, rotate to next attack vector. Do NOT
  retry same exploit more than twice — detection risk increases.
- **No callback**: check listener, check network path. If SOCKS proxy needed,
  set up via foothold first.
- **Access but no persist**: STOP further operations. Persistence is
  non-negotiable before proceeding.
- **Wrong target responds**: ABORT IMMEDIATELY. Verify Providentia data.
  Report incident to operator.
