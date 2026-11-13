---
name: cred-harvest
description: "Credential harvesting and privilege escalation skill. Research-first approach: determine WHERE creds live via HackTricks + wiki before harvesting. Store in tuoni cred store + wiki refs only. Lockout-aware credential spraying."
modes: [red-team, purple]
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

### Scope Exclusion (CRITICAL)

- **RT-SCOPE-001:** GT (green team) accounts OUT OF SCOPE. When harvesting
  credentials, DISCARD any gt-prefixed usernames, tokens, or sessions. If
  lsass/shadow/SAM dump contains gt creds, exclude them from storage and
  reporting. Never store gt credentials in Tuoni cred store. Never use gt
  tokens for lateral movement even if found in memory or cached logons.

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

## Plugin-First Policy (ENFORCED)

Use tuoni-plugins for credential operations:

| Action | Plugin | Instead of |
|--------|--------|------------|
| Shadow/SSH/config/history dump | cred-dump (4 Linux modules) | `cat /etc/shadow` |
| Windows SAM/LSA/DPAPI/vault | cred-dump (8 Windows modules) | Manual registry/file reads |
| Auto-store to Tuoni creds | cred-dump (built-in) | Manual `tuoni_credential_add` |

After any successful credential recovery:
1. Immediately store in Tuoni via `tuoni_credential_add`
2. Record ref in engagement YAML (tuoni_cred_id only, never plaintext)
3. Write Obsidian ref page: `wiki/<hostname>-creds.md`

## Phases

### Phase 1: Credential Source Research

Before touching target, research WHERE credentials live for this platform:

1. **HackTricks** (hacktricks-mcp): platform-specific credential locations
   - Use `hacktricks_quick_lookup` for first-pass credential dump techniques
   - Use `get_hacktricks_cheatsheet` to extract credential dump commands
   - Windows: SAM, LSA secrets, DPAPI, cached domain creds, vault,
     credential manager, browser stores, service account creds
   - Linux: /etc/shadow, SSH keys, .bash_history, config files,
     keyrings, process memory, environment variables
   - Network devices: running-config, startup-config, SNMP community strings
   - Applications: config files, databases, vaults, API tokens
2. **LOLBins** (lolbins-mcp): credential access via native binaries
   - `find_credential_access`: discover LOLBin-based credential harvesting paths
   - `find_escalation_paths`: priv esc paths that lead to credential access
   - `analyze_opsec_risk`: assess detection risk before each harvest command
3. **Wiki vulns-docs** (outline-readonly): prior team findings for this host/role
4. **GitLab README** (range-intel): deploy-time credentials, default passwords
5. **Hashcat MCP** (hashcat-mcp): hash type identification and cracking strategy
   - `search_hash_types`: identify what hash modes apply before dumping
   - `estimate_crack_time`: assess feasibility before investing agent time
6. **MITRE ATT&CK** (mitre-mcp): T1003 (OS Credential Dumping) sub-techniques
   - `get_data_sources` for T1003: understand what detection covers this technique
   - **Fallback if mitre-mcp unavailable**: use `lolbins analyze_opsec_risk` for
     detection assessment + `hacktricks_quick_lookup "credential dumping detection"`
     for OPSEC notes. `cve_to_attack` can map CWE→ATT&CK if CVE-driven.

Present research to operator: "These credential sources exist on this
platform. Which to target?"

### Phase 2: Privilege Escalation (if needed)

If current access insufficient for credential harvesting:

1. **Research escalation paths**:
   - HackTricks: platform-specific priv esc techniques
   - LOLBins (lolbins-mcp): SUID/capability abuse, native binary exploitation
   - MITRE: T1068 (Exploitation for Privilege Escalation) — if mitre-mcp unavailable,
     use LOLBins `find_escalation_paths` + HackTricks as alternatives
2. **Enumerate from agent** (tuoni-mcp commands on target):
   - Current privileges and group memberships
   - SUID binaries / service permissions / scheduled tasks
   - Kernel/OS version vs known local exploits
   - Misconfigured services or file permissions
3. **Execute escalation**:
   - Custom technique (no public exploit scripts)
   - Verify new access level
   - Update engagement YAML with new privilege level
4. **Persist-swarm ROUND 2 (high-priv)** — MANDATORY before Phase 3:
   - Invoke persist-swarm skill for elevated dual-beacon deployment
   - See persist-swarm Two-Round Persistence section
   - Verify BOTH elevated beacons before proceeding to credential harvest
   - Archive round 1 low-priv beacons once round 2 confirmed stable
   - Cred-dump requires root/SYSTEM — do NOT proceed without verified round 2

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

### Phase 3 Post-Harvest Checks (Windows)

Run after Windows credential harvesting completes:

1. **SID-500 Renamed Administrator Detection**:
   - Command via Tuoni agent: `wmic useraccount where "sid like '%-500'" get name,sid`
   - PowerShell alternative: `Get-WmiObject Win32_UserAccount | Where-Object {$_.SID -match '-500$'} | Select Name,SID`
   - If returned name != "Administrator": flag as **"Built-in Administrator (renamed)"**
   - Implications: SID-500 account bypasses UAC token filtering (full admin token
     on remote logon), eligible for pass-the-hash even when other local admins are not
   - Store renamed account name in Tuoni cred store metadata
   - Document in Obsidian target page: `§ SID-500: <actual_name> (renamed)`

### Phase 3.5: Auto-Crack via Hashcat MCP (when hashes recovered)

When Phase 3 yields crackable hashes (NTLM, NTLMv2, Kerberos TGS, etc.):

1. **Identify hash type** (hashcat-mcp `identify_hash` or `smart_identify_hash`):
   - Feed raw hash value, get hashcat mode number and confidence
2. **Auto-attack strategy** (hashcat-mcp `auto_attack_strategy`):
   - Provide hash + identified type, MCP picks mode/rules/wordlists
   - No manual hashcat syntax needed
3. **Crack** (hashcat-mcp `crack_hash` or `crack_multiple_hashes`):
   - Runs on Kali spoke where hashcat + GPU available
   - Monitor via `get_session_status` for long-running jobs
4. **Analyze results** (hashcat-mcp `analyze_cracked_passwords`):
   - Pattern analysis for spray planning (Phase 5)
   - Feed cracked passwords to Phase 4 storage as plaintext type

Skip this phase for: SSH keys, API tokens, certificates, plaintext passwords
(already usable — go direct to Phase 4).

### Phase 4: Credential Processing — MANDATORY GATES

On Kali (NOT target):

1. **Identify credential type**: plaintext, NTLM hash, Kerberos ticket,
   SSH key, API token, certificate
2. **MANDATORY: Store in Tuoni cred store** (tuoni-mcp `tuoni_credential_add`):
   - Each credential gets unique ref ID
   - Tagged with: source host, source location, type, privilege level
   - **This is a gate step like `/log-finding` — MUST call before proceeding**
   - Zero creds stored = engagement failure (see redteam-test2 post-mortem)
3. **Record ref in engagement YAML** (tuoni_cred_id only, NEVER plaintext):
   - Add to `credentials[]` with ref_id, type, username, domain, source_host
4. **Assess value for lateral movement**:
   - Domain admin? Service accounts with broad access?
   - Match `tuoni_credentials_list` filter by realm against `range_targets` by network
   - Programmatic lateral opportunity mapping, not manual
   - **BloodHound path analysis** (bloodhound-mcp — AD environments):
     For each new domain credential, query bloodhound-mcp for attack paths
     this credential unlocks. "shortest path from <user> to Domain Admins",
     "what can <user> reach via delegation". New creds may open paths that
     were previously blocked.
5. **Document in Obsidian** (refs only):
   - `llm-wiki/wiki/targets/<hostname>.md`: update cred refs section
   - Use template `llm-wiki/templates/credential.md` for credential ref page
   - `obsidian_add_tags`: `#engagement/<id>`, `#phase/cred-harvest`, `#target/<hostname>`
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
   - **Nextcloud OCS API trap**: HTTP 200 does NOT mean auth success.
     Nextcloud returns HTTP 200 for ALL OCS requests when LDAP backend is
     broken or misconfigured. Real auth status is in response body field
     `statuscode` (e.g., `996` = auth failure). Always parse body
     `statuscode`, never trust HTTP status alone. Tools like hydra that
     check only HTTP status will report mass false positives.
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

### Obsidian writes (llm-wiki paths — ENFORCED)

After each credential harvest or priv esc attempt, invoke `/log-finding`.
Then write:

```
llm-wiki/wiki/techniques/<technique>.md  # priv esc / harvest technique
llm-wiki/wiki/targets/<hostname>.md      # update target page findings + cred refs
llm-wiki/raw/<hostname>-creds-<date>.md  # raw enum dump (NO plaintext creds)
llm-wiki/log.md                          # changelog row
```

Credential pages use template `llm-wiki/templates/credential.md`.
**NEVER write actual credential values to Obsidian** — refs only,
linking to Tuoni cred store IDs.

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
