<!-- Mini variant for subagent dispatch. Full version: SKILL.md -->
---
name: initial-access
description: "Guided initial access skill for red-team mode. Takes recon output, researches exploit techniques via reference MCPs, enforces OPSEC exploit hygiene (no Metasploit defaults), and stages custom exploitation from Kali."
modes: [red-team, purple, ctf]
---

# Initial Access — Mini

## Thread Orchestration

Initial-access runs as SEPARATE thread from recon. Reads Obsidian target page produced by recon. If page lacks CVE research or PoC details, report back to master — do not proceed.

## Entry criteria (ALL MANDATORY)

- Target classified `confirmed` in engagement state
- Reachability verified FROM the specific pivot/agent being used
- Obsidian target page exists with completed research (services, CVEs, PoCs)
- Attack vectors ranked and operator-approved
- Target explicitly in scope (RT-TGT-001 confirmed)
- Engagement YAML has target entry

## OPSEC Rules — ENFORCED

### Exploit Hygiene (CRITICAL)

- **NO Metasploit modules** as deployment tools. Extract technique only.
- **NO public exploit scripts** run unmodified. Understand, adapt, custom-build.
- **NO tools uploaded to target** (RT-TGT-002). Run everything from Kali.
- Payload naming per RT-SIG-003, sizing per RT-SIG-004, unique ID per RT-SIG-002.

### Execution Platform (CRITICAL)

- **ALL offensive traffic originates from Kali.** NEVER from hub.
- Hub is orchestration only (MCP calls, Obsidian writes, YAML updates).

### Credential Testing (STRICT LIMITS)

- **Max 3-5 default passwords per service.** After defaults fail, STOP and pivot to CVE research.
- **NEVER run hydra/medusa/spray as primary vector.** Brute force is LAST resort.
- **>10 password attempts per service = OPSEC violation.**

### fail2ban / IDS (ENFORCED)

- **Max 2 SSH attempts per source IP per target** before pausing
- **30-minute minimum** between attempt batches
- Rotate source IPs if multiple agents available
- Invoke `opsec-cred-spray` before ANY auth attempt
- Ban detection: port changes OPEN→FILTERED, TCP RST, HTTP 000, SSH banner timeout

## Access Method Probe Sequence

Run BEFORE technique research. From Kali agent, 30s timeout each:

1. **SSH** (22): nmap probe → test 3-5 defaults if open
2. **WinRM** (5985/5986): nmap probe → test creds if open
3. **SMB Exec** (445): nmap probe → impacket (smbexec → wmiexec → psexec) if open
4. **RDP** (3389): nmap probe → operator-assisted if open (see full SKILL.md for RDP workflow)

Record results to Obsidian target page `§ Access Methods`. When ALL probes fail, report to operator with manual delivery instructions.

## RESEARCH GATE (MANDATORY)

Before ANY exploitation attempt, verify Obsidian target page has per-service:
- Service name + exact version
- cve-mcp `cve_by_product` run, top CVEs enriched
- HackTricks relevant sections read
- Nuclei scan run
- Pre-auth exploits identified with trigger mechanism
- PoC source or custom adaptation documented

If ANY service lacks research, complete it BEFORE exploitation. This gate prevents "enumerate → try passwords → report blocked."

## Phase 1: Technique Research (ENUMERATION-DRIVEN, NOT PROVIDENTIA-DRIVEN)

Attack vectors from live enumeration (service versions + open ports), NOT Providentia vuln names. Per service:version, research via HackTricks, CVE intelligence (cve_by_product → cve_enrich → exploit_search), MITRE ATT&CK, LOLBins OPSEC check, wiki vulns-docs.

## Phase 2: Payload Preparation

Build on Kali via tuoni-mcp: select listener, generate payload (cover name, platform sizing, unique ID), stage delivery, verify.

## Phase 3: Exploitation

1. Pre-flight: confirm target IP, scope, unique payload, active listener
2. Execute from Kali via tuoni-mcp
3. Verify access: agent check-in, basic enum (whoami, hostname, network)
4. **AUTO-CHAIN: persist-swarm round 1 (MANDATORY, IMMEDIATE)** — invoke `persist-swarm` the moment agent callback confirmed. Same thread. Pass current privilege level. NEVER skip. Confirm both beacons before proceeding. Failure to persist = STOP.

## Phase 4: Post-Access Kill Chain

Begins AFTER round 1 persistence confirmed.

1. Persist round 1 — verify beacons live (done in Phase 3 step 4)
2. Discovery — invoke `discovery` skill
3. Privilege escalation — invoke `get-system` plugin (recon_only first)
4. **Persist round 2 (high-priv)** — invoke `persist-swarm` again after escalation
5. Credential harvest — invoke `cred-harvest` skill
6. Collect intel — invoke `collect-intel` plugin
7. Update Obsidian target page (all sections)
8. Lateral decision — with harvested creds, select next target (RT-TGT-001 approval)

If privesc fails: keep round 1 persistence, document limitation, continue with user-level access.

## Documentation Outputs — ENFORCED

After EACH technique attempt (success OR failure), invoke `/log-finding`. After successful access: technique writeup, IoC report, raw dump, pickup card. Failed techniques documented too.

## State writes

```yaml
targets:
  - hostname: <target>
    classification: compromised
    phase: initial_access
    access:
      agent_id: <tuoni agent ID>
      user: <username>
      privilege: <user|admin|root|SYSTEM>
    persistence:
      operational: <beacon ID>
      sleeper: <beacon ID>
    technique:
      cve: <CVE-ID>
      mitre: <technique ID>
      method: <brief description>
```

## Degraded mode

When `degraded_mode: router-only`: skip Phases 2-3, attempt SSH-based access through Tuoni agent commands. See full SKILL.md for details.
