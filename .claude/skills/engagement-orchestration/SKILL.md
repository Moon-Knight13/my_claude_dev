---
name: engagement-orchestration
description: "Master orchestration flow for red-team engagements. Defines phases, thread patterns, Obsidian-as-bus, and handoffs. Load at engagement start before dispatching any threads."
modes: [red-team, purple]
---

# Engagement Orchestration

Master-level orchestration for red-team engagements. Defines the end-to-end
flow, thread dispatch patterns, shared state, and phase handoffs.

**Load this skill at engagement start.** All phase-specific skills (recon,
initial-access, persist-swarm, etc.) handle their own detail. This skill
defines how they connect.

## Architecture

```
Master thread (this session): orchestration, review, approval
T3 threads: execution (one phase per thread, short prompts)
Kali spoke: ALL offensive network traffic (never from hub)
Obsidian llm-wiki: shared state bus between all threads
Tuoni cred store: credentials (never plaintext in Obsidian)
Engagement YAML: thin gate file only (ID, mode, exclusions, wiki pointer)
```

## Intel Source Priority (with failover)

Query sources in this order. Lower tiers activate when higher tiers are
unavailable or return empty. Same Obsidian output format regardless of source.

```
1. Providentia (range-intel MCP) — ground truth if available
2. GitLab READMEs (range-intel MCP) — deploy config, known defaults
3. Wiki collections (outline-readonly) — prior research, vuln notes
4. FALLBACK: blind nmap scan + research MCPs (always available)
   Activates when tiers 1-3 return empty or are unreachable.
   Produces identical Obsidian target pages from live scanning.
   See recon skill "Blind Mode" section for pipeline details.
```

Engagement page records `intel_source: providentia | blind_scan | mixed`.
Downstream skills (initial-access, discovery, lateral-move) consume Obsidian
target pages and do not check intel source — format is identical.

## Phase 0: Pre-Engagement (master does directly)

Run these sequentially. No threads needed — master calls skills/MCPs inline.

1. `/spoke-health` — verify all MCPs + SSH spokes green
2. `engagement-state` skill — create thin YAML gate + Obsidian engagement page
3. `pre-engagement-cache` skill — cache Providentia + wiki + READMEs to Obsidian
4. `kali-bootstrap` skill — verify Tuoni + self-agent + plugins + tools on Kali

**Gate:** All 4 must pass before Phase 1. Failures block engagement start.

## Phase 1: Reachability + Enumeration (one thread)

**Note:** Recon skill calls this "Phase 0" internally. Same thing — one scan, once.

**Purpose:** Scan once, write to Obsidian. No phase after this re-scans.

**If Providentia empty or unavailable:** recon skill activates Blind Mode
automatically. Pipeline is the same (nmap sweep → service scan → Obsidian),
but without Providentia cross-reference. Blind Mode produces identical
Obsidian target pages — downstream phases work unchanged. Engagement page
records `intel_source: blind_scan`.

```
Thread: REACHABILITY-ENUM
  Skill: recon (Phase 0 section, or Blind Mode if no Providentia)
  From Kali self-agent:
    1. ip route → routable subnets
    2. nmap -sn per subnet → live hosts
    3. nmap -sV -sC -p- per live host → service:version
    4. Cross-ref with Providentia (skip if blind mode)
  Output:
    Per host → Obsidian target page § Services
    Summary → Obsidian engagement page § Reachability
    Raw → llm-wiki/raw/network-sweep-<date>.md
```

**Master reviews** reachability matrix + service tables.
Selects targets. Gets RT-TGT-001 operator approval.
Sets up ScheduleWakeup to monitor thread.

## Phase 2: Per-Target Attack (phased threads, master between each)

For EACH approved target, dispatch threads sequentially. Master reviews
between phases. Threads are short and focused — context comes from Obsidian.

### Thread A: RESEARCH (parallel OK across targets)

```
  Skill: recon (Phase 3 — vulnerability analysis)
  Input: reads Obsidian target page § Services
  Runs per service:version:
    - cve-mcp: cve_by_product → cve_enrich → exploit_search → kev_check
    - hacktricks-mcp: search → outline → section → cheatsheet
    - nuclei-mcp: nuclei_scan against target
    - outline-readonly: vulns-docs for service type
    - range-intel: range_host with README → deploy config
    - Obsidian: prior engagement findings
    - lolbins-mcp: analyze_opsec_risk per technique
    - mitre-mcp: technique IDs + detection sources
  Output → Obsidian target page § Attack Vectors (ranked, with PoC details)
  Also → llm-wiki/wiki/vulnerabilities/<cve>.md per finding
```

**Master reviews** ranked vectors. Approves execution order.
RESEARCH GATE: verify per-service evidence exists before dispatching exploit.

### Thread B: EXPLOIT (sequential per target, operator-approved vectors)

```
  Skill: initial-access (Phase 2-3)
  Input: reads Obsidian target page § Attack Vectors
  GATE CHECK: research evidence per service exists (or reject back to master)
  From Kali: execute ranked vectors
    - 3-5 default creds MAX per service, then CVE exploits only
    - Never brute force. Never hydra/medusa as primary vector.
  If foothold: deploy Tuoni agent (unique payload per RT-SIG rules)
  Output → Obsidian target page § Access (agent ID, privilege level)
  If blocked → Obsidian target page § Blocked (root cause per vector)
```

**Master reviews.** If foothold → dispatch Thread C. If blocked → analyze
root cause, adjust approach or move to next target.

### Thread C: POST-ACCESS (sequential steps, one thread)

```
  Skills: persist-swarm, discovery, cred-harvest, collect-intel
  Input: reads Obsidian target page § Access
  Steps (in order, do not skip):
    1. persist-swarm ROUND 1 (low-priv dual-beacon)
    2. discovery (invoke discovery skill: host-id → ad-enum → net-recon)
       If domain-joined: trigger bloodhound-python collection
    3. get-system recon_only → privesc exploit → verify root/SYSTEM
    4. persist-swarm ROUND 2 (elevated dual-beacon)
       Archive round 1 once round 2 confirmed
    5. cred-dump (requires root/SYSTEM)
       Store in Tuoni cred store. Refs only in Obsidian.
       If crackable hashes: hashcat-mcp MANDATORY before lateral planning
       Query bloodhound-mcp for paths new creds unlock
    6. collect-intel sweep (config dirs, keys, tokens, .env files)
  Output → Obsidian target page (§ Persistence, § Discovery, § Creds, § Intel)
```

**Master reviews** cred harvest + discovery results → lateral decision.

## Phase 3: Lateral Movement (repeat Phase 1-2 from new position)

```
  Skill: lateral-move
  Thread pattern: one thread per lateral target (master approves each)
  
  1. Master reads harvest results + BloodHound paths from Obsidian
  2. Selects next target (RT-TGT-001 approval — sequential, not parallel)
  3. If new zone: set up SOCKS proxy through foothold FIRST
  4. Dispatch lateral-move thread (handles SOCKS + payload + persist internally)
  5. Re-run Phase 1 scan from new foothold (new vantage point, new zone only)
  6. Newly-discovered hosts get full Phase 2 treatment:
     Thread A (RESEARCH) → Thread B (EXPLOIT) → Thread C (POST-ACCESS)
```

Each foothold is a new Phase 1 sweep point. Expand the map, don't re-scan
what's already in Obsidian.

## Thread Dispatch Rules

| Rule | Why |
|------|-----|
| One phase per thread | Prevents shortcutting research to try passwords |
| Short focused prompts | Context comes from Obsidian reads, not prompt |
| Master reviews between phases | Catches skipped steps, approves vectors |
| ScheduleWakeup to monitor | Don't wait for operator to ask "status" |
| All execution from Kali | Hub is orchestration only, never offensive traffic |
| Obsidian is the bus | Threads read previous phase, write their phase |
| Engagement YAML is thin gate | ID + mode + exclusions + wiki pointer only |
| Credentials in Tuoni store | Refs in Obsidian, never plaintext anywhere |

## Failure Handling

| Failure | Action |
|---------|--------|
| Target unreachable | Mark FILTERED/UNREACHABLE in Obsidian, skip |
| All vectors blocked | Document defense posture in Obsidian, move to next target |
| Persist fails | STOP all ops on host. Persistence is non-negotiable. |
| Privesc fails | Stay low-priv. Cred-dump limited. Document what's available. |
| Cred-dump empty | Move to next target. Return when creds available from elsewhere. |
| Thread shortcuts research | Master catches in review. Reject, re-dispatch with correction. |
| Brute force attempted | OPSEC violation. Log incident. Stop thread. |
| fail2ban triggered | STOP all attempts to target. Log OPSEC incident. 60-min cooldown. Try alternate source IP or target. |

## OPSEC Quick Reference

- Max 3-5 default creds per service. Never brute force.
- All traffic from Kali. Never hub.
- Unique payload per target (RT-SIG-002/003/004).
- GT accounts excluded (RT-SCOPE-001).
- fail2ban: max 2 SSH attempts, 60-min cooldown if banned.
- Exploit hygiene: extract technique from public PoC, adapt, never run unmodified.
- Two-round persistence: low-priv on landing, high-priv after escalation.
