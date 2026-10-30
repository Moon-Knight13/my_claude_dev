---
title: "PRD Quality Review"
reviewer: quality-rubric
date: 2026-10-30
verdict: CONDITIONAL PASS
---

# PRD Quality Review — my_claude_dev v2

## Verdict: CONDITIONAL PASS

PRD is well-structured with clear mode separation, numbered FRs, traceable NFRs, and explicit MVP/deferred split. Five findings need resolution before finalization; twelve minor items noted.

---

## Top 5 Findings (by severity)

### 1. CRITICAL — Missing FR: Engagement YAML schema/lifecycle (implied but unnumbered)

FR-H3 says "engagement YAML file persists between sessions" and FR-SK2 says skills read/write it, but no FR defines:
- What fields the YAML contains
- Who creates it (operator? skill? mode switch?)
- Lifecycle: when is one created, when closed, how are concurrent engagements handled?
- Validation: what happens if YAML is corrupt or stale?

MVP scope table lists "Engagement YAML state — Structured state persistence" — this needs at least a structural FR (FR-H8 or similar) defining the contract shape, even if implementation details are deferred to architecture.

**Recommendation:** Add FR-H8 defining engagement YAML as a structured contract (sections per mode, create/close lifecycle, single-engagement-at-a-time for MVP). Details go to architecture doc.

### 2. HIGH — Inconsistency: Visual spoke in MVP but no implementation path

FR-K3 is listed as MVP in section 12, but section 13 Open Question #4 says "computer-use capability availability and RDP/VNC integration approach TBD." The deferred table also lists "Visual spoke computer-use AI integration — v1.5", creating ambiguity about what MVP visual spoke actually delivers.

The PRD needs to clarify: MVP visual spoke = operator-facing RDP/VNC proxy (human uses it), AI computer-use integration = v1.5. Currently reads as if the whole thing is both MVP and TBD.

**Recommendation:** Split FR-K3 into FR-K3a (MVP: operator RDP/VNC/SOCKS proxy — human-operated visual access) and FR-K3b (v1.5: AI-driven computer-use through visual spoke). Update Open Question #4 to reference only FR-K3b.

### 3. HIGH — Missing FR: Mode template authoring/structure

Section 5.2 says mode switch "rewrites from mode templates" and FR-H2 says "mode template defines which servers are active." But no FR describes:
- Where templates live (file path convention)
- What a template contains (CLAUDE.md content, settings.json snippet, MCP list, permission set)
- How templates are validated (what catches a broken template before it bricks a session?)

This is MVP-critical — `/mode` skill depends on templates existing.

**Recommendation:** Add FR-H9 defining mode template structure: location, content schema, validation. Can be brief; architecture doc expands.

### 4. MEDIUM — FR-K4 mislabeled as "spoke" — it's a local mount, not a spoke

FR-K4 (Obsidian vault) says "local on host laptop... MCP runs local in devcontainer, no remote spoke needed." This contradicts its placement in "Spoke Infrastructure" — it's a local volume mount, not a spoke. Calling it a spoke dilutes the term and confuses the architecture (spokes = remote systems reached via tunnels).

**Recommendation:** Move FR-K4 to Hub Infrastructure (section 6) or rename section 7 to "External & Local Data Sources." Alternatively, add a note that "spoke" here means "data source outside the container" rather than "remote system via tunnel."

### 5. MEDIUM — Memlog entry 1 says 6 modes; PRD says 5

Memlog line 1: "6 modes confirmed: platform-ops (new, default), red-team, red-dev, green-dev, purple, range-build." PRD section 5.1 lists 5 modes — range-build was merged into green-dev (memlog entry 16 confirms this). The PRD is internally consistent at 5 modes. The memlog is stale on this point but that's expected (append-only log). No PRD change needed, but memlog should get a clarifying entry at finalize.

**Status:** PRD is correct. Memlog stale entry is historical record, not a defect.

---

## Minor Items

1. **FR prefix collision risk:** FR-U (purple) uses U for "purple" — not intuitive. Consider FR-PU or keep U but add a legend. Low priority, cosmetic.

2. **red-dev tools list includes tuoni-mcp** (section 5.5) but permissions say "No live target access without mode switch." If tuoni-mcp is loaded, the AI could attempt C2 commands. Clarify: is tuoni-mcp in red-dev for payload building/testing only, with send_command blocked?

3. **FR-R8 and FR-R9 in MVP scope ambiguity:** MVP lists "3 core skills: recon, deploy-agent, initial-access" but red-team mode defines 5 skills (recon, initial-access, deploy-agent, lateral-move, persist). FR-R8/R9 are implicitly deferred but not in the deferred table. The deferred table does list "Full skill library (lateral-move, persist, cleanup, exploit-dev) — v1.1" which covers this, but making it explicit per-FR would help.

4. **No FR for `.env` management:** FR-H5 mentions `.env.example` → `.env` but no FR governs what goes in `.env`, how it's validated, or what happens when fields are missing. Minor — this is setup script territory, but worth a sentence.

5. **NFR-S4 "MCP servers STDIO only"** — tuoni-mcp connects over HTTPS to Tuoni server. This is accurate (MCP protocol = STDIO, but the MCP server itself makes outbound HTTPS). Worth clarifying that "STDIO only" refers to MCP transport, not that servers cannot make outbound connections.

6. **Source priority (FR-H6)** lists 8 levels but doesn't specify behavior when sources conflict. What if Providentia says a host is decommissioned but Tuoni Discovery shows an active agent on it? Priority implies "trust Providentia," but an explicit conflict-resolution note would help.

7. **Success metrics lack targets.** "Seconds from intent to working session" — what's acceptable? 30s? 5 min? Even order-of-magnitude targets would make metrics actionable. Acceptable to defer to architecture/implementation, but note it.

8. **FR-H4 failover "CLI helper scripts wrapping MCP calls"** — not described elsewhere. What are these? If they're MVP, they need a brief FR. If post-MVP, say so.

9. **Green-dev mode missing GitLab MCP in overview table** — section 5.1 overview table has no tools column, but green-dev tools list includes GitLab MCP. Not an inconsistency per se, but the tools column would add clarity if the table were expanded.

10. **FR-D3 says "tuoni-plugins format"** — implies a specific payload format. Worth a one-liner defining what this means (TSE DynamicAlias modules? Java plugin JARs?) or referencing addendum.

11. **[ASSUMPTION] tags:** Two found (FR-G6 vault unlock, NFR-O3 bootstrap time). Both are appropriately tagged. No untagged assumptions detected.

12. **Addendum quality:** Well-structured, appropriate depth. Alternatives-considered tables present for key decisions. No operational details leaked (IP addresses, hostnames, domain names all absent). Suitable for public repo.

---

## Security Check (Public Repo)

**PASS.** No domains, hostnames, IPs, or topology details found in PRD or addendum. References to "deploy box," "Tuoni server," "host laptop" are generic. Vault path `~/Documents/my_notes` is benign. GitHub repo references (pingdotgg/t3code, etc.) are public. OPSEC rules referenced by code (RT-SIG-001) without quoting sensitive values.

One caution: FR-K1 mentions `host.docker.internal:host-gateway` and `172.17.0.1` — these are Docker standard addresses, not operational details. Safe.

## Testability Check

All FRs are testable with the following notes:
- FR-H6 (source priority) is hard to test automatically — needs integration test with mock sources at each level
- FR-SK4 (failover resilience) needs local model available to test
- FR-U4 (race condition scoring) needs SIEM + active targets — testable only in engagement context
- FR-H7 (upgrade loop) is a process, not a feature — testable only by observing it happen over multiple engagements

These are acceptable constraints, not defects.
