---
name: persist-swarm
description: "Deploy persistence on a target. Usage: /persist-swarm <hostname> — deploys operational + sleeper beacons via Tuoni."
---

# Persist Swarm

Deploy dual-beacon persistence on a compromised target. This skill is MANDATORY after any lateral movement (persist-on-lateral rule).

## Procedure

When operator invokes `/persist-swarm <hostname>`:

### 1. Validate
- Confirm target in approved list (RT-TGT-001)
- Confirm active agent exists on target (via tuoni-mcp)
- Check engagement YAML for target entry

### 2. Select Persistence Methods
Based on target OS (from Providentia/engagement YAML):

#### Linux targets
- Operational: cron job (beacon interval 30-120s)
- Sleeper: rc.local or systemd service (beacon interval 300-900s)
- Payload naming: platform-appropriate (e.g., crond, rsyslogd) per RT-SIG-003
- Binary size: 1-5 MB per RT-SIG-004

#### Windows targets
- Operational: scheduled task or service (beacon interval 30-120s)
- Sleeper: registry run key or WMI subscription (beacon interval 300-900s)
- Payload naming: platform-appropriate (e.g., svchost.exe, spoolsv.exe) per RT-SIG-003
- Binary size: 120-180 MB per RT-SIG-004

### 3. Generate Payloads
For each persistence method:
- Generate unique payload_id (RT-SIG-002 — never reuse across hosts)
- Use tuoni-mcp to create payload with correct listener
- Apply platform-appropriate naming and sizing

### 4. Deploy via C2
Using existing agent on target:
- Deploy operational beacon first (immediate C2 channel)
- Deploy sleeper beacon second (survival insurance)
- RT-TGT-002: all deployment through C2 tunnel, never upload tools directly

### 5. Verify
- Confirm both beacons check in
- Test operational beacon responsiveness
- Verify sleeper beacon on different listener if possible

### 6. Update Engagement YAML
Add to persistence section:
- target, method, beacon_interval, payload_id, type (operational/sleeper), status

## OPSEC Rules
- RT-SIG-002: unique payload_id per deployment
- RT-SIG-003: platform-appropriate filenames
- RT-SIG-004: right-sized binaries
- RT-TGT-002: no tools uploaded to target
- Persist-on-lateral: this skill MUST run after every lateral move before any other action
