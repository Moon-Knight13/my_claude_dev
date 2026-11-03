---
name: range-build
description: "Range infrastructure workflow using Providentia + catapult. Use when operator says 'build box', 'deploy box', 'check host', 'what IPs', 'network layout', or range infrastructure tasks in green-dev mode."
---

# Range Build Workflow

Providentia-first infrastructure workflow for green-dev mode. Build,
configure, and deploy exercise zone systems via catapult spoke.

## Truth Hierarchy

1. **Providentia** (range-intel MCP) — ground truth for networks, compute, IPs
2. **GitLab READMEs** (range-intel MCP) — deploy notes, config, known defaults
3. **Outline wiki** (outline-readonly MCP) — architecture docs, broader context

Never derive IPs, hostnames, or network topology from wiki tables or memory.
Always query Providentia fresh.

## Core Workflows

### Query Infrastructure State

Before any build work, understand current state:

```
range_environments                          # list available environments
range_networks env=dcm                      # all network segments
range_targets env=dcm team=<N>              # all hosts for team
range_targets env=dcm team=<N> role=<role>  # filter by role (dc, proxy, mail, etc.)
range_host env=dcm host_id=<id> team=<N>    # full detail on one host
range_tags env=dcm                          # available tags for filtering
```

### Investigate a Host

When operator asks about a specific box:

1. `range_targets` with role or tag filter to find host ID
2. `range_host` for full detail: OS, IPs, services, network membership
3. `range_vuln_lookup` if host has documented vulnerabilities
4. Check GitLab README (returned with host detail) for deploy notes

### Pre-Deploy Checklist

Before deploying via ctp-bridge:

1. **Verify in Providentia** — host record exists, IPs allocated, network assigned
2. **Read GitLab README** — understand current state, any deploy notes or warnings
3. **Check Outline** — architecture docs for zone/enclave design decisions
4. **Confirm with operator** — target, role, and any parameters
5. **Deploy** — use `/ctp-deploy` skill for catapult deployment

### Network Layout Review

When operator needs network understanding:

1. `range_networks` — all network segments with CIDRs and VLANs
2. `range_targets` per team — map hosts to networks
3. Cross-reference with Outline architecture docs for zone boundaries
4. Report: which networks are Control vs Exercise zone (SEG-001)

### Post-Deploy Validation

After deployment completes:

1. Re-query `range_host` — verify Providentia reflects expected state
2. SSH to host (if accessible) — verify services running
3. Compare deployed state against GitLab README expected state
4. Update GitLab README with any changes made

## Rules

- **DEV-002:** Providentia is single source of truth. Never override it.
- **DEV-005:** Requirement documented as GitLab issue before development.
- **NET-001:** Network segment changes require change management.
- **SEG-001:** R-Edge is interconnection between Control and Exercise zones.
- **SEG-005:** Exercise Zone systems MUST NOT authenticate against CRP AD DCs.

## Cache

range-intel caches Providentia responses. If data looks stale:

```
range_cache_refresh    # clear and rebuild cache
```
