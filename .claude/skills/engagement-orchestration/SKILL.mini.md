<!-- Mini variant for subagent dispatch. Full version: SKILL.md -->
---
name: engagement-orchestration
description: "Master orchestration flow for red-team engagements. Defines phases, thread patterns, Obsidian-as-bus, and handoffs. Load at engagement start before dispatching any threads."
modes: [red-team, purple, ctf]
disable-model-invocation: true
---

# Engagement Orchestration — Mini

Master-level orchestration for red-team engagements. Defines end-to-end flow, thread dispatch, shared state, phase handoffs.

## Architecture

```
Master thread: orchestration, review, approval
T3 threads: execution (one phase per thread)
Kali spoke: ALL offensive traffic (never from hub)
Obsidian llm-wiki: shared state bus
Tuoni cred store + Obsidian: credentials in both
Engagement YAML: thin gate file only
```

## Engagement Types

```yaml
type: black-box  # optional — omit for standard
```

Standard: query all authoritative sources. Black-box: skip ALL authoritative sources, go straight to live enum + reference MCPs. When any source returns empty regardless of type, fall through to next tier.

## Intel Source Priority

1. Providentia (range-intel MCP) — ground truth
2. GitLab READMEs (range-intel MCP) — deploy config, defaults
3. Wiki collections (outline-readonly) — prior research
4. Operator notes (note-search) — runs in PARALLEL with tiers 1-3, not fallback
5. FALLBACK: blind nmap + research MCPs (always available)

Engagement page records `intel_source: providentia | blind_scan | mixed`.

## Execution Model — Pre-Beacon vs Post-Beacon

**Pre-Beacon:** Operator is execution surface. Gets beacon on target. Harness: payload staging, listener setup. No target interaction without agent.

**Post-Beacon:** Moment agent calls back → harness takes over ALL target interaction. Immediately. No transition period.
1. Confirm agent: `tuoni_agent_command` (whoami)
2. Announce takeover
3. Invoke persist-swarm (immediate, non-negotiable)
4. Continue kill chain

**Human-in-the-loop = DEGRADED mode.** Push back if operator sends commands after beacon live.

## Phase 0: Pre-Engagement (master inline)

1. `/spoke-health` — all MCPs + SSH green (warn if Obsidian not running)
2. `engagement-state` — create gate YAML + Obsidian page
3. `pre-engagement-cache` — cache Providentia + wiki (skip if black-box)
4. `kali-bootstrap` — verify Tuoni + plugins on Kali

**Gate:** Steps 1, 2, 4 must pass. Step 3 skipped for black-box.

## Phase 1: Reachability + Enumeration (one thread)

```
Thread: REACHABILITY-ENUM
  Skill: recon (Phase 0)
  From Kali: ip route → nmap -sn → nmap -sV -sC -p- → Providentia cross-ref → note-search per host
  Output: Obsidian target pages § Services, engagement page § Reachability, raw/ sweep
```

Master reviews reachability + services. Selects targets. Gets RT-TGT-001 approval. ScheduleWakeup to monitor.

## Phase 2: Per-Target Attack (phased threads)

### Thread A: RESEARCH (parallel OK across targets)

```
  Skill: recon (Phase 3 — vuln analysis)
  Per service:version: cve-mcp, hacktricks-mcp, nuclei-mcp, outline-readonly, range-intel, lolbins-mcp, mitre-mcp, note-search
  Output: Obsidian target § Attack Vectors (ranked + PoC)
```

Master reviews vectors. RESEARCH GATE: per-service evidence must exist before exploit dispatch.

### Thread B: EXPLOIT (sequential per target)

```
  Skill: initial-access (Phase 2-3)
  GATE: research evidence per service exists
  From Kali: ranked vectors. 3-5 defaults MAX, then CVE only. Never brute force.
  If foothold: deploy Tuoni agent + persist-swarm ROUND 1 HERE
  Output: Obsidian target § Access
```

**Auto-chain:** Thread B foothold + persist round 1 → auto-dispatch Thread C. No manual gate between exploit and post-access.

### Thread C: POST-ACCESS (auto-dispatched)

```
  Skills: discovery, cred-harvest, collect-intel, persist-swarm (round 2)
  Prerequisite: persist round 1 confirmed in Thread B

  IF ROOT/SYSTEM: discovery → persist round 2 → cred-dump (full) → hashcat if hashes → bloodhound paths → collect-intel → flag-hunt (CTF)
  IF USER: discovery → privesc attempt →
    Success: persist round 2 → full cred-dump → collect-intel → flag-hunt
    Fail: user-level cred-dump + intel, mark for revisit. Do NOT block.
  Output: Obsidian target § Persistence, Discovery, Creds, Intel, Privesc, Flags
```

## Phase 3: Lateral Movement

1. Master reads harvest + BloodHound paths from Obsidian
2. note-search per lateral target + technique
3. Select next target (RT-TGT-001, sequential)
4. New zone: SOCKS proxy through foothold FIRST
5. Dispatch lateral-move thread
6. Re-scan from new foothold (new zone only)
7. New hosts get full Phase 2: Thread A → B → C

## Thread Dispatch Rules

- One phase per thread. Short focused prompts. Context from Obsidian reads.
- Master reviews between phases. ScheduleWakeup to monitor.
- All execution from Kali. Hub = orchestration only.
- Obsidian is bus. YAML is thin gate. Creds in Tuoni store.
- Auto-chain exploit → post-access (persist round 1 = gate).
- Persist round 1 in exploit thread (RD-003).
- note-search at every phase.

## Failure Handling

| Failure | Action |
|---------|--------|
| Unreachable | Mark in Obsidian, skip |
| All vectors blocked | Document defense, next target |
| Persist fails | STOP all ops. Non-negotiable. |
| Privesc fails | Stay low-priv, user-level ops, mark revisit |
| Cred-dump empty | Next target, return when creds available |
| Research shortcut | Master rejects, re-dispatch |
| Brute force | OPSEC violation. Stop thread. |
| fail2ban triggered | STOP. 60-min cooldown. Alternate IP or target. |

## OPSEC Quick Reference

- Max 3-5 defaults per service. Never brute force.
- All traffic from Kali. Never hub.
- Unique payload per target (RT-SIG-002/003/004).
- GT excluded (RT-SCOPE-001).
- fail2ban: max 2 SSH attempts, 60-min cooldown.
- Two-round persistence.

## CTF Flow (mode: ctf)

Speed-oriented. No YAML, no OPSEC, no mandatory documentation.

**Phase 0:** Kali agent alive only.
**Phase 1:** Blind recon, parallel per CIDR. nmap sweep → service scan → research MCPs → ranked targets. Auto-dispatch, no approval gate.
**Phase 2:** One thread per target, full chain: exploit → flag-hunt → privesc → flag-hunt. Any exploit OK (Metasploit allowed). Parallel across targets.
**Phase 3:** Cred reuse spray (unlimited), AD enum if domain, parallel exploit threads.

Thread pattern: recon parallel per CIDR, exploit parallel per target, post-access combined with exploit thread, master inline OK.
