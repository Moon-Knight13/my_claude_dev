---
name: engagement-orchestration
description: "Master orchestration flow for red-team engagements. Defines phases, thread patterns, Obsidian-as-bus, and handoffs. Load at engagement start before dispatching any threads."
modes: [red-team, purple, ctf]
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
4. Operator notes (note-search skill) — personal MITRE notes, prior
   engagement experience, technique write-ups, vuln lab results.
   Always available. Queries vault for target hostname/IP/technique.
5. FALLBACK: blind nmap scan + research MCPs (always available)
   Activates when tiers 1-4 return empty or are unreachable.
   Produces identical Obsidian target pages from live scanning.
   See recon skill "Blind Mode" section for pipeline details.
```

**note-search integration:** Operator notes (tier 4) run in parallel with
tiers 1-3, not as fallback. Results enrich Obsidian target pages with prior
experience context. If operator has technique notes for a target's services,
those inform vector ranking in Phase 2.

Engagement page records `intel_source: providentia | blind_scan | mixed`.
Downstream skills (initial-access, discovery, lateral-move) consume Obsidian
target pages and do not check intel source — format is identical.

## Phase 0: Pre-Engagement (master does directly)

Run these sequentially. No threads needed — master calls skills/MCPs inline.

1. `/spoke-health` — verify all MCPs + SSH spokes green (includes Obsidian app check — WARN if not running, operator won't see llm-wiki artifacts)
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
    5. note-search per live host (hostname + IP)
       → surfaces prior engagement experience with this target
       → flags known techniques, OPSEC notes, prior access paths
  Output:
    Per host → Obsidian target page § Services
    Per host → Obsidian target page § Operator Notes (from note-search)
    Summary → Obsidian engagement page § Reachability
    Raw → llm-wiki/raw/network-sweep-<date>.md
```

**note-search at recon:** For each discovered host, invoke `note-search` with
hostname and IP. If operator has prior notes (technique write-ups, vuln lab
results, past engagement findings), append summary to target page under
`§ Operator Notes`. This gives master context before target selection — a host
with documented prior access paths may be higher priority.

**Master reviews** reachability matrix + service tables + operator note matches.
Selects targets. Gets RT-TGT-001 operator approval.
Sets up ScheduleWakeup to monitor thread.

## Phase 2: Per-Target Attack (phased threads, master between each)

For EACH approved target, dispatch threads sequentially. Master reviews
between phases. Threads are short and focused — context comes from Obsidian.

### Thread A: RESEARCH (parallel OK across targets)

```
  Skill: recon (Phase 3 — vulnerability analysis)
  Input: reads Obsidian target page § Services + § Operator Notes
  Runs per service:version:
    - cve-mcp: cve_by_product → cve_enrich → exploit_search → kev_check
    - hacktricks-mcp: search → outline → section → cheatsheet
    - nuclei-mcp: nuclei_scan against target
    - outline-readonly: vulns-docs for service type
    - range-intel: range_host with README → deploy config
    - Obsidian: prior engagement findings
    - lolbins-mcp: analyze_opsec_risk per technique
    - mitre-mcp: technique IDs + detection sources
    - note-search: per technique/service → operator's prior experience
      Query: "<service> <version>" AND each candidate MITRE technique ID
      Returns: prior success/failure on similar targets, known commands,
      OPSEC notes from operator's own write-ups
  Output → Obsidian target page § Attack Vectors (ranked, with PoC details)
  Also → llm-wiki/wiki/vulnerabilities/<cve>.md per finding
```

**note-search at research:** For each candidate technique, invoke `note-search`
with technique name and MITRE ID. Operator's prior success/failure history
influences vector ranking: techniques the operator has successfully executed
before rank higher. Prior failure notes include root-cause context that avoids
repeating mistakes. Commands from technique notes provide tested PoC snippets.

**Master reviews** ranked vectors (with operator experience context). Approves execution order.
RESEARCH GATE: verify per-service evidence exists before dispatching exploit.

### Thread B: EXPLOIT (sequential per target, operator-approved vectors)

```
  Skill: initial-access (Phase 2-3)
  Input: reads Obsidian target page § Attack Vectors + § Operator Notes
  GATE CHECK: research evidence per service exists (or reject back to master)
  PRE-EXPLOIT: note-search per approved vector technique name
    → pull operator's tested commands and OPSEC warnings
    → if operator notes show prior failure on identical service:version,
      include root-cause in thread context to avoid repeating
  From Kali: execute ranked vectors
    - 3-5 default creds MAX per service, then CVE exploits only
    - Never brute force. Never hydra/medusa as primary vector.
    - Prefer command sequences from operator technique notes when available
  If foothold: deploy Tuoni agent (unique payload per RT-SIG rules)
  If foothold: persist-swarm ROUND 1 fires HERE (per RD-003, in exploit thread)
  Output → Obsidian target page § Access (agent ID, privilege level, persist round 1 status)
  If blocked → Obsidian target page § Blocked (root cause per vector)
```

**Auto-chain:** When Thread B completes with foothold + persist round 1 confirmed,
master auto-dispatches Thread C (POST-ACCESS) immediately. No manual review gate
between exploit and post-access — the persist-swarm round 1 confirmation IS the gate.
Master still reviews Thread B output but does NOT wait for review to dispatch Thread C.
If blocked → master reviews, adjusts approach or moves to next target.

### Thread C: POST-ACCESS (auto-dispatched, sequential steps, one thread)

Thread C is auto-dispatched by master when Thread B reports foothold + persist
round 1 confirmed. Persist-swarm round 1 already ran in Thread B (exploit thread).

```
  Skills: discovery, cred-harvest, collect-intel, persist-swarm (round 2 only)
  Input: reads Obsidian target page § Access (includes privilege level + persist round 1 status)
  Prerequisite: persist-swarm round 1 CONFIRMED in Thread B output

  IF LANDED AS ROOT/SYSTEM:
    1. discovery (invoke discovery skill: host-id → ad-enum → net-recon)
       If domain-joined: trigger bloodhound-python collection
    2. Document privesc paths (even though already root — record for report)
    3. persist-swarm ROUND 2 (elevated dual-beacon, additional mechanisms)
       Archive round 1 once round 2 confirmed
    4. cred-dump (full — already have root/SYSTEM)
       Store in Tuoni cred store. Refs only in Obsidian.
       If crackable hashes: hashcat-mcp MANDATORY before lateral planning
       Query bloodhound-mcp for paths new creds unlock
    5. collect-intel sweep (config dirs, keys, tokens, .env files)
    6. flag-hunt (CTF/exercise only — search for planted flags, write to § Flags)

  IF LANDED AS USER (not root):
    1. discovery (limited scope — what user can see)
       If domain-joined: trigger bloodhound-python collection (user-level)
    2. get-system recon_only → privesc exploit → verify root/SYSTEM
    3a. IF PRIVESC SUCCEEDS:
        - persist-swarm ROUND 2 (elevated dual-beacon)
          Archive round 1 once round 2 confirmed
        - cred-dump (full — now have root/SYSTEM)
          Store in Tuoni cred store. Refs only in Obsidian.
          If crackable hashes: hashcat-mcp MANDATORY before lateral planning
          Query bloodhound-mcp for paths new creds unlock
        - collect-intel sweep (config dirs, keys, tokens, .env files)
        - flag-hunt (CTF/exercise only — search for planted flags, write to § Flags)
    3b. IF PRIVESC FAILS:
        - Document limitation + attempted vectors in Obsidian § Privesc
        - cred-dump (user-level only — /etc/shadow inaccessible, harvest what's available)
        - collect-intel (user-accessible dirs only)
        - flag-hunt (CTF/exercise only — user-accessible paths only)
        - Do NOT block. Continue to next target. Mark host for revisit if new creds arrive.

  Output → Obsidian target page (§ Persistence, § Discovery, § Creds, § Intel, § Privesc, § Flags)
```

**Master reviews** cred harvest + discovery results → lateral decision.

## Phase 3: Lateral Movement (repeat Phase 1-2 from new position)

```
  Skill: lateral-move
  Thread pattern: one thread per lateral target (master approves each)

  1. Master reads harvest results + BloodHound paths from Obsidian
  2. note-search per lateral target + lateral technique (e.g. "pass-the-hash",
     "winrm lateral", "psexec") → operator experience with this move type
  3. Selects next target (RT-TGT-001 approval — sequential, not parallel)
  4. If new zone: set up SOCKS proxy through foothold FIRST
  5. Dispatch lateral-move thread (handles SOCKS + payload + persist internally)
  6. Re-run Phase 1 scan from new foothold (new vantage point, new zone only)
  7. Newly-discovered hosts get full Phase 2 treatment:
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
| Auto-chain exploit to post-access | Persist round 1 confirmed = gate. No manual dispatch delay. |
| Persist round 1 in exploit thread | Per RD-003: landing + persist happen together, before post-access |
| note-search at every phase | Operator notes ground decisions in real experience, not just MCP data |

## Failure Handling

| Failure | Action |
|---------|--------|
| Target unreachable | Mark FILTERED/UNREACHABLE in Obsidian, skip |
| All vectors blocked | Document defense posture in Obsidian, move to next target |
| Persist fails | STOP all ops on host. Persistence is non-negotiable. |
| Privesc fails | Stay low-priv. User-level cred-dump + intel only. Document attempted vectors in § Privesc. Mark host for revisit when new creds arrive from other targets. Do NOT block post-access or lateral planning. |
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

## Mode Selection

Read `.claude/.active-mode` (or `.claude/.mode-overrides/$CLAUDE_CODE_SESSION_ID`)
at engagement start:

```
if mode == "ctf": use CTF Flow section below
else: use standard red-team flow above (Phases 0-3)
```

CTF mode is auto-detected when `.claude/modes/ctf/system-prompt.md` is active.
No operator confirmation needed — mode selection IS the confirmation.

---

## CTF Flow (mode: ctf)

When active mode is `ctf`, orchestration adapts for speed. No gates, no
mandatory documentation, no OPSEC constraints. Flag-oriented.

### Differences from Red-Team Flow

| Aspect | Red-Team | CTF |
|--------|----------|-----|
| Engagement YAML | Mandatory gate | Skip — no YAML needed |
| Pre-engagement cache | Providentia + wiki | Skip — blind scan |
| Phase 0 | 4 mandatory checks | Kali agent check only |
| Research gate | Per-service evidence required | Any scan data sufficient |
| Target approval | RT-TGT-001 operator gate | Auto-approve all live hosts |
| OPSEC | Full RT-SIG rules | None — speed over stealth |
| Persist | Mandatory before proceeding | Optional — flag first |
| Exploit hygiene | Custom only, no Metasploit | Any working exploit OK |
| Documentation | Obsidian mandatory | Obsidian optional (recommended for multi-host) |
| Research dispatch | Thread-only (master blocked) | Master inline OK (no research gate) |
| Cred spray | Lockout-aware, 3-5 max | Unlimited — no lockout concern |

### CTF Phase 0: Quick Start

1. Check Kali agent alive (`tuoni_agents_list`)
2. If dead: deploy fresh agent
3. Done — no other gates

### CTF Phase 1: Blind Recon (parallel threads per CIDR)

Operator provides scope (CIDRs, IPs, or hostnames).
Per CIDR, dispatch thread:

1. `nmap -sn` sweep → live hosts
2. `nmap -sV -sC` top 1000 per live host (or `-p-` if time allows)
3. Per service:version → research MCPs (HackTricks, CVE, nuclei)
4. Write results to Obsidian target pages (optional but recommended)
5. Return ranked target list with attack vectors

Master reviews target list. No approval gate — auto-dispatch exploit threads.

### CTF Phase 2: Exploit + Flag (one thread per target)

Single thread per target handles full chain:

1. Attempt ranked vectors from research
2. If foothold: flag-hunt immediately (`user.txt` / `proof.txt`)
3. Privesc attempt
4. If root/SYSTEM: flag-hunt again (`root.txt`)
5. Optional: persist (only if lateral movement planned)
6. Optional: cred-dump (for lateral or AD attacks)

Key difference: exploit and post-access are ONE thread for speed.
Red-team splits them for gate enforcement. CTF combines for velocity.

### CTF Phase 3: Lateral (if multi-host)

1. Cred reuse spray against all live hosts (no lockout concern)
2. AD enumeration if domain found (BloodHound, Kerberoasting)
3. Dispatch parallel exploit threads for new targets
4. Each thread: exploit → flag-hunt → privesc → flag-hunt

### Thread Dispatch Pattern (CTF)

| Pattern | Behavior |
|---------|----------|
| Recon | Parallel per CIDR |
| Exploit | Parallel per target (not sequential like red-team) |
| Post-access | Combined with exploit thread (not separate) |
| Master | Can research inline (no dispatch guard) |

### CTF Failure Handling

| Failure | Action |
|---------|--------|
| Target unreachable | Skip, move to next |
| All vectors blocked | Try harder, research more, move on if stuck |
| Exploit fails | Try next vector immediately, no cooldown |
| Privesc fails | Grab user flag, note for revisit, move on |
