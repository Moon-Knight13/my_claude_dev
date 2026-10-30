---
title: "PRD Addendum — Technical Decisions and Implementation Context"
created: 2026-10-29
updated: 2026-10-30
---

# Addendum: my_claude_dev v2 — Technical Decisions

This document preserves implementation-level decisions, research findings, and
architectural rationale that informed the PRD but belong in downstream documents
(architecture, solution design).

## Mode Switching Implementation

**Constraint:** CLAUDE.md is not hot-reloaded mid-session. Confirmed via multiple
Claude Code GitHub issues (#69571, #46737, #22085). No `/reload` command has
shipped. Multiple RFCs open (#15858, #17306, #53538, #62656), none landed.

**Pattern:** File replacement. Three open-source implementations validated this:
- PsyChaos/claude-operator — sentinel injection into CLAUDE.md
- foxj77/claudectx — full profile swap (CLAUDE.md + settings.json + MCP config)
- kevinzai/cc-commander — skill-based mode preset loading

All use file replacement, not symlinks or env vars. Session restart expected.

**Our approach:** `/mode` skill writes CLAUDE.md + settings.json from mode
templates. v2 subagents receive mode instructions via prompt injection (no file
rewrite needed).

## Spoke Connectivity — SSH Tunnels via host.docker.internal

**Problem:** Devcontainer has its own network namespace + deny-by-default iptables
firewall. VPN runs on host OS, container cannot reach range network.

**Solution:** SSH tunnels through host. Container connects to
`host.docker.internal` (resolves to 172.17.0.1, Docker bridge gateway). Host
manages tunnels to VPN-side targets.

**Evaluated alternatives:**
| Option | Verdict |
|--------|---------|
| Host networking (`networkMode: host`) | Destroys firewall isolation. Rejected |
| Docker bridge routing to VPN | Brittle, breaks on VPN reconnect. Rejected |
| VPN client inside container | Overkill, conflicts with host VPN. Rejected |
| socat on host | Viable but no encryption. SSH preferred |

**Firewall change:** Added port 22 to host gateway allow-list in
`init-firewall.sh`. Container can SSH to host only — cannot reach range directly.
Host controls what is tunneled.

## Obsidian Integration — LLM Wiki / Second Brain Pattern

**Source:** Karpathy's LLM Wiki concept, researched via Lynx Solutions
implementation guide.

**Pattern:** Instead of flat read/write, AI maintains a structured wiki from raw
sources:
- `raw/` — immutable intake (recon output, Providentia data, OSINT)
- `wiki/` — AI-maintained pages (per target, per technique, per engagement)
- `index.md` — master index, AI keeps updated
- `log.md` — change log

**Key benefit:** Incremental compilation. Each engagement enriches all relevant
wiki pages. Reports generated from compiled wiki, not raw notes. Cross-linked
entities give graph-view relationships.

**Reference implementations:**
- AgriciDaniel/claude-obsidian — self-organizing knowledge graph
- ddenzu/karpathy-llm-wiki-second-brain — 4-axis template
- NicholasSpisak/second-brain — LLM-maintained personal KB

## Skills Architecture — Phase-Based Offensive Procedures

**Research findings:** No standard stateful skill pattern exists for Claude Code.
All existing repos use natural-language conditionals for OS/service branching.

**Reference repos:**
- offensive-claude (32 modules) — kill-chain organized, preset workflows
- Masriyan/Claude-Code-CyberSecurity-Skill (22 skills) — full spectrum
- claude-red (58 skills) — 12 attack domains, trigger-word activated
- SecSkills (16 skills + 6 subagents) — marketplace installable

**Academic:** RedTeamLLM (agentic pentest with memory + plan correction),
AutoPentester (iterative target-tool loop with repetition detection).

**Our differentiator:** Skills drive tuoni-plugins via MCP. No existing repo does
this. Phase-based structure with entry/exit criteria, state via engagement YAML +
Tuoni Discovery API.

## T3 Code — v2 Orchestration Candidate

**What it is:** Open-source control plane for AI coding agents (Theo Browne /
Ping.gg, MIT, ~15K stars). Orchestrates Claude Code, Codex, OpenCode, Grok.

**Features:** File browser/editor, per-turn diffs, workspace checkpoints, Git
worktree support, session management.

**Fit:** Does not replace our mode layer — sits above it. Three-layer:
T3 Code (control plane) > my_claude_dev (mode/OPSEC/state) > Claude Code (execution).

**Caution:** v0.0.40 as of Sep 2026. Evaluate stability before committing.

## SIEM Strategy

**Primary:** Elastic (blue team's instance, access to be requested).
**Backup:** Wazuh container + agents deployed ourselves for purple team.
**Abstract:** Skills query "SIEM" layer, not specific product. Implementations
swappable.

## Range-Build Merged into green-dev (Decision Record)

**Decision:** Merge range-build mode into green-dev. Final count: 5 modes, not 6.

**Rationale:** Same tools, same permissions, same target systems. Difference was
task scope, not tool scope. Having a separate mode for "build a VM" vs "deploy a
role" added mode-switch overhead with zero security or capability benefit.
Permission for permanent new boxes is a MOC process gate (change management
approval), not a tool gate — green-dev already requires those approvals.

## Container Firewall Rationale (Retained)

Originally designed for shared-box threat model (multiple devs, one OS account,
sudo everywhere). On personal laptop, primary threat is lower but firewall still
protects against:
- MCP dependency supply chain attacks (30+ CVEs in early 2026)
- Accidental data exfil from Claude to unexpected endpoints
- Defense-in-depth for range network access

Cost of maintaining is low. Removing is easy, re-adding is hard. Decision: keep
with spoke access unblocked via host gateway SSH rule.
