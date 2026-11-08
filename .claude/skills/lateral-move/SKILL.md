---
name: lateral-move
description: "Lateral movement skill with mandatory persist-on-landing. Uses harvested credentials to move through the network per deployment order (RT-DEP-001). Establishes SOCKS proxies from footholds for Kali tool routing."
modes: [red-team, purple]
---

# Lateral Movement — Persist-on-Landing Enforced

## When to use

Operator has credentials or access that enables movement to another host.
Credentials harvested and stored in tuoni cred store.

Active in: **red-team** mode only.

## Entry criteria

- At least one active agent with persistence confirmed
- Credentials harvested (refs in engagement YAML)
- Target host in approved scope (RT-TGT-001)
- Target host exists in Providentia

## Scope Exclusion — ENFORCED

- **RT-SCOPE-001:** GT (green team) accounts OUT OF SCOPE. When selecting
  credentials for lateral movement, NEVER use gt-prefixed credentials even
  if present in Tuoni cred store. When targeting hosts, skip any host that
  appears to be a gt/green-team infrastructure node. If a lateral move lands
  in a gt session context, ABORT and report.

## MANDATORY: Persist-on-Landing

Every new target gets persistence IMMEDIATELY after lateral landing.
**No other operations until persistence confirmed.** This is non-negotiable.

Sequence on every new host:
1. Land (get agent callback)
2. Deploy operational beacon (short interval)
3. Deploy sleeper beacon (long interval)
4. THEN proceed with discovery/enumeration

## OPSEC Rules — ENFORCED

- RT-SIG-001: `root` agent identity for all lateral connections
- RT-SIG-002: unique payload per target host
- RT-SIG-003: platform-appropriate cover filename
- RT-SIG-004: right-sized binary padding
- RT-TGT-002: no tools uploaded to target
- RT-DEP-001: deployment order (ISPs > routers > firewalls > per-enclave)

## Plugin-First Policy (ENFORCED)

Use `lateral-wmi` tuoni-plugin (renamed from lateral-move):

| Action | Plugin Config | Instead of |
|--------|--------------|------------|
| Linux rsh lateral | method=rsh | Manual `rsh -l root` |
| Linux SSH lateral | method=ssh | Manual SSH commands |
| Windows WMI lateral | method=wmi | Manual WMI/WinRM |

Plugin auto-tries rsh first on Linux. Credentials pulled from Tuoni
credential store — requires creds stored via `tuoni_credential_add` first.

## Phases

### Phase 1: Target Selection

0. **Read source host Obsidian page** (`llm-wiki/wiki/targets/<source>.md`):
   - Harvested cred refs, discovered lateral paths, routes, proxy chain
   - This is the input — don't re-derive what discovery already found
1. **BloodHound AD paths** (bloodhound-mcp — AD environments):
   - Query shortest paths from current access to high-value targets (DA, EA)
   - Match BloodHound paths against available credentials
   - Identify kerberoastable SPNs, delegation abuse, NTLM relay opportunities
   - BloodHound is PRIMARY tool for "where to move next" in AD
2. **Review Providentia** (range-intel MCP) for candidate targets:
   - `range_networks`: full network topology
   - `range_targets_summary`: lightweight inventory per segment
   - `range_host`: detail for specific candidates
   - Host roles: prioritize per RT-DEP-001 deployment order
   - Team assignments: stay within engagement scope
3. **Match credentials to targets** (programmatic, not manual):
   - `tuoni_credentials_list` filter by realm/type against `range_targets` by network
   - Domain creds: which hosts are domain-joined?
   - Local admin: reuse across similar builds?
   - Service accounts: what systems do they access?
   - SSH keys: authorized on which hosts?
   - **If technique-scoring data available**: rank vectors by empirical success rate
4. **LOLBins lateral analysis** (lolbins-mcp):
   - `find_lateral_movement`: discover LOLBin-based lateral movement methods
   - `compare_platforms`: when moving Linux→Windows or vice versa, find technique equivalents
   - `analyze_opsec_risk`: assess detection risk for chosen lateral method
4. **Assess network path**:
   - Direct: foothold can reach target
   - Proxied: need SOCKS through intermediate foothold
   - Multi-hop: chain of proxies needed
5. **Present plan to operator**: target, credential, method, path, OPSEC risk score

### Phase 2: SOCKS Proxy Setup (if needed)

When foothold has routes to internal nets not reachable from Kali:

1. **Identify proxy host**: foothold with routes to target network
2. **Configure SOCKS5** via tuoni agent:
   - Tuoni built-in SOCKS proxy through C2 tunnel
   - Or custom SOCKS binary with cover name (RT-SIG-003)
3. **Configure Kali proxychains**:
   - Add SOCKS5 proxy entry pointing through C2 tunnel
   - Test connectivity to target through proxy
4. **Document proxy chain** in engagement YAML:
   ```yaml
   proxies:
     - host: <foothold>
       type: socks5
       port: <port>
       reaches: [<target networks>]
   ```

### Phase 3: Payload Staging

For each target (unique payload per RT-SIG-002):

1. **Generate payload** (tuoni-mcp):
   - Listener matched to network topology
   - Cover filename for target OS (RT-SIG-003)
   - Padded to expected size (RT-SIG-004)
2. **Stage delivery on Kali**:
   - HTTP: for targets that can reach Kali (direct or through proxy)
   - SMB: for Windows targets in same network segment
   - Agent relay: push through existing agent (tuoni file upload)
3. **Pre-flight per target**:
   - Confirm target IP in Providentia
   - Confirm credential ref exists in tuoni store
   - Confirm payload ID unique
   - Confirm listener active

### Phase 4: Execute Lateral Move

Per target, strictly sequential:

1. **Authenticate**: use credential from tuoni store via Kali tool
   - RDP, WinRM, SSH, SMB, WMI — match to credential type and target OS
   - Run from Kali (through SOCKS if needed)
   - **If credential fails: max 2 attempts per cred per target.** Do NOT retry
     or brute force during lateral movement. Mark cred invalid for this host.
2. **Deliver payload**: stage on target using authenticated session
3. **Execute payload**: trigger execution via authenticated access
4. **Wait for callback**: monitor listener for agent check-in
5. **Persist-swarm ROUND 1 (low-priv)** — invoke `persist-swarm` skill:
   - User-level dual-beacon (insurance during privesc)
   - **DO NOT PROCEED** to step 6 until persist-swarm confirms success
6. **Discovery sweep** (only after persistence):
   - whoami, hostname, network config
   - Local users, groups, privileges
   - Network connections, routing table
   - Credential store locations (DO NOT harvest yet)
7. **Privilege escalation** — invoke `get-system` plugin:
   - Run `recon_only=true` first to enumerate paths
   - Execute best privesc path for this platform
   - Verify elevated access (root/SYSTEM)
8. **Persist-swarm ROUND 2 (high-priv)** — invoke `persist-swarm` skill again:
   - Elevated dual-beacon (systemd + cron.d, or service + scheduled task)
   - Archive round 1 low-priv beacons once confirmed stable
   - **DO NOT PROCEED** to step 9 until high-priv persist confirmed
9. **Credential harvest** — invoke `cred-dump` plugin (requires root/SYSTEM):
   - Store in tuoni cred store, refs only in YAML/Obsidian
10. **Collect intel** — invoke `collect-intel` plugin:
    - Sweep config dirs for keys, tokens, .env files

### Phase 5: Post-Lateral Assessment

After all planned lateral moves complete:

1. **Update engagement YAML** for each new host:
   - Phase, agent IDs, persistence status
   - Network position (what new nets are reachable?)
   - Discovery findings summary
2. **Re-run recon Phase 0 from new position** (MANDATORY if new zone):
   - Dispatch net-recon sweep from new foothold via tuoni plugin
   - Map what this host can reach that Kali couldn't
   - Update reachability matrix in engagement YAML + Obsidian
   - Newly-reachable targets become candidates for next lateral wave
3. **Assess new attack surface**:
   - New network segments reachable?
   - New credential harvesting opportunities?
   - Closer to high-value targets (DCs, critical servers)?
4. **Update proxy chain** if new routes discovered
4. **Document in Obsidian (llm-wiki paths — ENFORCED)**:
   Invoke `/log-finding` for each lateral move outcome. Then write:
   - `llm-wiki/wiki/targets/<hostname>.md`: update target page with access method
   - `llm-wiki/wiki/techniques/<method>.md`: technique page for lateral method
   - `llm-wiki/raw/<hostname>-lateral-<date>.md`: raw command/session output
   - `llm-wiki/log.md`: changelog row
   - Update network topology in engagement wiki page

## State writes

```yaml
# engagement.yaml updates
lateral_moves:
  - from: <source host>
    to: <target host>
    method: <rdp|winrm|ssh|smb|wmi>
    credential_ref: <tuoni cred ID>
    timestamp: <ISO 8601>

targets:
  - hostname: <new target>
    phase: lateral_move
    access:
      agent_id: <tuoni agent ID>
      user: <username>
      privilege: <level>
    persistence:
      operational: <beacon ID>
      sleeper: <beacon ID>
    reached_via:
      proxy_chain: [<hop hosts>]
      method: <protocol used>

proxies:
  - host: <foothold hostname>
    type: socks5
    port: <port>
    reaches: [<network CIDRs>]
```

## Failure modes

- **Credential rejected**: do NOT retry more than once. Mark cred as
  failed for this target. Try alternate credential. If spray needed,
  follow lockout-safe procedure from cred-harvest skill.
- **Payload blocked**: AV/EDR detection. Do NOT attempt same payload.
  Research target's AV product, adjust payload characteristics.
- **No callback after execution**: check network path, check listener.
  May need SOCKS proxy. May need different delivery method.
- **Persistence fails**: STOP all operations on that host. Persistence
  is required before proceeding. Troubleshoot or abandon host.
- **Wrong host responds**: ABORT. Verify all Providentia data. Report
  to operator immediately.
