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

## Procedure

### Step 1: Firewall Check

Verify Kali IP in container allow-list:

```bash
ipset test allowed-domains "$SPOKE_KALI_HOST"
```

If NOT in ipset: run `bash scripts/spoke-firewall.sh` and re-check.
If still failing: check `.env` has correct `SPOKE_KALI_HOST`.

### Step 2: SSH Auth Check

Test SSH authentication to Kali:

```bash
ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
    "${SPOKE_KALI_USER:-rt}@${SPOKE_KALI_HOST}" whoami
```

If auth fails:
1. Print container pubkey: `cat ~/.ssh/id_ed25519.pub`
2. Tell operator: "Add this SSH key to rt@kali — run `ssh-copy-id rt@<kali-ip>` from host, or paste into authorized_keys"
3. Wait for operator confirmation
4. Re-check SSH auth

### Step 3: Tuoni API Check

Test Tuoni server is running:

```bash
curl -sk --connect-timeout 5 "https://${SPOKE_KALI_HOST}:${SPOKE_KALI_C2_WEB_PORT:-8443}/api/v1/status"
```

If unreachable: SSH to Kali and check service status:
```bash
ssh rt@<kali> systemctl status tuoni
```

### Step 4: Check for Self-Agent

Use tuoni-mcp `tuoni_agents_list` to find agent on Kali hostname.

If agent exists:
- Record agent ID
- Skip to Step 6 (verify)

### Step 5: Deploy Self-Agent (if missing)

1. List listeners via `tuoni_listeners_list` — find or create HTTP listener
   on Kali localhost (127.0.0.1)
2. Generate Linux payload for Kali architecture via tuoni-mcp
3. Deploy payload to Kali:
   - Preferred: `tuoni_upload_file` to upload, then execute via SSH
   - Fallback: SCP payload to Kali, SSH to execute
4. Wait for agent to check in (poll `tuoni_agents_list`)

### Step 6: Verify Self-Agent

Send test commands through tuoni-mcp to Kali self-agent:

```
tuoni_send_command: whoami    → expect "root"
tuoni_send_command: ip addr   → verify Kali IP matches SPOKE_KALI_HOST
tuoni_send_command: which nmap → verify tools available
```

### Step 7: Deploy Plugins

Check tuoni-plugins are loaded:
- Use tuoni-mcp to list available modules
- If missing: upload plugin JARs via `tuoni_upload_file`
- Verify 12 TSE DynamicAlias modules available

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
- [ ] tuoni-plugins loaded (12 modules)
- [ ] Agent ID recorded in engagement YAML
