---
name: discovery
description: "Post-compromise host and network enumeration skill. Runs after persistence is established. Compares actual state against Providentia expected state. Feeds cred-harvest and lateral-move skills."
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

## Procedure

### Step 1: Host Enumeration

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

**Engagement YAML:**
```yaml
targets:
  - hostname: <target>
    phase: discovery
    discovery:
      users: [<local users>]
      admins: [<admin users>]
      services: [<running services>]
      network:
        interfaces: [<IPs>]
        routes: [<reachable networks>]
        connections: [<active connections>]
      security:
        av_product: <name>
        edr_product: <name>
        firewall: <enabled|disabled>
      cred_sources: [<identified locations>]
      lateral_paths: [<reachable targets>]
      discrepancies: [<vs Providentia expected>]
```

**Obsidian:**
```
raw/<hostname>-discovery-<date>.md    # full enumeration dump
wiki/<hostname>.md                    # update structured target page
```

## Failure modes

- **Agent dies during enumeration**: use sleeper beacon to re-establish.
  Resume from where enumeration stopped.
- **Commands blocked by AV/EDR**: note which commands blocked. Research
  alternative enumeration methods via HackTricks.
- **Host not in Providentia**: flag as unknown host. Cannot compare
  expected vs actual. Report to operator.
