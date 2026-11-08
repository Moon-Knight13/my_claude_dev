---
name: discovery
description: "Post-compromise host and network enumeration skill. Runs after persistence is established. Compares actual state against Providentia expected state. Feeds cred-harvest and lateral-move skills."
modes: [red-team, purple]
---

# Discovery — Post-Compromise Enumeration

## When to use

After persistence is confirmed on a new host. Systematic enumeration
to feed credential harvesting and lateral movement planning.

Active in: **red-team** mode only.

## Entry criteria

- Persistence confirmed (operational + sleeper beacons active)
- Host in engagement YAML with `phase: initial_access` or `lateral_move`

## OPSEC Rules — ENFORCED

- RT-TGT-002: no tools uploaded. Use native OS commands via tuoni agent.
- All enumeration through tuoni-mcp agent commands.
- Minimize command volume — defenders monitor for enumeration bursts.
- **RT-SCOPE-001:** GT (green team) accounts OUT OF SCOPE. When enumerating
  users, sessions, or logged-on accounts, skip any gt-prefixed entries. If gt
  sessions appear in `who`, `query user`, or process lists, ignore them. Never
  include gt accounts in lateral movement target lists or credential source maps.

## Thread Orchestration

Discovery runs INLINE within the post-access thread (same thread as
initial-access Phase 4 or lateral-move post-landing). Reads and writes
the Obsidian target page. Engagement YAML gets phase status only.

## Plugin-First Policy (ENFORCED)

Use tuoni-plugins before raw sh commands. Plugin benefits: structured output,
Tuoni Discovery tab auto-population, consistent OPSEC, audit trail.

| Action | Plugin | Module/Config | Instead of |
|--------|--------|---------------|------------|
| Full host enumeration | host-id | (default) | Manual whoami/uname/ip |
| OSPF/routing dump | net-recon | routing_recon | `vtysh -c "show ip ospf"` |
| Web service fingerprint | net-recon | web_fingerprint | `curl`/`nmap` on HTTP |
| Host/service discovery | net-recon | (default) + discovery=true | manual port scan + `arp -a` |
| Network interface enum | net-recon | (default) | `ip addr; ip route` |
| Domain/workgroup detect | ad-enum | (default) | Manual `net user /domain` |
| User/group enumeration | ad-enum | users/groups | Manual `net user`, `getent` |
| Config sweep for keys | collect-intel | (default) | Manual find/grep |

**Run `host-id` first** — gets OS, hostname, users, network in one call.
Then `ad-enum` for domain membership. Then `net-recon routing_recon` for
network position. Raw `sh` commands only when plugin fails.

**BloodHound collection:** If domain-joined host and bloodhound-python
available on Kali, run SharpHound/bloodhound-python collection via SSH
and ingest data. This feeds lateral-move BloodHound path queries.

## Fork Agent Parallelism

When discovering on multiple hosts simultaneously, use fork agents:
- One fork per target host (each runs plugin commands on its agent)
- Coordinator merges Discovery results and updates engagement YAML
- Sequential within each host; parallel across hosts

## Procedure

### Step 1: Host Enumeration

**Preferred: use tuoni-plugins.** Run net-recon module via tuoni command
workflow (commands_search → command_describe → command_prepare →
operation_execute). Falls back to raw commands below only when plugin
unavailable or fails.

Execute via tuoni agent commands (native OS tools only):

**Identity:**
- `whoami /all` (Windows) / `id; whoami` (Linux)
- `hostname`
- `systeminfo` (Windows) / `uname -a; cat /etc/os-release` (Linux)

**Users and groups:**
- `net user` / `net localgroup administrators` (Windows)
- `cat /etc/passwd; cat /etc/group` (Linux)
- Domain users if domain-joined: `net user /domain`

**Network:**
- `ipconfig /all` (Windows) / `ip addr; ip route` (Linux)
- `netstat -ano` (Windows) / `ss -tlnp` (Linux)
- `arp -a` (both)
- DNS config: `nslookup` / `cat /etc/resolv.conf`

**Services:**
- `sc query state= all` (Windows) / `systemctl list-units` (Linux)
- Scheduled tasks: `schtasks /query` / `crontab -l; ls /etc/cron.*`
- Running processes: `tasklist /v` / `ps auxf`

**Security:**
- AV/EDR products: process names, service names
- Firewall rules: `netsh advfirewall show allprofiles` / `iptables -L`
- Logging config: audit policy, syslog forwarding

**Filesystem:**
- Interesting directories: user profiles, web roots, config dirs
- Recent files: `dir /o-d /t:w` / `find / -mtime -7 -type f`
- Mounted shares: `net use` / `mount`

### Step 1.5: LOLBins Environment Analysis (ENFORCED)

After host enumeration, pipe output to lolbins-mcp for structured analysis:

1. **`analyze_environment`**: feed enumeration output to create lolbins environment session
2. **`discover_chains`**: find multi-step attack chains from environment assessment
3. **`find_escalation_paths`**: identify privilege escalation paths (feeds cred-harvest)
4. **`find_persistence_paths`**: identify persistence options (feeds persist-swarm)
5. **`analyze_opsec_risk`**: assess OPSEC risk of planned enumeration commands

This creates an environment context that all subsequent lolbins calls
(find_credential_access, find_lateral_movement, build_attack_plan) can use.
Without this step, lolbins-mcp is nearly useless.

### Step 1.7: Tuoni Discovery ↔ Providentia Reconciliation

Compare `tuoni_hosts_list` against `range_targets` for this host's network segment:
- **Hosts Tuoni sees but Providentia doesn't** = rogue systems (high-value finding)
- **Hosts Providentia lists but Tuoni hasn't reached** = remaining attack surface
- Document discrepancies in engagement YAML `discovery.reconciliation`

### Step 2: Compare Against Providentia

Query range-intel MCP for expected host state:
- Expected OS, services, IPs, role
- Expected network connections

**Document discrepancies** — these are high-value findings:
- Unexpected services = potential attack surface
- Missing expected services = possible prior compromise
- Extra network connections = unexpected routes
- Extra users = potential persistence by others

### Step 3: Credential Source Identification

Map credential storage locations (DO NOT harvest yet):

| Source | Windows | Linux |
|--------|---------|-------|
| Hashes | SAM, NTDS.dit | /etc/shadow |
| Cached | lsass, credential manager | ssh-agent, keyrings |
| Config | web.config, appsettings | .env, config files |
| Keys | Certificate store | ~/.ssh/, /etc/ssl/ |
| Browser | Chrome/Edge credential store | Firefox profiles |
| History | PowerShell history | .bash_history |

Report locations to operator. Handoff to cred-harvest skill.

### Step 4: Lateral Movement Opportunity Mapping

Identify paths to other hosts:
- Network segments reachable from this host
- Trust relationships (domain trusts, SSH keys to other hosts)
- Shared resources (file shares, databases)
- Service accounts running on this host (may have broader access)

Cross-reference with Providentia network topology to identify
high-value targets now reachable.

### Step 5: Document and Update State

**Engagement YAML — LEAN (detail goes to Obsidian):**
```yaml
targets:
  - hostname: <target>
    phase: discovery
    status: complete
    wiki_page: llm-wiki/wiki/targets/<hostname>.md
```

All discovery detail (users, services, network, security, cred sources,
lateral paths, discrepancies) goes to the Obsidian target page under
`## Discovery` section. YAML stays lean — status refs only.

**Obsidian (llm-wiki paths — ENFORCED):**

After enumeration completes, invoke `/log-finding` for each significant
discovery result. Then write:

```
llm-wiki/raw/<hostname>-discovery-<date>.md    # full enumeration dump
llm-wiki/wiki/targets/<hostname>.md            # update target page (template: target.md)
llm-wiki/log.md                                # changelog row
```

RT-SCOPE-001 reminder: exclude gt-prefixed accounts from all written output.

## Failure modes

- **Agent dies during enumeration**: use sleeper beacon to re-establish.
  Resume from where enumeration stopped.
- **Commands blocked by AV/EDR**: note which commands blocked. Use
  `lolbins analyze_opsec_risk` to find lower-risk alternatives, then
  research via HackTricks (`hacktricks_quick_lookup`).
- **Host not in Providentia**: flag as unknown host. Cannot compare
  expected vs actual. Report to operator.

## MCP Tool Reference (discovery phase)

| MCP | Tools to use | When |
|-----|-------------|------|
| tuoni-mcp | agent commands, `tuoni_hosts_list` | Host enumeration, Discovery reconciliation |
| range-intel | `range_host`, `range_targets_summary`, `range_networks` | Providentia comparison, network topology |
| lolbins-mcp | `analyze_environment`, `discover_chains`, `find_escalation_paths`, `analyze_opsec_risk` | Post-enum analysis |
| outline-readonly | `outline_search` (vulns-docs) | Check prior vuln research for this host role |
| obsidian-mcp | `obsidian_search_vault`, `obsidian_create_note`, `obsidian_add_tags` | Dedup + write + tag notes |
