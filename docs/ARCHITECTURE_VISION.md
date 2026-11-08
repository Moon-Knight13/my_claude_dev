# Architecture Vision — v3 Multi-Environment Expansion

> **Status:** Planning (2026-11-06). Nothing in this document is built unless
> explicitly marked. Current working state is documented in
> [`../README.md`](../README.md) and the [explainer](explainer/index.html).

## Overview

my_claude_dev v3 generalizes the platform from a single-environment operator hub
(one cyber range) to a multi-environment framework supporting independent
operational domains: CTF challenge solving, penetration testing, bug bounty,
general software development, exploit research, and homelab infrastructure.

The core thesis: the **architecture** (mode isolation, MCP integration, safety
harness, session continuity) is environment-agnostic. The range-specific parts
are configuration, not code.

## Multi-Environment Expansion

### Current modes (built)

| Mode | Domain | Range required |
|------|--------|----------------|
| `base` | Hub routing and cross-domain planning | No |
| `platform-ops` | Framework self-maintenance, MCP dev, CI | No |
| `green-dev` | Range infrastructure build and deploy | Yes |
| `red-team` | Offensive operations against authorized targets | Yes |
| `red-dev` | Exploit development and reverse engineering | Yes (test range) |
| `purple` | Attack + detection validation with scoring | Yes |
| `homelab` | Homelab IaC development | No |

### Planned modes

| Mode | Domain | Notes |
|------|--------|-------|
| `dev` | General software development | No offensive tools, full coding toolchain |
| `ctf` | CTF platform challenge solving | HTB/THM/PG oriented, no OPSEC requirements, flag-focused |
| `pentest` | Client penetration testing | SOW-scoped, formal reporting, Mythic C2 |
| `bounty` | Bug bounty programs | Program policy as scope, web-focused, no C2 |

Existing modes remain unchanged. New modes follow the same structure:
`system-prompt.md`, `settings.json`, and `tool-policy.yaml` under
`.claude/modes/<name>/`.

### Environment profile system

Replaces the current flat `.env` with per-environment configuration:

```
~/.claude-profiles/
  range.env           # current environment
  ctf-htb.env        # HTB/THM challenges
  pentest.env        # client engagement
  homelab.env        # infrastructure work
  general.env        # software development
```

Each profile selects:
- Available modes (subset of all 11+)
- Active MCP server list
- Spoke connections (SSH endpoints)
- Model failover chain
- Active Obsidian vaults

Activated via `ACTIVE_PROFILE=<name>`. Only modes listed in the active profile
appear in `/mode list`.

### MCP availability matrix

Most MCP servers are universal. Only three are range-locked:

| MCP Server | Availability | Used by modes |
|------------|-------------|---------------|
| `tuoni-mcp` | Range-locked (C2) | red-team, purple |
| `range-intel` | Range-locked (targeting) | red-team, green-dev, purple, red-dev |
| `ctp` (build tooling) | Range-locked (deploy) | green-dev |
| `outline-readonly` | Range-locked (wiki) | red-team, green-dev, purple |
| `obsidian-mcp` | Universal | All modes |
| `rea-mcp` | Universal | red-dev, ctf, pentest, bounty, dev, purple, research |
| `hacktricks-mcp` | Universal | red-team, ctf, pentest, bounty, purple |
| `mitre-mcp` | Universal | red-team, purple, pentest |
| `cve-mcp` | Universal | red-dev, pentest, bounty, purple |
| `lolbins-mcp` | Universal | red-team, purple, ctf |
| `local-ollama` | Universal | All modes |

## T3-Native Routing

### Problem

Hook-injected mode rules degrade in long sessions: context bleed, routing
ambiguity with 11+ modes, and no isolation between concurrent mode sessions.
The `.active-mode` file is shared state — two threads in the same project see
the same mode, which is wrong when they need different modes.

### Solution: master agent pattern

```
T3 Projects = Environment Profiles
  └── T3 Threads = Mode Sessions

Hub thread (base) = coordinator/router
  ├── "Cyber Range" project → red-team, green-dev, purple, red-dev threads
  ├── "CTF" project → per-challenge threads
  ├── "Pentest" project → per-engagement threads
  ├── "Homelab" project → per-service threads
  └── "Dev" project → per-repo threads
```

- Mode rules live in project-level `CLAUDE.md`, not hook injection
- Hub routes via `t3_thread_launch` (new session) or `t3_thread_send` (resume)
- No routing table parsing — user states intent, hub finds or creates right thread
- Workspace strategy: separate repos per domain (my_claude_dev = framework only)
- Skills and MCPs installed at machine level, available to all projects

### Security under T3 routing

**What improves:**
- Context isolation: no cross-mode bleed between threads in different projects
- Hooks are project-scoped (`$CLAUDE_PROJECT_DIR`): fire on all threads within a project
- Delegate task children inherit project context, including hooks

**What stays the same:**
- Hard gates (guard stack, killswitch) are machine-level
- MCP tool filtering is LLM-enforced (soft). Hardened by `mode-tool-gate.sh`
  which reads `.active-mode` and the mode's `tool-policy.yaml` to hard-deny
  disallowed MCP calls

**Known gap:** `.active-mode` is one file per project. Two threads in the same
project that need different modes will read the wrong mode state.

**Solution:** Project-per-mode-group. Each T3 project gets its own `.claude/`
directory with its own `.active-mode` and `tool-policy.yaml`. The framework
repository becomes a template that scaffolds new project security configs.

### Migration path

Incremental, not big-bang:

1. Keep hooks for existing modes (working now, no regression)
2. Build scaffold script to create new project with security config from template
3. First non-range project (ctf or dev) proves the pattern end-to-end
4. Scale to remaining projects as needed
5. Hub thread becomes pure router last

## Model Failover Chain

### Design

Cost-aware failover around Claude MAX subscription (not per-token API):

| Tier | Provider | Cost | Notes |
|------|----------|------|-------|
| 0 | Claude MAX (Anthropic) | Subscription (already paid) | Primary. Opus 4.6, full capability |
| 1 | Homelab vLLM server | Zero marginal cost | Abliterated open-weight model, controlled infra |
| 2 | RunPod serverless vLLM | ~$0.50-1/hr active | Same model as homelab, insurance when homelab is down |
| 3 | Local Ollama on laptop | Zero cost | Degraded capability, emergency fallback |

### Failover triggers

- HTTP 5xx or timeout >30s → next tier
- 429 rate limit → next tier
- Content policy block → skip directly to Tier 1 (abliterated model handles
  legitimate offensive security research prompts that frontier models refuse)

### Failover harness

OpenCode serves as the failover client — provider-agnostic, MCP support, same
operator experience. Replaces the original OpenRouter plan (cost).

**Dependency:** Homelab workstrand must deploy vLLM server before Tier 1 is
available.

## Vault-per-Mode Knowledge Bases

### Architecture

Each operational mode gets its own Obsidian vault as a domain-specific knowledge
base. Agents search active vaults for accumulated operational experience.

```
Obsidian vaults:
  ops-security/    red-team, purple (TTPs, OPSEC, engagement findings)
  ctf/             writeups, technique patterns, platform notes
  pentest/         methodology, report templates, client-safe findings
  exploit-dev/     CVE research, RE notes, exploit patterns
  software-dev/    architecture decisions, library notes, debug patterns
  homelab/         service docs, runbooks, network topology
  platform/        framework decisions, MCP dev notes
  reference/       shared across ALL modes (MITRE, tool cheatsheets, protocols)
```

Profile config activates vaults: `OBSIDIAN_VAULTS_ACTIVE=reference,<mode-vault>`

### Search tiers

| Tier | Method | Status |
|------|--------|--------|
| 1 | obsidian-mcp keyword search | Existing, works now |
| 2 | vault-search-mcp (semantic) | Planned — Ollama nomic-embed-text + ChromaDB/SQLite-vec |
| 3 | LLM query expansion + re-search | Planned — requires Tier 2 |

### Why vaults over fine-tuning

This is the competitive advantage: purpose-trained models (what others build)
are expensive and static. Purpose-built knowledge bases accumulate operator
experience over time, are searchable, editable, and survive model swaps.
The model is replaceable; the vault is not replicable.

### Build sequence

1. Structure vault directories and templates
2. Deploy embedding model on homelab (blocked on vLLM server)
3. Build vault-search-mcp (platform-ops work)
4. Populate vaults organically during work

## Competitive Landscape

### Context

Researched 2026-11-06 for architecture decisions. Landscape changes fast —
re-verify before citing specifics.

### Positioning

| | This framework | Comparable tools |
|---|---|---|
| **Approach** | Integration-depth: 15+ MCPs from one seat, mode isolation, OPSEC-as-code | Purpose-trained models, multi-agent orchestration, C2 ecosystem |
| **Safety** | Fail-closed harness, tested, documented, demonstrated | Varies by tool |
| **Knowledge** | Vault-per-mode, accumulates over time | Model training (static) |
| **Model** | Swappable (failover chain) | Provider-locked |
| **Scale** | Single operator | Team-scale |

### Key capability gaps to close

1. **Identity graph reasoning** — no equivalent to AD graph analysis tooling
2. **Multi-agent operational orchestration** — parallel ops via Workflow/pipeline
3. **Disposable plugin generation** — OPSEC improvement for throwaway tooling

### Portfolio framing

Public repository is safe to publish. This is a framework, not a weapon:
- Less directly weaponizable than open-source C2 frameworks and attack path tools
- No operational data, credentials, or target specifics in the repository
- Offensive skills require range infrastructure to function
- Safety harness is documented alongside offensive capability
- Demonstrates security engineering approach that employers evaluate

## Security Model Summary

### Hard gates (machine-level, always active)

| Gate | Mechanism | Scope |
|------|-----------|-------|
| Guard stack | PreToolUse hook → `guard-stack.sh` | All threads in project |
| Mode tool gate | `mode-tool-gate.sh` reads `.active-mode` + `tool-policy.yaml` | All threads in project |
| Secret scan | UserPromptSubmit gitleaks scan | All threads in project |
| Killswitch | PAM hook + systemd timer | Machine-wide |
| Audit trail | Logs all tool calls | All threads in project |
| Response scanner | Scans tool output for leaks | All threads in project |

### T3 thread model implications

- Hooks use `$CLAUDE_PROJECT_DIR` — project-scoped, not machine-scoped
- All hooks fire on all threads within a T3 project
- Delegate task children inherit project context including hooks
- `.active-mode` is shared within a project: solved by project-per-mode-group
- Cross-thread messaging is a new attack surface: mitigated by defense-in-depth
  (guard stack fires on all tool calls regardless of origin)

### Net security assessment

T3-native routing **improves** security over hook-injected modes:
- Context isolation prevents cross-mode bleed
- Project-scoped hooks are structural, not convention-dependent
- Mode state is per-project, eliminating shared-file race conditions
- Audit trail is per-thread, giving cleaner forensics

## Implementation Priority

| Phase | Work | Depends on |
|-------|------|------------|
| 1 | Scaffold script for new T3 project security configs | Nothing |
| 2 | First non-range project (ctf or dev) | Phase 1 |
| 3 | Environment profile system | Phase 2 validated |
| 4 | Homelab vLLM deployment | Hardware (already sufficient) |
| 5 | vault-search-mcp (semantic search) | Phase 4 |
| 6 | Model failover router in OpenCode | Phase 4 |
| 7 | Hub thread as pure router | Phases 2-3 stable |

All phases are independent and incremental. No big-bang migration. Existing
modes continue working through every phase.
