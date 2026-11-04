---
name: kali-bootstrap
description: "Verify Tuoni self-agent on Kali + deploy plugins. Run before engagement, during green-dev phase. Use when operator says 'bootstrap kali', 'check kali', or before first red-team mode switch."
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

### Step 8: Record State

Update engagement YAML:
```yaml
kali_agent_id: <agent-id-from-step-4-or-5>
```

If no engagement YAML exists: print agent ID for operator to record.

## Exit Criteria

All must be true:
- [ ] Kali IP in container firewall
- [ ] SSH auth working (key accepted)
- [ ] Tuoni API responding on :8443
- [ ] Self-agent connected and executing commands
- [ ] tuoni-plugins loaded (14 modules)
- [ ] Agent ID recorded in engagement YAML
