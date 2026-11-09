---
name: initial-access
description: "Guided initial access skill for red-team mode. Takes recon output, researches exploit techniques via reference MCPs, enforces OPSEC exploit hygiene (no Metasploit defaults), and stages custom exploitation from Kali."
modes: [red-team, purple]
---

# Initial Access Skill — OPSEC-Compliant Exploitation

## When to use

Operator ready to exploit a target after recon phase. Takes ranked attack
vectors from recon skill output or engagement YAML.

Active in: **red-team** mode only.

## Thread Orchestration

**Initial-access runs as a SEPARATE thread from recon.** It reads the
Obsidian target page produced by the recon thread. Do not combine recon and
initial-access in one thread — this prevents shortcutting research to jump
to credential testing.

**Input:** Read `llm-wiki/wiki/targets/<hostname>.md` via obsidian-mcp.
This page has: services, versions, CVEs, ranked vectors, PoC details.
If the page lacks CVE research or PoC details, the recon thread was
incomplete — report back to master, do not proceed.

## Entry criteria

- **Target marked REACHABLE** in recon Phase 0 reachability matrix (MANDATORY)
- **Obsidian target page exists** with completed research (services, CVEs, PoCs)
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

### Execution Platform (CRITICAL)

- **ALL offensive traffic originates from Kali.** Run tools via `ssh kali '<command>'`
  or via tuoni self-agent. NEVER run nmap/hydra/curl-to-target from the hub machine.
- Hub is for orchestration (MCP calls, Obsidian writes, YAML updates) only.

### Identity

- All outbound connections use `root` agent (RT-SIG-001).
- No `rt`-prefixed usernames in any target-facing traffic.

### Credential Testing (STRICT LIMITS)

- **Max 3-5 default passwords per service** (blank, product default, admin:admin).
  After defaults fail, STOP credential testing and pivot to CVE research.
- **Never run hydra/medusa/spray as primary vector.** Brute force is LAST resort
  after all CVE/exploit paths exhausted AND operator approves.
- **>10 password attempts per service = OPSEC violation.** Log it as such.
- Version-specific CVE exploit > credential guessing. Always.

## Phases

### Phase 0: Tool Availability Check

Before selecting attack vectors, verify available tooling:

1. Read engagement YAML `tools_verified` section (populated by kali-bootstrap)
2. If no `tools_verified`: check `degraded_mode` — if `router-only`, use
   degraded attack paths only (see Degraded Mode section below)
3. For each candidate attack vector, check its technique wiki page
   (`llm-wiki/wiki/techniques/<slug>.md`) `## Tool Requirements` section
4. **Skip vectors whose required tools are missing.** Report skipped vectors
   and missing tools to operator.
5. If technique has no wiki page yet: check tool requirement against
   kali-bootstrap manifest (`llm-wiki/wiki/tools/kali-bootstrap-manifest.md`)

This prevents wasting time on vectors that will fail due to tooling gaps.
When a technique IS attempted and fails due to missing tools, log finding
with `result: blocked, notes: tooling_gap — <tool_name> not available`.
This auto-feeds `llm-wiki/wiki/tools/tools-needed.md` for next bootstrap.

### Phase 1: Technique Research (ENUMERATION-DRIVEN, NOT PROVIDENTIA-DRIVEN)

**MANDATORY:** Attack vectors come from live enumeration results (recon Phase 2
service versions + open ports), NOT from Providentia vuln tag names. Providentia
tags are hints to investigate, never vectors to execute directly.

Input to this phase: service versions and open ports from net-recon/nmap.
For each identified service+version, research attack techniques:

0. **Range vuln profiles** (range-intel `range_vuln_lookup`): cross-reference
   Providentia vuln tags against what enumeration actually found. Discrepancies
   (vuln listed but service not running, or service found but no vuln listed)
   are high-value findings.
0b. **BloodHound attack paths** (bloodhound-mcp — AD environments):
   - Query attack paths from current access to target (DA, EA, specific accounts)
   - Identify kerberoastable SPNs on shortest paths — prioritize for credential attacks
   - Check delegation abuse chains (unconstrained, constrained, RBCD)
   - Map ADCS misconfiguration vectors (ESC1-ESC8)
   - Check NTLM relay opportunities to target DCs
   - Use results to select and prioritize attack vectors below
1. **HackTricks** (hacktricks-mcp): use efficient workflow:
   - `hacktricks_quick_lookup` for first-pass exploitation overview
   - `search_hacktricks` → `get_hacktricks_outline` → `get_hacktricks_section` for depth
   - `get_hacktricks_cheatsheet` to extract all code blocks for adaptation
   - NEVER use `get_hacktricks_page` (3000-15000 tokens) when `get_hacktricks_section` suffices
2. **CVE intelligence** (cve-mcp) — full enrichment pipeline:
   - `cve_by_product`: FIRST — find CVEs for exact product+version from enumeration
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

### RESEARCH GATE (MANDATORY before any exploitation attempt)

Before proceeding to payload prep or execution, verify the Obsidian target
page (`llm-wiki/wiki/targets/<hostname>.md`) contains per-service research:

```
For EACH open service:
  [ ] Service name + exact version
  [ ] cve-mcp: cve_by_product run, top CVEs enriched
  [ ] hacktricks-mcp: relevant sections read (not just quick_lookup)
  [ ] nuclei-mcp: scan run against target
  [ ] wiki vulns-docs: checked for this service/vuln type
  [ ] GitLab README: reviewed for deploy config (range_host with readme)
  [ ] Obsidian prior findings: checked
  [ ] Pre-auth exploits identified with trigger mechanism
  [ ] PoC source or custom adaptation documented
```

**Blind-scan evidence accepted.** When `intel_source: blind_scan` is set on
target page (recon ran without Providentia/README), the gate validates that
evidence EXISTS — not where it came from. Specifically:
- nmap service:version satisfies "Service name + exact version"
- CVE research from cve-mcp satisfies enrichment requirement
- hacktricks + nuclei research still required (source-independent)
- GitLab README check: SKIP if unavailable (blind mode has no READMEs)
- wiki vulns-docs check: SKIP if outline-readonly unavailable
- All other checks remain mandatory

The gate validates DEPTH of research per service, not intel SOURCE.

If ANY service lacks this research, complete it BEFORE attempting exploitation.
This gate prevents the "enumerate → try passwords → report blocked" pattern.

**Credential testing:** Max 3-5 product defaults per service ONLY. Never brute
force. After defaults fail, exploit research is the path forward, not more passwords.

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

4. **AUTO-CHAIN: Persist-swarm round 1 (MANDATORY, IMMEDIATE)**:
   - **Do NOT wait for operator.** Invoke `persist-swarm` skill the moment
     agent callback is confirmed. Same thread, no handoff.
   - Pass current privilege level (`user` or `root`) — persist-swarm adapts.
   - **NEVER skip round 1 because "we might get root later."**
   - If landing as non-root: user-level mechanisms only (see Phase 4 detail).
   - If persist-swarm skill fails: deploy manually, but DO NOT skip.
   - Confirm both beacons (operational + sleeper) call back before proceeding.
   - Failure to persist = STOP. No discovery, no privesc, no lateral until
     at least one beacon is confirmed durable.

### Phase 4: Post-Access Kill Chain

**PERSIST-ON-LANDING is handled by Phase 3 step 4 auto-chain.** Phase 4
begins AFTER round 1 persistence is confirmed. If you arrived here without
round 1 complete, STOP and go back.

1. **Persist-swarm ROUND 1 (low-priv)** — already invoked in Phase 3 step 4.
   Verify beacons are live. If not, re-invoke `persist-swarm` skill.

   **Privilege-aware mechanisms (non-root footholds):**
   - **User crontab**: `crontab -e` (no root needed)
   - **User systemd unit**: `~/.config/systemd/user/` (no root needed)
   - **Shell profile**: `.bashrc` / `.profile` / `.bash_logout` hooks
   - **XDG autostart**: `~/.config/autostart/` (if desktop session)
   - Windows user-level: startup folder, HKCU Run key, scheduled task (user context)
   - Cover names per RT-SIG-003, unique ID per RT-SIG-002
2. **Discovery** — invoke `discovery` skill:
   - Runs host-id, ad-enum, net-recon, collect-intel plugins
   - If domain-joined: trigger bloodhound-python collection
   - Credential store locations identified (harvest in step 5, not here)
3. **Privilege escalation** — invoke `get-system` plugin:
   - Run `recon_only=true` first to enumerate paths
   - Execute best privesc path (writable passwd, setuid, sudoers, service exploit, etc.)
   - Verify elevated access (root/SYSTEM)
4. **Persist-swarm ROUND 2 (high-priv)** — invoke `persist-swarm` skill again:
   - Elevated dual-beacon (systemd + cron.d, or service + scheduled task)
   - These are the durable operational beacons
   - Archive round 1 low-priv beacons once high-priv confirmed stable

   **If privesc FAILS:**
   - Keep round 1 user-level persistence — do NOT remove it
   - Document limitation in Obsidian target page: `privilege: user (privesc failed)`
   - Log privesc failure as finding via `/log-finding`
   - Continue to credential harvest (user-level: .bash_history, SSH keys,
     readable config files, tokens) — skip root-only sources
   - Continue to lateral decision with user-level creds
   - Round 2 is skipped, not failed — engagement proceeds with user-level access
5. **Credential harvest** — invoke `cred-harvest` skill (requires root/SYSTEM):
   - Linux: shadow, SSH keys, tokens, bash history
   - Windows: SAM, LSASS, cached domain creds, DPAPI
   - Store in tuoni cred store, refs only in Obsidian
6. **Collect intel** — invoke `collect-intel` plugin:
   - Sweep config dirs for keys, tokens, .env files, cloud creds
7. **Update Obsidian target page**:
   - All sections: § Access, § Persistence, § Discovery, § Creds, § Intel
   - Engagement page: update target phase status
8. **Lateral decision** — with harvested creds, select next target:
   - Sequential approval required (RT-TGT-001)
   - Update Obsidian engagement page before moving

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

## Degraded Mode (Router-Only Operations)

When `degraded_mode: router-only` is set in engagement YAML (no Kali spoke),
the following constraints apply:

**Available on router agents:** Python3 (socket, subprocess, urllib,
http.client), pexpect (r1), Scapy (ICMP/raw), curl, basic shell, Tuoni
plugins (net-recon, host-id, jump-ssh, cred-dump, persist-swarm).

**NOT available:** nmap, hydra, smbclient, impacket, xfreerdp, crackmapexec,
rpcclient, icmp_c2.py, sshpass, medusa, enum4linux.

**Degraded attack paths:**
- SSH password auth: Tuoni `remote-exec-ssh` or `jump-ssh` (one attempt at
  a time, manually)
- Port scanning: Python socket (`connect_ex`), NOT bash `/dev/tcp` (false negatives)
- Web enumeration: curl + Python urllib (manual path probing)
- ICMP: Scapy for crafted packets
- SMB/RDP: BLOCKED — no tools available
- Password spray: BLOCKED — no spray tools

**Skip Phases 2-3** (payload prep, Kali execution). Attempt SSH-based
initial access directly through Tuoni agent commands.

## Network Device SSH (Menu Shell Targets)

pfSense, Cisco IOS, and similar devices present interactive menu shells on SSH
instead of a standard command shell. Tuoni `remote-exec-ssh` connects but
cannot navigate menus.

**Preferred approach: jump-ssh plugin.** SCP delivery bypasses the login
shell entirely — SCP writes files directly without invoking the menu. Use
`jump-ssh` to:
1. SCP a script to the target
2. Execute the script via a separate SSH channel

**pexpect approach (fallback):** Write a pexpect script to a file on the
relay agent, then execute it. Use prompt pattern `Password for.*:` (not
`[Pp]assword:` — pfSense includes username in prompt).

## fail2ban / IDS Awareness — ENFORCED

Many targets run fail2ban or equivalent IDS that ban source IPs after
repeated authentication failures. A ban can lose access to the target AND
all targets behind it (e.g., a gateway firewall blocks all downstream targets).

**Rules:**
- **Max 2 SSH attempts per source IP per target** before pausing
- **Wait 30 minutes minimum** between attempt batches (default fail2ban ban)
- **Rotate source IPs** if multiple agents available on different hosts
- **Before ANY auth attempt**: invoke `opsec-cred-spray` skill for lockout
  policy enumeration
- **After ban detection** (SSH FILTERED or connection refused after prior
  success): log OPSEC incident, set 60-minute cooldown timer, try alternate
  source IP

**Ban detection indicators:**
- Port changes from OPEN to FILTERED (iptables DROP)
- TCP RST where previously SYN-ACK (iptables REJECT)
- HTTP 000 response on previously-working HTTPS
- SSH banner timeout where banner previously appeared
- ICMP still responds (fail2ban bans port, not IP entirely)

**Recovery:**
1. Log ban in engagement YAML as OPSEC incident finding
2. Set timer: do NOT retry before ban expiry (typically 30-60 min)
3. If alternate agent on different IP exists, attempt from there
4. If gateway target banned: ALL downstream targets inaccessible — pivot
   to other reachable targets first

## Providentia Vulnerability Data — Trust but Verify

Providentia vuln data may be aspirational (what SHOULD be deployed) rather
than factual (what IS deployed). The `custom_not_working` tag explicitly
marks broken vulns, but unlisted vulns may also be non-functional.

**Before committing to an attack vector:**
1. Check Providentia tags for `custom_not_working` or similar
2. Verify the service/port actually exists (port scan first)
3. Cross-reference with GitLab README for deploy status
4. If 2+ vectors fail on same target: suspect Providentia data issue, not
   technique failure. Report to operator.

## Failure modes

- **Exploit fails**: document failure, rotate to next attack vector. Do NOT
  retry same exploit more than twice — detection risk increases.
- **No callback**: check listener, check network path. If SOCKS proxy needed,
  set up via foothold first.
- **Access but no persist**: STOP further operations. Phase 3 step 4
  auto-chains persist-swarm immediately — if it failed, diagnose and retry
  before ANY discovery or privesc. Persistence is non-negotiable.
- **Wrong target responds**: ABORT IMMEDIATELY. Verify Providentia data.
  Report incident to operator.
- **fail2ban triggered**: STOP all attempts to target. Log OPSEC incident.
  Set 60-min cooldown. Try alternate source IP or target. See fail2ban
  section above.
