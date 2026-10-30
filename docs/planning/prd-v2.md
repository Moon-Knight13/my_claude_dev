---
title: "my_claude_dev v2 — AI-Driven Cyber Operations Operator Framework"
status: final
created: 2026-10-28
updated: 2026-10-30
---

# PRD: my_claude_dev v2 — AI-Driven Cyber Operations Operator Framework

## 1. Problem Statement

Cyber range operators wear multiple hats — red team, blue-side development, purple team validation, infrastructure build, platform maintenance. Each context demands different tools, permissions, OPSEC rules, and documentation pipelines. Today operators context-switch manually, carry wrong permissions into wrong modes, lose session state across hats, and rebuild tool configurations per engagement. There is no integrated framework that lets an operator orchestrate AI-driven operations from a single session across all operational contexts.

## 2. Vision

A single hub framework on the operator's laptop provides mode-aware, AI-orchestrated sessions across all operational contexts. Mode switching reconfigures tools, permissions, OPSEC posture, and documentation pipeline. Spoke systems (C2 servers, deploy boxes, visual access) connect through the hub. The framework learns from each engagement — discoveries flow back into tooling, making every future operation more capable.

**One bootstrap. Five operational modes. Continuous improvement.**

## 3. Target User

Solo range operator running authorized engagements across offensive, defensive, development, and infrastructure contexts on an authorized cyber range. Single-operator for MVP; architecture does not preclude multi-operator extension.

## 4. Form Factor

- **Primary workspace:** VS Code devcontainer on host laptop
- **AI interface:** Claude Code CLI (primary) and/or VS Code Claude extension
- **MVP:** VS Code devcontainer + Claude Code CLI
- **v2 candidate:** T3 Code (pingdotgg/t3code) as orchestration control plane above the mode layer

Three-layer architecture (v2):
```
T3 Code        (control plane — orchestrate agents, session management)
my_claude_dev  (mode layer — CLAUDE.md, permissions, OPSEC, state, skills)
Claude Code    (execution — MCP servers, hooks, guards, spoke connectivity)
```

## 5. Operational Modes

### 5.1 Mode Overview

| Mode | Context | Range Connectivity |
|------|---------|-------------------|
| **platform-ops** | Framework self-maintenance (default, no engagement) | Not required |
| **red-team** | Offensive ops + target research + engagement documentation | Required |
| **red-dev** | Exploit development, RE, CVE research + vuln documentation | Optional (for PoC testing) |
| **green-dev** | Range infrastructure — build, deploy, configure | Required |
| **purple** | Attack + detect + score + engagement enrichment | Required |

### 5.2 Mode Switching

Mode switch rewrites `.claude/CLAUDE.md` + `.claude/settings.json` from mode templates, requiring session restart. CLAUDE.md is not hot-reloaded mid-session (confirmed via research — multiple Claude Code issues document this constraint).

| Level | Mechanism | Phase |
|-------|-----------|-------|
| **MVP** | Operator invokes `/mode red-team` skill. Skill rewrites config. Operator restarts session | Manual, explicit |
| **v1.5** | Claude suggests mode switch based on task context. Operator confirms | AI-suggested, human-approved |
| **v2** | Master orchestrator spawns mode-agents as subagents with mode instructions injected as prompt context. No file rewrite needed for subagents | Autonomous, orchestrated |

Reference implementations: PsyChaos/claude-operator (sentinel injection), foxj77/claudectx (profile swap), kevinzai/cc-commander (skill-based).

### 5.3 platform-ops Mode

Default mode when no engagement is active. Framework self-maintenance, MCP server development, CI management.

**FR-P1:** Health monitoring — Docker disk usage, MCP server health probes, dependency audit (npm/pip/gitleaks), CI pipeline status, guard stack validation via `check-day0.sh`.

**FR-P2:** Spoke connectivity preflight — "Am I ready for red-team?" check. Ping deploy box, Tuoni server, VPN status. Report which modes are available.

**FR-P3:** MCP server development — write and test range-intel, tuoni-mcp, outline-readonly code within this mode.

**FR-P4:** GitHub integration — issues, PRs for my_claude_dev, tuoni-plugins, other GitHub repos.

**Tools:** GitHub MCP, health check scripts, day0-check skill, security-audit skill.

### 5.4 red-team Mode

Offensive operations against authorized targets. Includes target research, engagement execution, and documentation.

**FR-R1:** Target approval gate — before any scan, exploit, or offensive command, AI must obtain explicit operator approval on exact target list. Discovered hosts are NOT automatically in scope. (RT-TGT-001)

**FR-R2:** Recon skill — phased passive/active reconnaissance. Queries authoritative sources first (Providentia → GitLab READMEs → wiki → Tuoni Discovery → Obsidian notes → existing TTPs), falls to reference MCPs (HackTricks, MITRE, GTFOBins) only when authoritative sources insufficient.

**FR-R3:** Attack execution — drive tuoni-plugins (12+ TSE DynamicAlias modules) via tuoni-mcp. Deploy agents, run modules, manage C2 state. All through Tuoni MCP, not direct SSH to targets.

**FR-R4:** OPSEC enforcement — RT-SIG rules active: no `rt`-prefixed usernames outbound, unique payload IDs per target, platform-appropriate cover names, right-sized binaries. AI validates compliance before each offensive action.

**FR-R5:** Engagement documentation — findings, timeline, IOCs written to Obsidian vault in real-time using LLM Wiki pattern. Raw intel dropped to `raw/`, AI updates structured wiki pages (per target, per technique). Not batched post-engagement. Each finding enriches all relevant cross-linked pages.

**FR-R6:** Deploy to range — ctp-bridge through deploy box spoke for catapult operations when needed.

**FR-R7:** Initial-access skill — entry procedures per vector, informed by reference MCPs and operator tactical notes from Obsidian.

**FR-R8:** Lateral movement skill — movement procedures, rsh/SSH/WMI/credential reuse paths.

**FR-R9:** Persistence skill — deploy-agent procedures using tuoni-plugins persist-swarm module.

**Tools:** tuoni-mcp, range-intel MCP, outline-readonly MCP, Obsidian MCP, HackTricks MCP, MITRE ATT&CK MCP, GTFOBins MCP, ctp-bridge (via spoke). Skills: recon, initial-access, deploy-agent, lateral-move, persist.

**Permissions:** tuoni_send_command whitelisted. Full Bash access to Kali spoke.

### 5.5 red-dev Mode

Exploit development, reverse engineering, CVE research. Build and PoC-test with known-good access (deploy box SSH, `gt` account). Mode boundary: when PoC is proven and ready for realistic E2E testing, switch to red-team.

**FR-D1:** CVE research workflow — eip-mcp for vulnerability details, HackTricks for attack surface, MITRE for technique mapping.

**FR-D2:** Reverse engineering — GhidraMCP for binary analysis, disassembly, decompilation.

**FR-D3:** PoC development — build exploit payloads in tuoni-plugins format. Test via SSH to deploy box with known access.

**FR-D4:** Vulnerability documentation — findings and PoC details written to Obsidian vault.

**FR-D5:** Grounding enforcement — AI follows reference material (HackTricks, MITRE, eip-mcp, Obsidian notes, existing TTPs), does not guess or hallucinate attack vectors. Minimize AI speculation through reference grounding.

**Tools:** GhidraMCP, eip-mcp, codebase-memory-mcp, tuoni-mcp, HackTricks MCP, MITRE ATT&CK MCP, Obsidian MCP. Skills: exploit-dev workflow, vuln documentation.

**Permissions:** Tuoni access for payload testing. Ghidra analysis tools. No live target access without mode switch to red-team.

### 5.6 green-dev Mode

Range infrastructure — build new VMs, deploy ansible roles, configure existing infrastructure. Includes what was previously separate "range-build" scope.

**FR-G1:** Deploy via catapult — ctp-bridge through deploy box spoke. ansible roles, host deploy, deploy-role operations.

**FR-G2:** Pre-deploy validation — ansible-lint + ansible-playbook --syntax-check before any ctp-bridge deploy.

**FR-G3:** Providentia queries — range-intel MCP for network definitions, host records, IP allocation. Providentia is source of truth.

**FR-G4:** VM README documentation — deployment notes, configuration changes written to GitLab READMEs (not Obsidian — Obsidian is for engagement docs).

**FR-G5:** Catapult source navigation — codebase-memory-mcp for ansible role structure, variable resolution.

**FR-G6:** Vault unlock handling — catapult container `make start` requires vault password. [ASSUMPTION] Handled via SSH to deploy box spoke; operator enters vault password manually through tunnel. Not automated — secrets stay human-entered.

**Tools:** ctp-bridge (via spoke), range-intel MCP, GitLab MCP, outline-readonly MCP, codebase-memory-mcp. Skills: ansible-lint pre-deploy.

**Permissions:** ctp-bridge verbs (host deploy, deploy-role, project update-inventory). No offensive tools.

### 5.7 purple Mode

Attack + detect + score + engagement enrichment. Full red-team capability plus blue-side monitoring. Tests whether TTPs buy enough time, enriches reports with IOCs and mitigations.

**FR-U1:** Red-team skill reuse — same attack skills as red-team mode, wrapped with post-step detection monitoring. "After each step, query SIEM for detection."

**FR-U2:** SIEM integration — Elastic (primary, if access granted) + Wazuh (backup, own instance, always available). Abstract SIEM layer in skills — query "SIEM" not specific product.

**FR-U3:** Endpoint telemetry — Velociraptor MCP for artifact collection, process trees, network connections.

**FR-U4:** Race condition scoring — not pass/fail. Measures:
- Time-to-detection: how long until alert fires
- Action completion: did TTP finish objective before detection?
- Payload uniqueness: no signature match in EDR
- Cleanup success: IOCs removed before response

**FR-U5:** Engagement enrichment — pull IOCs, detection artifacts, mitigations from SIEM/EDR to enrich red team reports. Makes reports actionable for blue team.

**FR-U6:** OPSEC refinement loop — if detected too fast, suggest tradecraft refinements. Goal is inflicting time cost on defenders, not invisibility.

**FR-U7:** Defender writeups — generate attack reports + defender learning writeups from purple findings. Written to Obsidian.

**Tools:** Everything from red-team PLUS Wazuh MCP (or Elastic), Velociraptor MCP, scoring mechanism. Skills: red-team skills with detection wrapper.

**Permissions:** Red-team permissions + SIEM/EDR read access.

## 6. Hub Infrastructure

Cross-cutting features that every mode relies on.

**FR-H1:** Guard stack — commit guard (warn-only), safety guard (destructive action gate), git guard (destructive git ops), PII/IP path guard. All installed at user scope, active in every mode, fail-closed.

**FR-H2:** MCP server management — load/unload MCP servers per mode configuration. Mode template defines which servers are active. Routing rule: GitLab MCP active in range-connected modes (green-dev, red-team, purple) for git.crp.cr14.net. GitHub MCP active in platform-ops, red-dev, and any GitHub-hosted work.

**FR-H3:** Cross-session state — engagement YAML file persists between sessions with structured sections per mode (targets, access, findings, handoff notes). Tuoni Discovery queried fresh (never cached) — authoritative for live C2 state. Obsidian vault for human-readable documentation only, not agent-to-agent handoff.

**FR-H4:** Failover chain — Opus 4.6 primary → OpenCode + local model on host laptop → CLI helper scripts wrapping MCP calls. Platform layer (MCPs, .env, modes, vault) is model-agnostic.

**FR-H5:** Bootstrap — `git clone → cp .env.example .env → edit fields → ./setup.sh → /mode <mode>`. Under 15 minutes to first working session. [ASSUMPTION: 15-minute target is reasonable]

**FR-H6:** Source priority enforcement — authoritative sources before research, enforced in skills:
1. Providentia (range truth)
2. GitLab READMEs (VM profiles)
3. Outline wiki (doctrine, procedures)
4. Tuoni Discovery (live C2 state)
5. Obsidian notes (operator tactical knowledge)
6. Existing TTPs (tuoni-plugins, proven techniques)
7. Reference MCPs (HackTricks, MITRE, eip-mcp — only when above insufficient)
8. Web research (last resort)

**FR-H7:** Iterative capability upgrade loop — engagement discoveries flow back into ALL framework components: tuoni-plugins, skills, MCP servers, setup scripts, guard stack, mode configs, OPSEC rules, ctp-bridge. Improvements are maintenance tasks in platform-ops mode. Framework is a living system.

**FR-H8:** Engagement YAML contract — structured state file created when operator starts an engagement, closed when engagement ends. Sections per mode: targets (approved list), access (credentials obtained, not stored — references only), findings, handoff notes. Single active engagement for MVP. Skills read at start, write results on completion. Corrupt or missing YAML triggers skill entry-criteria failure (fail-closed). Schema and lifecycle details deferred to architecture doc.

**FR-H9:** Mode templates — each mode defined by a template directory under `.claude/modes/<mode>/` containing: `CLAUDE.md` fragment (instructions, OPSEC rules), `settings.json` fragment (permissions, MCP server list), and a manifest listing active tools. `/mode` skill validates template before applying (checks required files exist, MCP servers referenced are installed). Broken template = switch refused with diagnostic.

## 7. Spoke and Data Source Infrastructure

**FR-K1:** Deploy box spoke — SSH tunnel via `host.docker.internal`. Host manages tunnel (host VPN resolves DNS, routes to range), container connects to `host.docker.internal:<forwarded-port>`. ctp-bridge executes catapult commands through tunnel. Catapult container sees a shell session, transparent to whether local or tunneled. Preserves devcontainer deny-by-default firewall — only explicitly tunneled hosts are reachable. Requires `--add-host=host.docker.internal:host-gateway` in devcontainer.json.

**FR-K2:** Kali/Tuoni spoke — tuoni-mcp over HTTPS, tunneled through `host.docker.internal:<tuoni-port>` to Tuoni server via host VPN. Primary weapons platform. MCP tools already working (79 tools); tunnel infrastructure needed.

**FR-K3a:** Visual spoke (operator) — RDP/VNC/SOCKS proxy tunneled through host for manual operator access to target boxes (GUI-only admin panels, visual confirmation). MVP requirement — many operational steps require visual/GUI interaction that CLI cannot reach.

**FR-K3b:** Visual spoke (AI computer-use) — AI-driven screen interaction through visual spoke for automated GUI operations. Deferred to v1.5 pending computer-use capability maturity.

**FR-K4:** Obsidian vault (local data source) — not a remote spoke; included here as an external data source outside container. Local on host laptop (`~/Documents/my_notes`). MCP runs local in devcontainer, no remote spoke needed. Vault follows LLM Wiki / second brain pattern (Karpathy):

```
raw/          ← immutable sources (recon output, Providentia dumps, OSINT)
wiki/         ← AI-maintained structured pages (per target, technique, engagement)
index.md      ← master index, AI keeps updated
log.md        ← change log
```

AI incrementally builds and maintains wiki from raw sources. Each engagement enriches all relevant wiki pages — targets, techniques, OPSEC findings cross-linked. Reports generated from compiled wiki, not raw notes. Reference implementations: AgriciDaniel/claude-obsidian (self-organizing graph), ddenzu/karpathy-llm-wiki-second-brain (4-axis template).

## 8. Skills Architecture

Phase-based skills with entry/exit criteria, natural-language OS conditionals, engagement YAML + Tuoni Discovery for state. Reference implementations: offensive-claude (structure), Masriyan/Claude-Code-CyberSecurity-Skill (spectrum coverage).

**FR-SK1:** Skill structure — each skill defines phases with entry criteria, tool declarations, and exit/documentation step. Natural-language conditionals for OS/service branching (works for both Opus and local model).

**FR-SK2:** State awareness — skills read engagement YAML (what's been tried) and Tuoni Discovery (live C2 state) at start. Write results to both on completion.

**FR-SK3:** Purple reuse — same skill, different wrapper. Red-team runs the procedure. Purple mode wraps with "after each step, query SIEM for detection" post-step hook.

**FR-SK4:** Failover resilience — skills prescriptive enough that local model can follow step-by-step. Reference files hold judgment calls (when to pivot, what's anomalous). Opus uses them, local model may skip.

**FR-SK5:** Evidence-based completion — skills must provide evidence (Tuoni state, command output, screenshots) for success claims. "It worked" without evidence is not accepted.

## 9. Multi-Agent Orchestration (v2)

**FR-MA1:** Mode-agents — orchestrator spawns subagents with mode-specific instructions injected as prompt context. Each agent operates in its mode's tool/permission scope.

**FR-MA2:** Engagement loop — red-dev agent (build PoC) → red-team agent (test realistic E2E) → purple agent (observe detection) → iterate. Shared state through engagement YAML.

**FR-MA3:** Agent safety — evidence-based success (not self-reported), OPSEC validation by purple agent, exit criteria checklists, max iteration count, budget caps, full guard stack per agent.

**FR-MA4:** T3 Code integration — evaluate T3 Code (pingdotgg/t3code) as orchestration control plane for mode-agents. Provides session management, workspace checkpoints, Git worktree support, per-turn diffs.

## 10. Non-Functional Requirements

### Security

| ID | Requirement |
|----|-------------|
| NFR-S1 | Credentials never in repository files |
| NFR-S2 | Guard stack (commit, safety, git, PII) active in all modes, fail-closed |
| NFR-S3 | Mode permissions restrictive by default — no offensive tools in non-offensive modes |
| NFR-S4 | MCP servers STDIO only, pinned versions, audited dependencies |
| NFR-S5 | Secrets on spoke guarded from Claude (deny-read hooks) |
| NFR-S6 | Public repo — no domains, hostnames, IPs, topology in code/commits/issues |
| NFR-S7 | OPSEC rules (RT-SIG, RT-TGT) enforced in red-team and purple modes |
| NFR-S8 | Agent budget caps and iteration limits for orchestrated runs (v2) |
| NFR-S9 | ctp-bridge gates on all mutating range commands (team + box allow-list) |
| NFR-S10 | Credentials entered via spoke tunnels must never appear in Claude history, session transcripts, or engagement state files. Safe in flight, absent at rest |

### Operational

| ID | Requirement |
|----|-------------|
| NFR-O1 | Works offline from range (platform-ops, red-dev without live targets) |
| NFR-O2 | Failover: Opus 4.6 → OpenCode + local model → CLI helpers |
| NFR-O3 | Bootstrap under 15 minutes: clone → .env → setup → first mode [ASSUMPTION] |
| NFR-O4 | Session restart on mode switch acceptable (CLAUDE.md not hot-reloaded) |
| NFR-O5 | Spoke connectivity failure degrades gracefully — mode still usable for local work |

### Data

| ID | Requirement |
|----|-------------|
| NFR-D1 | Providentia is source of truth for range state |
| NFR-D2 | Tuoni is authoritative for C2 state — queried fresh, never cached |
| NFR-D3 | Engagement YAML is agent-to-agent handoff contract |
| NFR-D4 | Obsidian vault for human-readable engagement documentation |
| NFR-D5 | Source priority hierarchy enforced — authoritative sources before research |
| NFR-D6 | Engagement discoveries flow back into ALL framework components — plugins, skills, MCPs, setup, guards, mode configs, OPSEC rules |

## 11. Success Metrics

| Metric | Measure | Counter-metric |
|--------|---------|----------------|
| Mode switch time | Seconds from intent to working session | Not at expense of safety (guards still active post-switch) |
| Engagement velocity | Targets compromised per session hour | Not at expense of OPSEC (purple scores don't degrade) |
| Capability growth | New modules/skills/MCP improvements added per engagement | Not at expense of quality (proven before merge) |
| Source authority hit rate | % of queries answered by authoritative sources before falling to research | Not at expense of missing genuinely novel vectors |
| Failover resilience | Can complete basic engagement task on local model | Not at expense of Opus-tier quality when available |
| Upgrade loop throughput | Time from engagement discovery to codified improvement | Not at expense of stability (regression testing) |

## 12. MVP Scope

### In MVP

| Feature | Details |
|---------|---------|
| Mode switching | `/mode` skill + session restart. platform-ops + red-team modes |
| Deploy box spoke | SSH tunnel + ctp-bridge remote execution |
| Tuoni MCP | Already working, 79 tools |
| Obsidian MCP | Read tactical notes + write engagement docs |
| Engagement YAML state | Structured state persistence between sessions |
| Guard stack | Existing commit/safety/git/PII guards |
| 3 core skills | recon, deploy-agent, initial-access (phase-based) |
| Source priority enforcement | Authoritative-first hierarchy in skills |
| Visual spoke (operator) | RDP/VNC/SOCKS proxy for manual operator GUI access to target boxes (FR-K3a) |
| Mode templates | Template directories per mode with validation (FR-H9) |
| Health monitoring | Docker disk, MCP health, spoke preflight |

### Deferred (post-MVP)

| Feature | Phase |
|---------|-------|
| red-dev, green-dev, purple modes | v1.1 |
| AI-suggested mode switching | v1.5 |
| Multi-agent orchestration | v2 |
| T3 Code integration | v2 |
| Wazuh/Velociraptor/Elastic MCP | v1.1 (purple) |
| GhidraMCP, eip-mcp, codebase-memory-mcp | v1.1 (red-dev) |
| Visual spoke computer-use AI integration | v1.5 |
| Report export pipeline (DOCX/PDF) | v1.1 |
| Agent budget caps / iteration limits | v2 |
| Automated capability upgrade loop | v1.5 |
| Full skill library (lateral-move, persist, cleanup, exploit-dev) | v1.1 |
| Purple race-condition scoring | v1.1 |

## 13. Open Questions

1. **Local model benchmarking** — what model runs acceptably on host laptop hardware for failover? Deferred to on-host testing session. [NOTE FOR PM]
2. **Elastic access** — can we get read access to blue team's Elastic instance, or must we run our own Wazuh? Affects purple mode tool requirements. [NOTE FOR PM]
3. **T3 Code maturity** — v0.0.40 as of Sep 2026. Evaluate stability before committing to v2 orchestration dependency. [NOTE FOR PM]
4. **Visual spoke AI integration** — computer-use capability availability for FR-K3b (AI-driven GUI ops, v1.5). Operator-facing RDP/VNC proxy (FR-K3a) is MVP. [NOTE FOR PM]
5. **Multi-operator extension** — architecture should not preclude it, but no specific requirements defined. Defer until demand exists. [NOTE FOR PM]

## 14. Constraints

- **CLAUDE.md not hot-reloaded** — mode switch requires session restart. Confirmed constraint, not a bug.
- **Public repository** — no operational details in code, commits, issues, or documentation.
- **Authorized scope only** — all offensive work confined to authorized range, on organization-owned boxes.
- **Human-in-the-loop** — all mutating range commands confirmed by operator. No auto-approve path.
- **Devcontainer-first** — hub runs in devcontainer on host laptop. Deploy box is a spoke, not the primary workspace.
