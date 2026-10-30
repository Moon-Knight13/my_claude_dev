---
name: persist-swarm
description: "Dual-beacon persistence deployment. Deploys operational (short interval) + sleeper (long interval) beacons on every new target. Called by initial-access and lateral-move skills. Non-negotiable — no operations proceed without persistence."
---

# Persist-Swarm — Dual-Beacon Persistence

## When to use

Immediately after gaining access to any new host. Called automatically by
initial-access and lateral-move skills. Also invoke manually when
re-establishing lost persistence.

Active in: **red-team** mode only.

## Rule

**Every new host gets TWO beacons before any other operation.**

1. Operational beacon — short callback (30s to 2min)
2. Sleeper beacon — long callback (4h to 24h)

No discovery, no enumeration, no credential harvesting, no lateral movement
until BOTH beacons are confirmed active.

## OPSEC Rules — ENFORCED

- RT-SIG-002: unique payload ID per beacon per host
- RT-SIG-003: platform-appropriate cover filenames
- RT-SIG-004: right-sized binary padding
- RT-SIG-001: `root` agent identity

## Procedure

### Step 1: Assess host environment

From initial agent (the one that just landed):

1. **OS identification**: Windows/Linux/network device
2. **Privilege level**: what can we persist as?
3. **AV/EDR presence**: what's running? (process list)
4. **Persistence mechanism availability**:
   - Windows: services, scheduled tasks, registry run keys, WMI subscriptions, startup folder
   - Linux: cron, systemd services, rc.local, .bashrc/.profile, SSH authorized_keys
   - Network device: config persistence, scheduled scripts

### Step 2: Select persistence mechanisms

Choose TWO different mechanisms (defense-in-depth):

| Priority | Windows | Linux |
|----------|---------|-------|
| 1st (operational) | Service | systemd service |
| 2nd (sleeper) | Scheduled task | cron job |
| Fallback | WMI subscription | .bashrc hook |

Mechanisms must be:
- Different from each other (survive single remediation)
- Appropriate to privilege level
- Quiet (low log generation)

### Step 3: Generate payloads

Via tuoni-mcp (`tuoni_payload_create`), two payloads per host:

**Operational beacon:**
- Callback interval: 30s - 2min (active operations)
- Jitter: 10-30%
- Cover filename per RT-SIG-003:
  - Windows: `svchost.exe`, `RuntimeBroker.exe`, `SearchIndexer.exe`
  - Linux: `crond`, `systemd-resolved`, `dbus-daemon`
- Padded per RT-SIG-004
- Unique payload ID (RT-SIG-002)

**Sleeper beacon:**
- Callback interval: 4h - 24h (survival)
- Jitter: 30-50% (blend with daily patterns)
- Different cover filename from operational
- Different payload ID
- Different persistence mechanism

### Step 4: Deploy persistence

Via tuoni agent commands on target:

1. **Upload operational payload** (tuoni file upload through agent)
2. **Install operational persistence mechanism**
3. **Verify operational beacon** — wait for independent callback
4. **Upload sleeper payload**
5. **Install sleeper persistence mechanism**
6. **Verify sleeper beacon** — wait for independent callback

### Step 5: Verify survival

If possible (and operator approves):

1. Kill initial landing agent
2. Verify operational beacon maintains contact independently
3. Verify sleeper beacon check-in at expected interval

### Step 6: Document

Update engagement YAML:
```yaml
targets:
  - hostname: <target>
    persistence:
      operational:
        beacon_id: <tuoni agent ID>
        mechanism: <service|cron|task|etc>
        cover_name: <filename used>
        interval: <callback seconds>
        payload_id: <unique ID>
      sleeper:
        beacon_id: <tuoni agent ID>
        mechanism: <different mechanism>
        cover_name: <filename used>
        interval: <callback seconds>
        payload_id: <unique ID>
      verified: <true|false>
      verified_at: <ISO 8601>
```

## Beacon recovery

When a beacon goes silent:

1. Check if OTHER beacon still active (that's why we have two)
2. If sleeper alive: use it to redeploy operational
3. If operational alive: check sleeper, redeploy if needed
4. If BOTH silent: target may be remediated. Report to operator.
   Re-exploitation required (back to initial-access skill).

## Failure modes

- **AV blocks payload**: research specific AV product via HackTricks.
  Adjust payload characteristics. Do NOT disable AV.
- **Insufficient privileges for persistence**: use available mechanisms
  (user-level cron, startup folder, .bashrc). Note reduced resilience.
- **Single beacon only**: acceptable temporarily. Document risk. Deploy
  second ASAP. Flag in engagement YAML `verified: false`.
- **Both beacons fail to persist**: STOP operations on host. Persistence
  is mandatory. Report to operator for decision.
