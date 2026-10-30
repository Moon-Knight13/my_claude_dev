---
name: initial-access
description: "Guided initial access — exploit execution with OPSEC hygiene. No Metasploit defaults, custom technique adaptation, lockout-aware credential testing. Triggers persist-swarm on successful access."
---

# Initial Access Skill — OPSEC-Compliant Exploitation

## Usage

```
/initial-access <hostname> <technique>
```

Where `<technique>` is one of: `web-exploit`, `weak-creds`, `service-exploit`,
`social-eng`, `config-abuse`, or `auto` (select from recon findings).

Active in: **red-team** mode only.

## Entry Criteria

Before proceeding, validate ALL of these:

1. **RT-TGT-001 — Target approved**: operator has given explicit approval for
   this exact target. Discovered hosts are NOT automatically in scope.
2. **Recon completed**: engagement YAML has this target with `phase: recon`
   or later and at least one ranked attack vector.
3. **Engagement YAML exists**: target entry present with Providentia data
   and recon findings cached.

If any criterion is unmet, STOP and inform the operator what is missing.

## OPSEC Rules — ENFORCED

### Exploit Hygiene (CRITICAL)

- **MUST NOT default to Metasploit modules** — they are reference material
  only. Extract the technique, understand the mechanism, build custom.
- **Public exploits are learning resources, not deployment tools.** Read
  the PoC to understand the vulnerability; adapt the technique for the
  target environment. Never run stock exploit scripts unmodified.
- **RT-TGT-002: NEVER upload tools to target.** No nmap, hydra, sshpass,
  or exploit binaries on target systems. Run everything FROM Kali through
  SSH tunnels or proxychains/SOCKS proxy.
- Payload naming follows RT-SIG-003 (platform-appropriate cover names:
  `svchost.exe` on Windows, `crond` on Linux — never `payload` or `agent`).
- Payload sizing follows RT-SIG-004 (Linux 1–5 MB, Windows 120–180 MB).
- Unique payload ID per target (RT-SIG-002).

### Identity

- All outbound connections use `root` agent identity (RT-SIG-001).
- No `rt`-prefixed usernames in any target-facing traffic.

## Technique Selection

Based on recon findings, select the appropriate technique category:

### Web Exploit (CVE-based or custom)
- Targets: web applications with known CVEs or discoverable vulns
- Research via eip-mcp (EPSS scores, exploit availability) + HackTricks
- Build custom exploit adapted to target version and configuration
- Execute from Kali against target web service

### Default / Weak Credentials
- Targets: services with default or guessable credentials
- Cross-reference GitLab README deploy notes for known defaults
- **Credential spray safety applies** (see below)

### Service Exploit (SSH, RDP, SMB, etc.)
- Targets: network services with version-specific vulnerabilities
- Fingerprint service version from recon, match to CVE database
- Research exploit method from HackTricks + eip-mcp
- Adapt technique — do not use stock exploit code

### Social Engineering Prep
- Targets: user-facing systems where phishing or pretexting applies
- Generate phishing payload with platform-appropriate naming
- Stage delivery infrastructure on Kali
- Payload must pass basic inspection (size, name, icon)

### Configuration Abuse
- Targets: misconfigured services, permissive defaults, exposed management
- Identify misconfiguration from recon delta (expected vs actual state)
- Exploit configuration gap without needing a vulnerability
- Common: open management interfaces, default SNMP, anonymous access

## Execution Flow

### Phase 1: Review Recon Findings

1. Load engagement YAML for target
2. Review ranked attack vectors from recon phase
3. Cross-reference with operator's chosen technique
4. If `auto` technique: select highest-ranked vector that matches available
   capabilities

### Phase 2: Technique Research

For the selected technique, query reference sources:

1. **HackTricks** (hacktricks-mcp): detailed exploitation steps for this
   platform/service/version combination
2. **eip-mcp**: CVE details, EPSS score, known exploit availability
3. **MITRE ATT&CK** (mitre-mcp): technique ID, sub-techniques, detection
   signatures to be aware of
4. **Wiki vulns-docs** (outline-readonly): prior team research on this vuln

Present research summary to operator:
- Technique name + MITRE ATT&CK ID
- Manual reproduction steps (no Metasploit)
- Detection risk assessment
- Recommended custom implementation approach

### Phase 3: Payload Preparation

Build or configure payload on Kali:

1. **Select listener**: match target network position
   - Direct connect: target can reach C2
   - Reverse: target behind NAT/firewall
   - SOCKS: through existing foothold proxy
2. **Generate payload** with OPSEC-compliant naming and sizing
3. **Stage delivery** on Kali (web server, SMB share, SCP — depending on
   access path)
4. **Verify payload**: test on non-target system if available

### Phase 4: Exploitation

Execute FROM Kali (NEVER from target — RT-TGT-002):

1. **Pre-flight check**:
   - Confirm target IP matches Providentia record
   - Confirm target in approved scope (RT-TGT-001)
   - Confirm payload unique to this target (RT-SIG-002)
   - Confirm listener active and receiving
2. **Execute exploit** from Kali through tunnel/proxy if needed
3. **Verify access**:
   - Agent callback confirmed
   - Basic enumeration: whoami, hostname, network
   - Compare actual vs expected (Providentia data)

### Phase 5: Post-Access — Persist on Landing

**CRITICAL: immediately trigger persist-swarm after successful access.**
Persistence before any other post-exploitation activity — this applies to
initial access the same way it applies to lateral movement.

1. **Deploy persistence** (persist-swarm skill):
   - Operational beacon: short callback interval
   - Sleeper beacon: long callback interval (survival)
2. **Initial discovery sweep**:
   - Local users, groups, privileges
   - Network connections, routing table
   - Running services, scheduled tasks
   - Credential store locations (identify, do NOT harvest yet)
3. **Update engagement YAML**:
   - Target phase: `initial_access`
   - Agent ID, access level achieved
   - Persistence beacon IDs
   - Discovery findings summary

## Credential Spray Safety

If the selected technique involves credential testing (weak-creds,
service-exploit with auth, or any brute-force component):

- **MUST enumerate lockout policy** before ANY credential testing
  - AD: `net accounts /domain` or equivalent
  - Linux: `/etc/pam.d/` faillock/tally configuration
  - Application: documentation review or test with known-bad credential
- **One password per observation window** — never exceed lockout threshold
- If lockout policy is unknown: **single attempt only**, then wait full
  window before next attempt
- Track ALL attempts (success AND failure) in engagement YAML
- On lockout trigger: STOP immediately, report to operator

## State Writes

```yaml
# engagement.yaml updates
targets:
  - hostname: <target>
    phase: initial_access
    access:
      agent_id: <agent ID>
      user: <username achieved>
      privilege: <user|admin|root|SYSTEM>
    persistence:
      operational: <beacon ID>
      sleeper: <beacon ID>
    technique:
      cve: <CVE-ID if applicable>
      mitre: <technique ID>
      method: <brief description>
    cred_spray_log:
      - timestamp: <ISO 8601>
        target_service: <service>
        username: <attempted>
        result: <success|fail|lockout>
```

## Failure Modes

- **Exploit fails**: document failure reason, rotate to next ranked attack
  vector. Do NOT retry the same exploit more than twice — detection risk
  compounds with each attempt.
- **No callback**: verify listener status, check network path. If target
  is behind segmentation, set up SOCKS proxy via existing foothold first.
- **Access achieved but persist fails**: STOP all further operations.
  Persistence is non-negotiable before proceeding to any other phase.
- **Wrong target responds**: ABORT IMMEDIATELY. Cross-check Providentia
  data. Report targeting incident to operator.
- **Lockout triggered during credential testing**: STOP all spray
  immediately. Wait full lockout window. Report to operator.
