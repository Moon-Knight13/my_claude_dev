<!-- Mini variant for subagent dispatch. Full version: SKILL.md -->
---
name: cred-harvest
description: "Credential harvesting and privilege escalation skill. Research-first approach: determine WHERE creds live via HackTricks + wiki before harvesting. Store in tuoni cred store + wiki refs only. Lockout-aware credential spraying."
modes: [red-team, purple]
---

# Credential Harvest — Mini

## Entry criteria

- Active agent on target (engagement YAML phase: initial_access or later)
- Persistence confirmed (operational + sleeper beacons)
- Current access level documented

## OPSEC Rules — ENFORCED

- **RT-SCOPE-001:** GT accounts OUT OF SCOPE. Discard gt-prefixed creds from all harvests. Never store gt creds in Tuoni.
- **Credential spray:** MUST enumerate lockout policy first. Stay under threshold (N-1). One password per observation window. Unknown policy = single attempt only.
- **Storage:** Credentials in Tuoni cred store AND Obsidian. YAML gate uses `[cred-ref: <id>]` format.
- **RT-TGT-002:** No tools uploaded. All commands via tuoni agent.

## Plugin-First Policy (ENFORCED)

| Action | Plugin | Instead of |
|--------|--------|------------|
| Linux shadow/SSH/config/history | cred-dump (4 Linux modules) | `cat /etc/shadow` |
| Windows SAM/LSA/DPAPI/vault | cred-dump (8 Windows modules) | Manual registry reads |

After recovery: `tuoni_credential_add` → engagement YAML ref → Obsidian ref page.

## Phase 1: Credential Source Research

Before touching target, research WHERE credentials live:

1. **HackTricks** (hacktricks-mcp): `hacktricks_quick_lookup` + `get_hacktricks_cheatsheet` for platform cred locations
2. **LOLBins** (lolbins-mcp): `find_credential_access` + `find_escalation_paths` + `analyze_opsec_risk`
3. **Wiki vulns-docs** (outline-readonly): prior findings for host/role
4. **GitLab README** (range-intel): deploy-time creds, defaults
5. **Hashcat** (hashcat-mcp): `search_hash_types` + `estimate_crack_time` for feasibility
6. **MITRE** (mitre-mcp): T1003 sub-techniques + `get_data_sources` for detection. Fallback: lolbins + HackTricks for OPSEC notes.

Present to operator: "These credential sources exist. Which to target?"

## Phase 2: Privilege Escalation (if needed)

1. Research: HackTricks, LOLBins (`find_escalation_paths`), MITRE T1068
2. Enumerate via tuoni agent: privileges, SUID, services, kernel version, permissions
3. Execute custom escalation, verify new access level
4. **Persist-swarm ROUND 2 (MANDATORY)** — elevated dual-beacon before Phase 3. Verify BOTH beacons. Archive round 1 once confirmed.

## Phase 3: Credential Harvesting

Via tuoni agent, priority order:

1. **Memory** (highest value): lsass/ssh-agent, cached logons, session tokens
2. **File** (persistent): config files, SSH keys, browser stores, DB connection strings
3. **Registry/store** (Windows): SAM, LSA secrets, DPAPI, Credential Manager

### Post-Harvest: SID-500 Check (Windows)

`wmic useraccount where "sid like '%-500'" get name,sid` — if renamed, flag as "Built-in Administrator (renamed)". SID-500 bypasses UAC token filtering. Document in target page.

## Phase 3.5: Auto-Crack via Hashcat MCP

When hashes recovered:

1. `identify_hash` or `smart_identify_hash` → mode number
2. `auto_attack_strategy` → mode/rules/wordlists
3. `crack_hash` or `crack_multiple_hashes` (runs on Kali)
4. `analyze_cracked_passwords` → pattern analysis for spray

Skip for: SSH keys, API tokens, certificates, plaintext.

## Phase 4: Credential Processing — MANDATORY GATES

On Kali (NOT target):

1. Identify type: plaintext, NTLM, Kerberos, SSH key, API token, certificate
2. **GATE: `tuoni_credential_add`** — store each cred with source host, type, privilege. Must call before proceeding.
3. Record ref in engagement YAML (`[cred-ref: <tuoni_cred_id>]` format)
4. **GATE: engagement-state Update Credential Inventory** — pass tuoni_cred_id, username, domain, type, source_host, harvest_method, timestamp, status: untested. Wait for confirm.
5. Assess lateral value: domain admin? Service accounts? Match `tuoni_credentials_list` against `range_targets`. BloodHound path analysis per new domain cred. Query untested creds from engagement-state.
6. Document in Obsidian: target page cred details, template credential.md, tags `#engagement/<id> #phase/cred-harvest #target/<hostname>`

## Phase 4.5: Auto Cred-Reuse Spray (same-template hosts)

Runs automatically after Phase 4. Single attempt per host. Operator notified, not approval-gated.

1. `range_host(<source>)` → extract template/role/OS
2. `range_targets_summary()` → filter same OS + role/template, exclude: source, compromised, GT, out-of-scope, locked
3. **GATE: opsec-cred-spray** — enumerate lockout, calculate safe params, verify threshold >= 2
4. Execute: single attempt per candidate, sequential, wait per lockout window. Log every attempt. Success → Tuoni store + queue lateral-move. Failure → mark invalid. Ban → STOP all, report.
5. Report results, update engagement YAML + Obsidian, queue lateral-move for confirmed

## Phase 5: Credential Spray (operator approval required)

1. Enumerate lockout: AD `net accounts /domain`, Linux PAM, application testing
2. Plan: targets from Providentia, one password per lockout window
3. Execute from Kali: sequential, monitor lockouts, log all attempts. **Nextcloud trap:** HTTP 200 ≠ auth success; check body `statuscode`.
4. Success → Tuoni store + engagement-state inventory + mark `tested:success`
5. Failure → mark `tested:failed`

## State writes

```yaml
targets:
  - hostname: <target>
    phase: cred_harvest
    access:
      privilege: <updated if escalated>
    cred_refs:
      - id: <tuoni cred ref>
        type: <hash|plaintext|key|token|ticket>
        scope: <local|domain|service>
        lateral_targets: [<hostnames>]
```

Obsidian (ENFORCED): `/log-finding` per attempt, then write technique page, target page (refs only), raw dump `llm-wiki/raw/<host>-creds-<date>.md`, changelog row. Credential pages use `llm-wiki/templates/credential.md`. NEVER write actual cred values.

## Failure modes

- **Lockout triggered:** STOP all spray. Wait full window. Report.
- **AV/EDR blocks:** research evasion via HackTricks. Do NOT disable AV.
- **Insufficient privileges:** return to Phase 2. No path → escalate to operator.
- **No creds found:** document negative. Consider keylogging, Kerberoasting, AS-REP roasting per HackTricks.
