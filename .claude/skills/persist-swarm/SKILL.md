---
name: persist-swarm
description: "Dual-beacon persistence deployment. Deploys operational (short interval) + sleeper (long interval) beacons on every new target. Called by initial-access and lateral-move skills. Non-negotiable — no operations proceed without persistence."
modes: [red-team, purple]
---

# Persist-Swarm — Dual-Beacon Persistence

## Thread Orchestration

Persist-swarm runs INLINE within the initial-access or lateral-move thread
(same thread, not separate). Before deploying, read the Obsidian target page
(`llm-wiki/wiki/targets/<hostname>.md`) for: current privilege level, AV/EDR
findings from discovery, available persistence mechanisms. Write results back
to the same Obsidian page. Engagement YAML gets status refs only.

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

## Two-Round Persistence (MANDATORY)

Persist-swarm runs TWICE per target:

1. **Round 1 (low-priv)** — immediately on landing. User-level mechanisms
   (user cron, .bashrc, startup folder). Insurance if privesc kills session.
2. **Round 2 (high-priv)** — immediately after privilege escalation to
   root/SYSTEM. Elevated mechanisms (systemd, cron.d, service, scheduled task).
   These are the durable operational beacons.

Round 2 is MANDATORY. Cred harvest requires root/SYSTEM. Lateral movement
requires harvested creds. Skipping round 2 breaks the entire downstream chain.

After round 2 beacons confirmed stable, archive round 1 low-priv beacons
(they served their purpose as insurance during escalation).

## OPSEC Rules — ENFORCED

- RT-SIG-002: unique payload ID per beacon per host
- RT-SIG-003: platform-appropriate cover filenames
- RT-SIG-004: right-sized binary padding
- RT-SIG-001: `root` agent identity

## Plugin-First Policy (ENFORCED)

Use `persist-swarm` tuoni-plugin for deployment:

| Action | Plugin Config | Instead of |
|--------|--------------|------------|
| Enumerate persistence options | recon_only=true | Manual crontab/systemctl check |
| Deploy cron persistence | method=cron | Manual `crontab -e` |
| Deploy systemd persistence | method=systemd | Manual unit file creation |
| Deploy SSH key persistence | method=authorized_keys | Manual key injection |

Plugin handles: cover filenames, payload staging, mechanism installation,
verification. Use raw commands only when plugin fails and operator approves.

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

**LOLBins-informed selection** (lolbins-mcp — ENFORCED):
1. `find_persistence_paths`: discover all persistence options for this platform/environment
2. `analyze_opsec_risk`: assess detection risk for each candidate mechanism
3. Select TWO mechanisms with lowest OPSEC risk score that satisfy defense-in-depth

Default fallback (if lolbins-mcp unavailable):

| Priority | Windows | Linux |
|----------|---------|-------|
| 1st (operational) | Service | systemd service |
| 2nd (sleeper) | Scheduled task | cron job |
| Fallback | WMI subscription | .bashrc hook |

Mechanisms must be:
- Different from each other (survive single remediation)
- Appropriate to privilege level
- Quiet (low log generation, confirmed by `analyze_opsec_risk`)

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

### Step 6: Document (llm-wiki paths — ENFORCED)

Invoke `/log-finding` with persistence deployment outcome.
Update `llm-wiki/wiki/targets/<hostname>.md` with persistence section.
Write `llm-wiki/raw/<hostname>-persist-<date>.md` with deployment log.

Write persistence detail to Obsidian target page (`llm-wiki/wiki/targets/<hostname>.md`
under `## Persistence` section): beacon IDs, mechanisms, cover names, intervals, payload IDs,
verification status.

Engagement YAML stays lean:
```yaml
targets:
  - hostname: <target>
    persistence:
      round1: verified|pending|failed
      round2: verified|pending|failed
      wiki_page: llm-wiki/wiki/targets/<hostname>.md
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
