---
title: "v2 Roadmap — Validated Feature List"
created: 2026-10-30
updated: 2026-10-30
source: "E2E worked examples review session + PRD v2 + course correction"
---

# v2 Roadmap

Validated feature list derived from PRD v2, course correction decisions, and
E2E worked example review. Each item maps to PRD feature requirements.
Items marked with `*` are new from the Oct 30 review session.

## Status Key

- **DONE**: built and working
- **P0**: blocks other work, do first
- **P1**: core workflow, MVP scope
- **P2**: enhancement, post-MVP
- **P3**: deferred / future version

## Infrastructure (DONE)

| # | Feature | Status | Notes |
|---|---------|--------|-------|
| I1 | Devcontainer + firewall | DONE | Guard hooks, plugins, config deploy |
| I2 | Spoke SSH config generation | DONE | PR #167, `setup-container-ssh.sh` |
| I3 | Hub-spoke ProxyJump chain | DONE | hub → deploybox, hub → kali verified |
| I4 | Guard stack (commit/safety/git/PII) | DONE | All passing |
| I5 | range-intel MCP (7 tools) | DONE | Providentia + GitLab READMEs |
| I6 | tuoni-mcp (official, 79 tools) | DONE | PR #1 open upstream |
| I7 | Obsidian vault mount | DONE | PR #167, read-only bind mount |
| I8 | GitHub board + kanban workflow | DONE | board.sh, KANBAN_WORKFLOW.md |

## P0 — Blocks Everything

| # | Feature | PRD Ref | Scope | Description |
|---|---------|---------|-------|-------------|
| P0-1 | Mode switching | FR-H9 | `/mode` skill + templates | Write `.claude/modes/<mode>/` templates (CLAUDE.md + settings.json fragments). `/mode` skill validates and applies. Session restart. Start with platform-ops + red-team. |
| P0-2 | ctp-bridge remote exec | FR-K1 | SSH tunnel path | `ctp-bridge` executes catapult commands via SSH to deploy box. Blocks all green-dev deploy ops. |

## P1 — Core Workflow (MVP)

| # | Feature | PRD Ref | Scope | Description |
|---|---------|---------|-------|-------------|
| P1-1 | Engagement YAML schema | FR-H8 | State contract | Schema: targets, phase, agents, cred refs (never plaintext), findings, handoff. Read at skill start, write on completion. |
| P1-2 | Recon skill | FR-R2 | Phase-based skill | Source priority: Providentia → GitLab README → wiki collections (repo-docs + vulns-docs)* → Tuoni Discovery → Obsidian → reference MCPs. net-recon from Kali. |
| P1-3 | Initial access skill | FR-R7 | Phase-based skill | Entry procedures per vector. OPSEC gate before execution. |
| P1-4 | Cred harvest + priv esc skill | FR-R8* | Phase-based skill | Always run priv esc assessment (even if elevated)*. Cred harvest grounded in research (HackTricks + vulns-docs)*. Store to tuoni creds + wiki*. |
| P1-5 | Lateral movement skill | FR-R8 | Phase-based skill | Requires harvested creds*. persist-swarm on every new target immediately*. SOCKS proxy setup from footholds*. |
| P1-6 | Persist-swarm skill | FR-R9 | Phase-based skill | Operational + sleeper agents. Unique payload IDs, cover names, right-sized binaries per RT-SIG-*. |
| P1-7 | opsec-exploit-hygiene skill | NEW* | Guard skill | No default to Metasploit/public modules. Extract technique, build custom. Public exploit = learning resource only. |
| P1-8 | opsec-cred-spray skill | NEW* | Guard skill | Enumerate lockout policy before any spray. Stay under threshold. One password per lockout window. |
| P1-9 | Source priority enforcement | FR-H6 | Cross-cutting | Wiki collections: repo-docs (GitLab READMEs), vulns-docs (vuln research)*. Authoritative before research. |

## P2 — Enhancement (post-MVP)

| # | Feature | PRD Ref | Scope | Description |
|---|---------|---------|-------|-------------|
| P2-1 | red-dev mode + template | FR-D1-D5 | Mode template | rea-mcp* replaces ghidra-mcp. gt SSH bypass for isolated testing*. Documentation outputs: technique writeup, IoC report, remediation guide, red-team pickup card*. |
| P2-2 | green-dev mode + template | FR-G1-G6 | Mode template | ctp-bridge deploy, Providentia queries, GitLab README docs. |
| P2-3 | purple mode + template | FR-U1-U7 | Mode template | Red-team skills + detection wrapper. SIEM abstraction layer. Scoring. |
| P2-4 | rea-mcp integration | FR-D2* | MCP server | Replace ghidra-mcp. Single RE MCP: native binaries, .NET, APK, Electron, firmware, pcaps. Ghidra/IDA as backends. |
| P2-5 | Obsidian MCP + LLM Wiki structure | FR-K4 | Data layer | raw/ → wiki/ → reports. AI-maintained structured pages. Index + changelog. |
| P2-6 | SOCKS proxy plugin | NEW* | tuoni-plugin | Firewall/foothold SOCKS proxy for Kali tool routing via proxychains. Setup + teardown module. |
| P2-7 | Report export pipeline | FR-H7 | Documentation | Obsidian wiki → engagement report (DOCX/PDF). |
| P2-8 | Health monitoring | FR-P1 | platform-ops | Docker disk, MCP health probes, dependency audit, CI status. |
| P2-9 | Visual spoke (operator) | FR-K3a | Spoke | RDP/VNC/SOCKS proxy for manual GUI access to targets. |

## P3 — Future

| # | Feature | PRD Ref | Notes |
|---|---------|---------|-------|
| P3-1 | AI-suggested mode switching | FR-MA1 | v1.5 |
| P3-2 | Multi-agent orchestration | FR-MA1-4 | v2, T3 Code evaluation |
| P3-3 | Visual spoke AI (computer-use) | FR-K3b | Pending capability maturity |
| P3-4 | Purple race-condition scoring | FR-U4 | After purple mode built |
| P3-5 | Agent budget caps | NFR-S8 | v2 orchestration |

## Session Additions (Oct 30 review)

Items marked `*` above were added or modified based on E2E worked example
review. Summary of changes:

1. **Wiki targeting sources**: repo-docs + vulns-docs collections alongside general search
2. **Cred harvest grounding**: research-first (HackTricks + vulns-docs + repo-docs), not assumptions
3. **Cred output**: tuoni creds store + wiki documentation (not just engagement YAML)
4. **Priv esc always runs**: even when already elevated, document alternative paths
5. **Persist on lateral**: every new target gets persist-swarm immediately
6. **SOCKS proxy**: from footholds for Kali tool routing (tuoni-plugin)
7. **opsec-exploit-hygiene**: no Metasploit/public exploit defaults
8. **opsec-cred-spray**: lockout-aware credential spraying
9. **rea-mcp**: replaces ghidra-mcp for unified RE
10. **gt SSH bypass**: red-dev isolated testing without full kill chain
11. **Documentation outputs**: technique writeup, IoC, remediation, pickup card
12. **Spoke SSH gap solved**: PR #167, setup-container-ssh.sh

## Stale Artifacts to Archive

These planning-era docs predate the course correction and should move to
`docs/archive/`:

- `docs/planning/prd-v2-review.md` — superseded by this roadmap
- Any BMAD planning artifacts from SP1a era

PRD v2 (`prd-v2.md`) and addendum (`prd-v2-addendum.md`) remain as design
reference — this roadmap is the execution plan derived from them.

## Related

- [E2E Worked Examples (internal)](https://claude.ai/artifact/5CQKDEv9yfo3HWqP4EDMYe)
- [E2E Explainer (public-safe)](https://claude.ai/artifact/HRhp4bS8DcmZFPQbY38bXR)
- [Course Correction Memory](../../../.claude/projects/-workspace/memory/course-correction-oct2026.md)
- PRD v2: `docs/planning/prd-v2.md`
- PRD Addendum: `docs/planning/prd-v2-addendum.md`
