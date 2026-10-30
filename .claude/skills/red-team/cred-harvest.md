---
name: cred-harvest
description: "Grounded credential harvest skill for red-team mode. Three-phase approach: GROUND (research where creds live on this platform), HARVEST (extract through C2), STORE (tuoni cred store + engagement refs). Use when operator says 'cred harvest', 'harvest creds', 'dump creds', or targets credential extraction on a compromised host."
---

# Credential Harvest Skill — Grounded, OPSEC-Compliant Extraction

## When to use

Operator wants to harvest credentials from a compromised host. Active agent
required on target.

Active in: **red-team** mode only.

Usage: `/cred-harvest <hostname>`

## Entry criteria

- Mode is red-team
- Target explicitly approved by operator (**RT-TGT-001** confirmed)
- Active agent exists on target (verify via tuoni-mcp `tuoni_agents_list`)
- Engagement YAML exists with target entry at `phase: initial_access` or later

## OPSEC Rules — ENFORCED

- **RT-TGT-001**: Operator MUST approve exact target before any harvest command.
  A compromised host is NOT automatically approved for credential extraction.
- **RT-TGT-002**: NEVER upload tools to target. All extraction runs through
  existing agent commands. No nmap, mimikatz, LaZagne, or similar uploaded.
  Use only built-in OS commands executed via C2 agent.
- **RT-SIG-001**: Use `root` agent identity for all C2 activity.
- Credential spray safety: if spraying discovered creds, MUST enumerate
  lockout policy first and stay under threshold (see Phase 2 addendum).

## CRITICAL STORAGE RULE

Credentials are stored as **REFERENCES ONLY** in engagement YAML `cred_refs`.
**NEVER** store plaintext passwords, hashes, keys, or tokens in:
- Engagement YAML
- Obsidian notes
- Git-tracked files
- Chat transcript

Actual credential values go ONLY to the **tuoni credential store** via
tuoni-mcp. The engagement YAML and documentation contain reference IDs that
point to the tuoni store entry.

---

## Phase 1 — GROUND: Research Where Credentials Live

**This phase is MANDATORY.** Never skip grounding. Never assume credential
locations. Research WHERE creds live on this specific platform BEFORE
attempting any harvest commands.

### Step 1.1: Query Providentia

Via range-intel MCP (`range_host`, `range_networks`):
- OS type and version
- Installed services and roles
- Network position (DMZ, internal, multi-homed)
- Team assignment and purpose

### Step 1.2: Query Wiki — vulns-docs

Via outline-readonly MCP (`outline_search` in vulns-docs collection):
- Known credential locations for this OS/service combination
- Prior engagement findings about credential storage on similar hosts
- Platform-specific extraction techniques documented by team

### Step 1.3: Query Wiki — repo-docs

Via outline-readonly MCP (`outline_search` in repo-docs collection):
- Deploy notes mentioning credentials, service accounts, API keys
- Configuration management details (Ansible vault, deploy scripts)
- Default credentials documented in deployment READMEs

### Step 1.4: Query HackTricks

Via hacktricks-mcp:
- Platform-specific credential storage locations
- Service-specific credential extraction techniques
- Post-exploitation credential harvesting methods for this OS

### Step 1.5: Compile Grounded Credential Map

Before touching the target, present the operator with:

```
Target: <hostname>
OS: <from Providentia>
Services: <from Providentia>

Grounded credential locations:
  1. <location> — <source that says creds live here> — <extraction method>
  2. <location> — <source> — <method>
  ...

Sources consulted:
  - Providentia: <what was found>
  - vulns-docs: <what was found>
  - repo-docs: <what was found>
  - HackTricks: <what was found>
```

Ask operator: "Proceed to harvest these locations?"

---

## Phase 2 — HARVEST: Extract Through C2

Execute ONLY through existing agent via tuoni-mcp. All commands run on
target through the C2 channel — no tools uploaded (**RT-TGT-002**).

### Linux Targets

Work through the grounded credential map. Common locations (only attempt
those confirmed by grounding):

- `/etc/shadow` — local user hashes (requires root)
- `/etc/passwd` — user enumeration
- `~/.ssh/` — SSH private keys, authorized_keys, known_hosts
- Service configs: `/etc/<service>/` — DB passwords, bind credentials
- Environment variables: `/proc/*/environ`, `.bashrc`, `.profile`, `.env`
- Browser credential stores: `~/.mozilla/`, `~/.config/google-chrome/`
- Application configs: connection strings, API tokens in app directories
- Cron jobs: credentials in scripts (`/var/spool/cron/`, `/etc/cron.d/`)
- History files: `.*_history` for leaked credentials in command history
- Keyring/wallet: GNOME Keyring, KDE Wallet paths

### Windows Targets

Work through the grounded credential map. Common locations (only attempt
those confirmed by grounding):

- **SAM/SYSTEM**: `reg save` to extract local account hashes
- **LSA secrets**: registry-stored service credentials
- **DPAPI**: user credential blobs (`%APPDATA%\Microsoft\Protect\`)
- **Kerberos tickets**: `klist` to enumerate, extract TGT/TGS
- **Cached domain credentials**: registry stored domain creds
- **Browser credential stores**: Chrome, Edge, Firefox profile directories
- **Service configs**: connection strings in application configs
- **Credential Manager**: `cmdkey /list`, vault enumeration
- **Scheduled tasks**: credentials stored for task execution
- **Group Policy Preferences**: `SYSVOL` cpassword remnants (legacy)
- **Wi-Fi profiles**: `netsh wlan show profiles` with key extraction
- **Registry run keys**: credentials in auto-start entries

### Network Device Targets

Work through the grounded credential map. Common locations (only attempt
those confirmed by grounding):

- **Running config**: `show running-config` or XML config dump
- **Startup config**: `show startup-config`
- **SNMP community strings**: in running config
- **RADIUS/TACACS secrets**: shared secrets in AAA configuration
- **Local user database**: `show users`, local account hashes
- **VPN pre-shared keys**: IPsec/IKE configuration sections
- **Certificate private keys**: if stored on device
- **API tokens**: REST API or NETCONF credentials in config

### Application-Specific Targets

Additional locations based on grounding results:

- **Database connection strings**: app configs, web.config, settings files
- **LDAP bind credentials**: directory service integration configs
- **RADIUS shared secrets**: network access control configs
- **SMTP relay credentials**: mail server configuration
- **API tokens and keys**: environment files, vault configs, `.env` files
- **Cloud provider credentials**: AWS keys, Azure tokens, GCP service accounts
- **Container secrets**: Docker env, Kubernetes secrets (if accessible)

### Credential Spray Safety Addendum

If operator requests credential spraying with harvested credentials:

1. **MUST** enumerate account lockout policy FIRST:
   - Windows: `net accounts /domain` or `Get-ADDefaultDomainPasswordPolicy`
   - Linux: `/etc/pam.d/` faillock/tally configuration
   - Network: login attempt limits in device config
2. **MUST** stay under lockout threshold — always spray at `threshold - 2`
3. **MUST** respect lockout observation window timing
4. **MUST** get operator approval for spray target list (RT-TGT-001)
5. Log every spray attempt for deconfliction

---

## Phase 3 — STORE: Safe Credential Storage

### Step 3.1: Store in Tuoni Credential Store

Via tuoni-mcp, store each discovered credential:
- Credential type (hash, plaintext, key, ticket, token)
- Associated username / service account
- Source host where discovered
- Discovery method (which grounded location)
- Validity status (tested / untested)

The tuoni credential store is the ONLY location for actual credential values.

### Step 3.2: Create Engagement YAML cred_ref Entry

Add reference entry to engagement YAML — **REFERENCES ONLY, NEVER PLAINTEXT**:

```yaml
# engagement.yaml — cred_refs section
cred_refs:
  - id: <tuoni_cred_store_id>
    source_host: <hostname>
    type: <hash|key|ticket|token|password>
    username: <associated_user>
    discovery_method: <how found>
    discovered_at: <timestamp>
    phase: cred_harvest
    tested: <true|false>
    notes: "Reference only — value in tuoni cred store"
```

### Step 3.3: Document Findings

Update Obsidian via obsidian-mcp (**references only, no credential values**):

- `wiki/<hostname>-creds.md` — structured findings page:
  - Credential locations checked (from grounded map)
  - What was found at each location (type and reference, not value)
  - Tuoni cred store reference IDs
  - Recommendations for next phase (lateral movement candidates)

- `raw/<hostname>-cred-harvest-<date>.md` — immutable harvest log:
  - Commands executed (sanitized — no credential output)
  - Locations checked vs locations yielding results
  - Grounding sources consulted

### Step 3.4: Update Engagement State

```yaml
# engagement.yaml target update
targets:
  - hostname: <target>
    phase: cred_harvest
    cred_summary:
      total_found: <count>
      types: [hash, key, ticket, ...]
      cred_ref_ids: [<id1>, <id2>, ...]
      spray_candidates: <count of testable creds>
```

---

## Exit criteria

- Phase 1 GROUND complete: all authoritative sources queried, credential map
  compiled and operator-approved
- Phase 2 HARVEST complete: all grounded locations checked through C2
- Phase 3 STORE complete: values in tuoni cred store, refs in engagement YAML
- Documentation updated in Obsidian (references only)
- Engagement YAML phase updated to `cred_harvest`
- No credential plaintext in ANY file outside tuoni cred store

## Failure modes

- **No agent on target**: STOP. Cannot harvest without C2 access. Direct
  operator to initial-access skill first.
- **Grounding returns no results**: warn operator — proceed with extreme
  caution, use only generic OS-level locations. Document gap.
- **Agent dies mid-harvest**: note last successful extraction. Check if
  target detected activity. Re-establish before continuing.
- **Lockout triggered during spray**: STOP ALL spray activity immediately.
  Document incident. Wait for lockout window to expire. Report to operator.
- **Credential store unavailable**: STOP. Do NOT store credentials anywhere
  else. Wait for tuoni availability.
