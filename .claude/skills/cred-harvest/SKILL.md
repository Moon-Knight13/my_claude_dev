---
name: cred-harvest
description: "Credential harvesting and privilege escalation skill. Research-first approach: determine WHERE creds live via HackTricks + wiki before harvesting. Store in tuoni cred store + wiki refs only. Lockout-aware credential spraying."
---

# Credential Harvest + Privilege Escalation

## When to use

After initial access established. Operator wants to escalate privileges
or harvest credentials for lateral movement.

Active in: **red-team** mode only.

## Entry criteria

- Active agent on target (engagement YAML `phase: initial_access` or later)
- Persistence confirmed (operational + sleeper beacons)
- Current access level documented

## OPSEC Rules — ENFORCED

### Credential Spray Safety

- **MUST enumerate lockout policy** before ANY credential spraying
- Stay under lockout threshold (typically N-1 attempts per observation window)
- One password per lockout observation window
- If lockout policy unknown: single attempt only, then wait full window

### Credential Storage

- Credentials stored as REFS ONLY in engagement YAML and Obsidian
- Actual creds go to **tuoni credential store** (tuoni-mcp)
- Wiki documentation uses `[cred-ref: <id>]` format, NEVER plaintext
- No passwords, hashes, or tokens in YAML, Obsidian, or git

### Tool Discipline

- RT-TGT-002: NO tools uploaded to target
- All harvesting commands run through tuoni agent on target
- Heavy processing (hash cracking) on Kali only

## Phases

### Phase 1: Credential Source Research

Before touching target, research WHERE credentials live for this platform:

1. **HackTricks** (hacktricks-mcp): platform-specific credential locations
   - Windows: SAM, LSA secrets, DPAPI, cached domain creds, vault,
     credential manager, browser stores, service account creds
   - Linux: /etc/shadow, SSH keys, .bash_history, config files,
     keyrings, process memory, environment variables
   - Network devices: running-config, startup-config, SNMP community strings
   - Applications: config files, databases, vaults, API tokens
2. **Wiki vulns-docs** (outline-readonly): prior team findings for this host/role
3. **GitLab README** (range-intel): deploy-time credentials, default passwords
4. **MITRE ATT&CK** (mitre-mcp): T1003 (OS Credential Dumping) sub-techniques

Present research to operator: "These credential sources exist on this
platform. Which to target?"

### Phase 2: Privilege Escalation (if needed)

If current access insufficient for credential harvesting:

1. **Research escalation paths**:
   - HackTricks: platform-specific priv esc techniques
   - GTFOBins (gtfobins-mcp): SUID/capability abuse on Linux
   - MITRE: T1068 (Exploitation for Privilege Escalation)
2. **Enumerate from agent** (tuoni-mcp commands on target):
   - Current privileges and group memberships
   - SUID binaries / service permissions / scheduled tasks
   - Kernel/OS version vs known local exploits
   - Misconfigured services or file permissions
3. **Execute escalation**:
   - Custom technique (no public exploit scripts)
   - Verify new access level
   - Update engagement YAML with new privilege level
4. **Re-establish persistence at new level**:
   - Persist-on-landing rule applies after priv esc too
   - New beacons at elevated privilege

### Phase 3: Credential Harvesting

Execute harvesting from agent (through tuoni-mcp):

1. **Memory-based** (highest value, most volatile):
   - Process memory (lsass on Windows, ssh-agent on Linux)
   - Cached logon credentials
   - Session tokens
2. **File-based** (persistent, lower detection risk):
   - Config files with embedded credentials
   - SSH keys and certificates
   - Browser credential stores
   - Application database connection strings
3. **Registry/store-based** (Windows):
   - SAM database
   - LSA secrets
   - DPAPI protected data
   - Credential Manager vault

### Phase 4: Credential Processing

On Kali (NOT target):

1. **Identify credential type**: plaintext, NTLM hash, Kerberos ticket,
   SSH key, API token, certificate
2. **Store in tuoni** (tuoni-mcp credential operations):
   - Each credential gets unique ref ID
   - Tagged with: source host, source location, type, privilege level
3. **Assess value for lateral movement**:
   - Domain admin? Service accounts with broad access?
   - Match against Providentia host list — where could these creds work?
4. **Document in Obsidian** (refs only):
   - `wiki/<hostname>-creds.md`: list of ref IDs, types, potential targets
   - NEVER write actual credential values

### Phase 5: Credential Spray (if operator approves)

Only with operator approval and lockout policy enumerated:

1. **Enumerate lockout policy**:
   - AD: `net accounts /domain` or equivalent via agent
   - Linux: `/etc/pam.d/` faillock/tally configuration
   - Application: documentation or testing with known-bad password
2. **Plan spray**:
   - Targets: list from Providentia matching credential scope
   - Rate: one password per lockout window
   - Credential: start with most likely (seasonal, company name patterns)
3. **Execute spray** (from Kali, through SOCKS if needed):
   - Single credential at a time
   - Monitor for lockouts between attempts
   - Log every attempt (success AND failure) in Obsidian
4. **On success**:
   - Store new access in tuoni cred store
   - Assess for lateral movement potential
   - Do NOT immediately use — plan lateral move first

## State writes

```yaml
# engagement.yaml updates
targets:
  - hostname: <target>
    phase: cred_harvest
    access:
      privilege: <updated if escalated>
    cred_refs:
      - id: <tuoni cred ref>
        type: <hash|plaintext|key|token|ticket>
        scope: <local|domain|service>
        lateral_targets: [<hostnames where cred may work>]
```

```
# Obsidian writes
wiki/<hostname>-privesc.md        # escalation technique used
wiki/<hostname>-creds.md          # credential ref index (NO plaintext)
raw/<hostname>-enum-<date>.md     # raw enumeration dump
```

## Failure modes

- **Lockout triggered**: STOP all spray immediately. Wait full lockout
  window. Report to operator. Reassess approach.
- **AV/EDR blocks harvesting**: research evasion for this specific product
  via HackTricks. Do NOT disable AV — detection risk too high.
- **Insufficient privileges**: return to Phase 2 priv esc. If no path
  found, escalate to operator for alternative approach.
- **No valuable creds found**: document negative result. Consider:
  keylogging (long game), Kerberoasting, AS-REP roasting, or other
  indirect approaches per HackTricks research.
