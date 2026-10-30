---
name: lateral-move
description: "Lateral movement skill with mandatory persist-on-landing. Uses harvested credentials to move through the network per deployment order (RT-DEP-001). Establishes SOCKS proxies from footholds for Kali tool routing."
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

## Phases

### Phase 1: Target Selection

1. **Review Providentia** (range-intel MCP) for candidate targets:
   - Network topology: what can current foothold reach?
   - Host roles: prioritize per RT-DEP-001 deployment order
   - Team assignments: stay within engagement scope
2. **Match credentials to targets**:
   - Domain creds: which hosts are domain-joined?
   - Local admin: reuse across similar builds?
   - Service accounts: what systems do they access?
   - SSH keys: authorized on which hosts?
3. **Assess network path**:
   - Direct: foothold can reach target
   - Proxied: need SOCKS through intermediate foothold
   - Multi-hop: chain of proxies needed
4. **Present plan to operator**: target, credential, method, path

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
2. **Deliver payload**: stage on target using authenticated session
3. **Execute payload**: trigger execution via authenticated access
4. **Wait for callback**: monitor listener for agent check-in
5. **PERSIST IMMEDIATELY** (non-negotiable):
   - Deploy operational beacon (30s-2min callback)
   - Deploy sleeper beacon (4h-24h callback)
   - Verify both beacons survive reboot test if possible
6. **Discovery sweep** (only after persistence):
   - whoami, hostname, network config
   - Local users, groups, privileges
   - Network connections, routing table
   - Credential store locations (DO NOT harvest yet)

### Phase 5: Post-Lateral Assessment

After all planned lateral moves complete:

1. **Update engagement YAML** for each new host:
   - Phase, agent IDs, persistence status
   - Network position (what new nets are reachable?)
   - Discovery findings summary
2. **Assess new attack surface**:
   - New network segments reachable?
   - New credential harvesting opportunities?
   - Closer to high-value targets (DCs, critical servers)?
3. **Update proxy chain** if new routes discovered
4. **Document in Obsidian**:
   - `wiki/<hostname>-lateral.md`: how access was achieved
   - Update network topology map

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
