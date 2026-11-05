---
name: kali-bootstrap
description: "Verify Tuoni self-agent on Kali + deploy plugins. Run before engagement, during green-dev phase. Use when operator says 'bootstrap kali', 'check kali', or before first red-team mode switch."
modes: [red-team, purple, red-dev]
---

# Kali Bootstrap

Verify Kali spoke is ready for engagement: firewall, SSH, Tuoni API,
self-agent, plugins. Run in green-dev or red-dev mode before switching
to red-team.

## Prerequisites

- `.env` has `SPOKE_KALI_HOST` set
- Host VPN connected to range
- Container firewall initialized (`spoke-firewall.sh` ran at startup)

## SSH vs Tuoni user context

Two users, two paths — do not confuse them:

- **SSH to Kali** (`rt` user): container→kali management path. Uses the
  `kali` SSH alias (configured as `User rt` in `~/.ssh/config`). This is
  NOT outbound from Kali to targets, so `rt` is acceptable here.
- **Tuoni self-agent** (`root`): runs as root on Kali. All commands
  executed through the agent run as root. Per RT-SIG-001, outbound C2
  and lateral movement MUST use `root`, never `rt`-prefixed usernames.

## Procedure

### Step 1: Firewall Check

Verify Kali IP in container allow-list:

```bash
ipset test allowed-domains "$SPOKE_KALI_HOST"
```

If NOT in ipset: run `bash scripts/spoke-firewall.sh` and re-check.
If still failing: check `.env` has correct `SPOKE_KALI_HOST`.

### Step 2: SSH Auth Check

Test SSH authentication to Kali via the configured SSH alias:

```bash
ssh -o BatchMode=yes -o ConnectTimeout=5 kali whoami
```

If auth fails:
1. Print container pubkey: `cat ~/.ssh/id_ed25519.pub`
2. Tell operator: "Add this SSH key to kali — run `ssh-copy-id kali` from host, or paste into authorized_keys"
3. Wait for operator confirmation
4. Re-check SSH auth

### Step 3: Tuoni API Check

Test Tuoni server is running:

```bash
curl -sk --connect-timeout 5 "https://${SPOKE_KALI_HOST}:${SPOKE_KALI_C2_WEB_PORT:-8443}/api/v1/status"
```

If unreachable: SSH to Kali and check service status:
```bash
ssh kali systemctl status tuoni
```

### Step 4: Check for Self-Agent

Use `tuoni_agents_list` to find agent on Kali hostname.

If agent exists:
- Record agent ID
- Skip to Step 6 (verify)

### Step 5: Deploy Self-Agent (if missing)

1. List listeners via `tuoni_listeners_list` — find or create HTTPS listener
   on Kali localhost (127.0.0.1)
2. Create payload via `tuoni_payload_create` for Linux/x64
3. Download payload via `tuoni_payload_download` — save to local temp
4. SCP payload to Kali and execute via SSH:
   ```bash
   scp /tmp/payload kali:/tmp/agent && ssh kali 'chmod +x /tmp/agent && nohup /tmp/agent &'
   ```
5. Wait for agent to check in (poll `tuoni_agents_list`)

### Step 6: Verify Self-Agent

Send test commands through tuoni-mcp to Kali self-agent. Use the
standard tuoni-mcp command execution flow:

1. `tuoni_commands_search` — find a shell command (e.g. search "shell" or "execute")
2. `tuoni_command_describe` — get parameter schema
3. `tuoni_command_prepare` — validate with test command (`whoami`)
4. `tuoni_operation_execute` — run on Kali self-agent
5. `tuoni_command_get` — poll until result arrives

Verify:
- `whoami` returns `root`
- `ip addr` shows IP matching `SPOKE_KALI_HOST`
- `which nmap` confirms tools available

### Step 7: Deploy Plugins

Check tuoni-plugins are loaded:

```bash
bash scripts/deploy-tuoni-plugins.sh --check-only
```

If modules missing, deploy automatically:

```bash
bash scripts/deploy-tuoni-plugins.sh
```

This clones `Moon-Knight13/tuoni-plugins` (branch `refactor/overhaul-v2`),
runs `build_scripts.py` to inline shared code, SCPs built scripts to Kali
`/srv/tuoni/data/scripts/`, restarts tuoni-server, and verifies.

If GitHub access unavailable (disconnected range), deploy from backup:
- Backups live at `/srv/tuoni/data/scripts.bak.*` on Kali
- Restore: `ssh kali "sudo cp /srv/tuoni/data/scripts.bak.<timestamp>/tuoni_*.py /srv/tuoni/data/scripts/"`

Verify 16 TSE DynamicAlias modules available (see tuoni-plugins README
for full list: host-id, net-recon, vuln-assess, lateral-move, lateral-wmi,
get-system, persist-swarm, cred-dump, ad-enum, agent-watcher, collect-intel,
ioc-cleanup, log-clear, exfil-stage, payload-gen, route-hijack).

### Step 8: Dynamic Tool Discovery from llm-wiki

Before running static checks, read llm-wiki for additional tool
requirements discovered during prior engagements.

1. Search Obsidian for technique pages with tool requirements:
   `obsidian_search_vault` for `Tool Requirements` in `llm-wiki/wiki/techniques/`
2. Read `llm-wiki/wiki/tools/tools-needed.md` if it exists (auto-populated
   wishlist from blocked techniques)
3. Merge discovered tools with static manifest below
4. Any new tools found: add to appropriate tier and attempt install

This makes the manifest self-growing — each engagement that hits a
tooling gap feeds the next bootstrap run.

### Step 9: Verify and Install Tools

Run tool checks through Kali self-agent (tuoni-mcp commands). Six tiers:

**Tier 1: Stock Kali tools (verify present)**

Check these binaries exist via `which` on Kali agent. All should be
pre-installed on kali-linux-default. Report any missing as anomaly.

```
nmap masscan hydra medusa crackmapexec smbclient rpcclient enum4linux-ng
impacket-secretsdump impacket-wmiexec impacket-psexec impacket-smbexec
impacket-ntlmrelayx xfreerdp rdesktop sshpass proxychains4 chisel socat
gobuster feroxbuster nikto sqlmap responder searchsploit bloodhound-python
ldapsearch certipy evil-winrm hping3 tshark john hashcat wfuzz
```

**Tier 2: APT packages (install if missing)**

```bash
apt list --installed 2>/dev/null | grep -E 'redis-tools|postgresql-client'
```

If missing:
```bash
apt update && apt install -y redis-tools postgresql-client
```

These provide `redis-cli` (Redis exploitation) and `psql` (PostgreSQL RCE
via `COPY FROM PROGRAM`).

**Tier 3: Python packages (install if missing)**

```bash
pip3 list 2>/dev/null | grep -iE 'pexpect|paramiko|coercer|mitm6|ldapdomaindump|adidnsdump|pypykatz|pcredz|netexec'
```

Install missing:
```bash
pip3 install pexpect paramiko coercer mitm6 ldapdomaindump adidnsdump pypykatz Pcredz netexec
```

Purpose by package:
- `pexpect`: interactive SSH automation (pfSense menu shells, custom prompts)
- `paramiko`: programmatic SSH with keyboard-interactive auth control
- `coercer`: force Windows machine authentication (PetitPotam, PrinterBug, DFSCoerce)
- `mitm6`: IPv6 DNS takeover for NTLM relay in AD
- `ldapdomaindump`: dump AD via LDAP to HTML/JSON/grep
- `adidnsdump`: dump AD-integrated DNS zones (find hidden hosts)
- `pypykatz`: pure-Python mimikatz (parse LSASS dumps offline on Kali)
- `Pcredz`: extract credentials from PCAP captures
- `netexec`: CrackMapExec successor, better maintained

**Tier 4: Binary tools (download if missing)**

Check and install on Kali filesystem:
```bash
test -x /opt/tools/ligolo-agent || echo "ligolo-ng missing"
test -x /opt/tools/kerbrute || echo "kerbrute missing"
```

If missing, download from GitHub releases (requires internet or pre-staged):
- `ligolo-ng`: TUN-level tunnel through footholds (better than proxychains)
- `kerbrute`: Kerberos user enum + password spray (no lockout on enum)

Install to `/opt/tools/` and symlink to `/usr/local/bin/`.

**Tier 5: .NET assemblies for Tuoni execute-assembly**

Stage in `/opt/assemblies/` on Kali for quick deployment through Tuoni
agents on Windows targets:

```
SharpHound.exe    — BloodHound AD data collector
Rubeus.exe        — Kerberos abuse (roasting, ticket manipulation)
Certify.exe       — ADCS enumeration and abuse
Seatbelt.exe      — Host situational awareness
```

These run on Windows agents via `execute-assembly`, not on Kali directly.
Download from GhostPack/BloodHound repos if not pre-staged.

**Tier 6: Custom/range-specific tools**

```bash
test -f /opt/tools/icmp_c2.py || echo "icmp_c2.py missing"
```

- `icmp_c2.py`: ICMP backdoor trigger (SCP from deploy infra if available)

Report summary: tools verified N, installed N, missing N (with names).

### Step 10: Record State

Update engagement YAML:
```yaml
kali_agent_id: <agent-id-from-step-4-or-5>
tools_verified:
  stock_kali: <count>/35
  apt_packages: [redis-tools, postgresql-client]
  pip_packages: [pexpect, paramiko, coercer, mitm6, ...]
  binaries: [ligolo-ng, kerbrute]
  assemblies: [SharpHound, Rubeus, Certify, Seatbelt]
  custom: [icmp_c2.py]
  missing: [<any that could not be installed>]
  verified_at: <ISO-8601>
```

If no engagement YAML exists: print agent ID and tool summary for operator.

## Exit Criteria

All must be true:
- [ ] Kali IP in container firewall
- [ ] SSH auth working (key accepted)
- [ ] Tuoni API responding on :8443
- [ ] Self-agent connected and executing commands
- [ ] tuoni-plugins loaded (16 modules)
- [ ] Stock Kali tools verified present
- [ ] redis-tools + postgresql-client installed
- [ ] Python packages installed (pexpect, paramiko, coercer, mitm6, etc.)
- [ ] Agent ID + tool manifest recorded in engagement YAML

## Attack Chain Reference

Tools combine across layers to unlock specific attack chains:

**Redis RCE** (needs creds): `redis-cli` AUTH, CONFIG SET dir/dbfilename,
write SSH key or cron, or MODULE LOAD for .so RCE.

**PostgreSQL RCE** (needs creds): `psql` COPY FROM PROGRAM for command
execution, lo_import/lo_export for file read/write.

**NTLM relay** (AD): `responder` + `impacket-ntlmrelayx` capture and relay.
`Coercer` forces machine auth. `mitm6` for IPv6 DNS takeover.

**Pivoting**: Tuoni `socks5` on foothold + `proxychains4` on Kali wraps all
tools. `ligolo-ng` for TUN-level routing (tools work natively).

**pfSense access**: `pexpect` navigates menu shell (option 8 = Shell).
`jump-ssh` SCP bypasses login shell. Extract `/cf/conf/config.xml` for
admin hash, VPN PSKs, firewall rules.

**AD attack path**: `bloodhound-python` or SharpHound via execute-assembly
for path mapping. `kerbrute` for user enum. `certipy` for ADCS abuse.
`Rubeus` for Kerberoasting/AS-REP roasting through Tuoni agent.
