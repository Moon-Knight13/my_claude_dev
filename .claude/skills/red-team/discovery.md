---
name: discovery
description: "Post-compromise host and network discovery through C2 agent. Covers Linux, Windows, and network device enumeration. Structured output feeds cred-harvest and lateral movement planning. Use when operator says 'discovery', 'enumerate', or 'discover <hostname>'."
---

# Discovery Skill — Post-Compromise Enumeration via C2

## When to use

Operator invokes `/discovery <hostname>` to enumerate a compromised target.
Active in: **red-team** mode only.

## Entry criteria

- Active agent on target (tuoni-mcp confirms agent responsive)
- Target approved per RT-TGT-001 (in engagement YAML `targets` list)
- Persistence confirmed (operational + sleeper beacons)
- Agent responsive (heartbeat within expected interval)

## OPSEC Rules — ENFORCED

### RT-TGT-002: No Tools on Target

**NEVER** upload tools to the target. This means:
- No nmap, linpeas, winpeas, SharpHound, BloodHound, Seatbelt, or any
  third-party enumeration tool deployed to the target filesystem.
- All enumeration uses **native OS commands** executed through the C2 agent.
- Heavy processing and correlation happen on Kali, not on target.

### RT-TGT-001: Scope Discipline

- Confirm target is in the approved scope before running ANY enumeration.
- Discovered hosts from enumeration output are **NOT** automatically in scope.
  New targets found during discovery must be explicitly approved by the
  operator before any interaction.
- Present discovered hosts to operator: "Discovery found these adjacent
  hosts. Which should be added to scope?"

### Additional OPSEC

- Cross-reference discovery results against Providentia (range-intel MCP)
  to identify discrepancies — a mismatch is a high-value finding.
- Do NOT create accounts or modify existing accounts on target.
- Do NOT install packages, enable services, or change system configuration.
- Prefer low-noise commands (single reads) over noisy sweeps (port scans,
  recursive finds across entire filesystems).
- Space commands over time when stealth is required.

## Linux Discovery

All commands executed through C2 agent on target using native tools only.

### System Identification

```
hostname
whoami
id
uname -a
cat /etc/os-release
cat /etc/machine-id
hostnamectl 2>/dev/null
```

### Network Position

```
ip addr
ip route
ss -tlnp
ss -ulnp
arp -a
cat /etc/resolv.conf
cat /etc/hosts
ip neigh
```

### Users and Access

```
cat /etc/passwd
w
last -20
who
sudo -l
cat /etc/group
getent passwd
```

### Services and Scheduled Tasks

```
systemctl list-units --type=service --state=running
crontab -l
ls -la /etc/cron.d/
ls -la /etc/cron.daily/
cat /etc/crontab
systemctl list-timers
```

### Filesystem Reconnaissance

```
# SUID binaries (priv-esc surface)
find / -perm -4000 -type f 2>/dev/null

# Writable directories (staging, persistence)
find / -writable -type d 2>/dev/null | head -50

# Interesting configs
ls -la /etc/ssh/sshd_config
cat /etc/fstab
ls -la /opt/ /srv/ /var/www/
```

### Credential Locations (prep for cred-harvest skill)

Identify WHERE credentials may live. Do NOT harvest at this stage.

- `/etc/shadow` (readable?)
- `~/.ssh/` (keys present?)
- `~/.bash_history` (contains passwords?)
- `/etc/*.conf` (embedded credentials?)
- Environment variables (`env | grep -i pass`)
- Application config directories
- Process memory candidates (ssh-agent, gpg-agent)

## Windows Discovery

All commands executed through C2 agent on target using native tools only.

### System Identification

```
hostname
whoami /all
systeminfo
tasklist /v
ver
wmic os get caption,version,osarchitecture
```

### Network Position

```
ipconfig /all
netstat -ano
arp -a
route print
nslookup . 2>nul
```

### Domain Enumeration

```
net user /domain
net group "Domain Admins" /domain
net group "Enterprise Admins" /domain
nltest /dclist:
nltest /domain_trusts
gpresult /r
```

### Services and Scheduled Tasks

```
sc query
schtasks /query /fo list /v
reg query HKLM\Software\Microsoft\Windows\CurrentVersion\Run
reg query HKCU\Software\Microsoft\Windows\CurrentVersion\Run
wmic service list brief
```

### Shares and Resources

```
net share
net view
net view /domain
```

### Credential Locations (prep for cred-harvest skill)

Identify WHERE credentials may live. Do NOT harvest at this stage.

- SAM database accessibility
- LSA secrets (requires SYSTEM)
- DPAPI protected data locations
- Credential Manager vault entries (`cmdkey /list`)
- Browser credential stores
- Cached domain credentials
- Service account credentials in registry
- Unattend.xml / sysprep files
- Group Policy Preferences (cpassword)

## Network Device Discovery

For firewalls, routers, and switches accessed through C2 or jump host.
Adapt commands to vendor platform.

### Interfaces and Routes

```
# VyOS / Linux-based
show interfaces
show ip route
ip route show

# Cisco IOS
show ip interface brief
show ip route

# pfSense
ifconfig -a
netstat -rn
```

### ACL and Firewall Rules

```
# VyOS
show firewall
show configuration commands | grep firewall

# Cisco
show access-lists
show ip access-lists

# pfSense / iptables
iptables -L -n -v
pfctl -sr
```

### Routing Protocol Peering

```
# OSPF neighbors
show ip ospf neighbor

# BGP neighbors
show ip bgp summary
show bgp neighbors

# VyOS
show protocols ospf neighbor
show protocols bgp
```

### NAT Rules

```
# VyOS
show nat source rules
show nat destination rules

# Cisco
show ip nat translations

# iptables
iptables -t nat -L -n -v
```

### Connected Networks and Reachable Hosts

```
# ARP table (directly connected)
show arp
arp -a

# Routing table (reachable networks)
show ip route connected
show ip route summary
```

### Vendor-Specific Adaptations

- **Cisco IOS/IOS-XE**: `show running-config`, `show version`, `show cdp neighbors`
- **VyOS**: `show configuration`, `show version`, `show lldp neighbors`
- **pfSense**: Web GUI config export, `pfctl` commands, `/cf/conf/config.xml`
- **Linux-based routers**: Standard Linux commands plus routing daemon configs
  (`/etc/frr/`, `/etc/quagga/`, `/etc/bird/`)

## Output Format — Structured Discovery Report

Present results to operator in this structured format:

### Host Profile

- Hostname, OS, architecture, kernel/version
- Role classification (DC, web server, workstation, router, etc.)
- Domain membership and trust relationships
- Uptime and last reboot

### Network Position

- All interfaces with IPs and subnets
- Default gateway and routing table
- DNS configuration
- ARP neighbors (directly connected hosts)
- Reachable networks (from routing table)
- Listening services (with PIDs)

### Users and Access

- Current user and privilege level
- All local accounts and groups
- Domain accounts and group memberships (if domain-joined)
- Active sessions and recent logins
- Sudo/admin capabilities

### Services and Processes

- Running services with PIDs
- Scheduled tasks and cron jobs
- Startup programs and persistence mechanisms
- Notable processes (security tools, management agents)

### Attack Surface

- SUID binaries and writable directories (Linux)
- Service misconfigurations
- Unpatched software versions
- Credential storage locations identified
- Pivot opportunities (dual-homed, VPN clients, SSH keys to other hosts)

### Recommended Next Steps

Based on discovery results, recommend:
- Privilege escalation paths (if not already elevated)
- Credential harvest targets (specific locations for cred-harvest skill)
- Lateral movement targets (reachable hosts, available credentials)
- Additional discovery needed (adjacent hosts requiring scope approval)

## State Writes

### Engagement YAML Updates

```yaml
# engagement.yaml target entry updates
targets:
  - hostname: <target>
    phase: discovery
    os: <detected OS>
    arch: <architecture>
    role: <classified role>
    domain: <domain if joined>
    interfaces:
      - name: <iface>
        ip: <address>
        subnet: <cidr>
    routes: [<summary of routing table>]
    services: [<listening services>]
    users:
      current: <whoami output>
      privilege: <access level>
    attack_surface:
      suid: [<notable SUID binaries>]
      writable: [<notable writable paths>]
      cred_locations: [<identified credential stores>]
      pivot_targets: [<reachable hosts for lateral consideration>]
    discovery_timestamp: <ISO 8601>
```

### Obsidian Writes

```
raw/<hostname>-discovery-<date>.md     # Full command output dump
wiki/<hostname>-profile.md             # Structured host profile
wiki/<hostname>-network.md             # Network position and neighbors
```

## Integration

### Input From

- **recon skill**: Target research and Providentia data
- **initial-access skill**: Agent placement and initial foothold details
- Engagement YAML: approved target list, current phase

### Output To

- **cred-harvest skill**: Credential locations identified, privilege level,
  platform-specific harvest targets
- **lateral-move skill**: Network position, reachable hosts, pivot
  opportunities, available credentials

## Failure Modes

### Agent Dies Mid-Enumeration

- Note last successful command in engagement YAML
- Wait for agent reconnection (check sleeper beacon interval)
- If agent lost: flag to operator, may need re-exploitation
- Do NOT re-run completed commands — resume from where enumeration stopped

### Commands Blocked (AppLocker, SELinux, etc.)

- Note which commands were blocked and the security mechanism
- Research alternative native commands that achieve same result
- Document security controls as part of attack surface
- Blocked commands are valuable intel — they reveal defensive posture

### High-Noise Commands

- If stealth is priority, skip noisy commands (recursive finds, large queries)
- Present operator with noise/value tradeoff: "This command will generate
  <N> events. Proceed?"
- Prefer targeted queries over broad sweeps

### Network Device Access Limited

- Many network commands require enable/privileged mode
- Document current access level and what is visible
- Note commands that require elevation for follow-up

### Providentia Mismatch

- If discovered configuration differs from Providentia records, flag as
  **high-value finding** — may indicate unauthorized changes, compromise
  by another team, or configuration drift.
- Document both expected (Providentia) and actual (discovered) values.
- Report to operator immediately.
