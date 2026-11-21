# E2E Software Factory Architecture

**Status:** Draft — operator review  
**Date:** 2026-11-21  
**Sources:** deployment-target-inventory, repo-consolidation-audit, environment-isolation, cloud-provider-landscape, context-safety-catch

---

## 1. Vision

my_claude_dev becomes a complete software factory HQ: a single operator seat
that orchestrates dev, test, and deploy pipelines across any infrastructure the
operator has access to.

**Core principles:**

- **Fleet model.** HQ orchestrates. Project repos execute. Satellites stay
  separate. No monorepo.
- **Environment isolation.** Range data never reaches public repos. Homelab
  creds never reach range threads. Cloud keys never reach git history.
  Mode-based walls enforce boundaries.
- **Deploy target abstraction.** Common pipeline stages (build, test, package,
  push, verify) with target-specific adapters. Same operator experience whether
  deploying to range VMs, Azure, Hetzner, or homelab.
- **Context safety.** Automated detection of context window exhaustion. Graceful
  handoff between threads. No silent quality degradation.

**What this is NOT:**

- Not a CI/CD platform (GitHub Actions handles CI).
- Not a hosting service (providers host; HQ orchestrates).
- Not a monorepo (repos stay separate; HQ connects them via modes and MCPs).

---

## 2. Fleet Model

### 2.1 Classification

Based on audit of all 45 Moon-Knight13 repos:

| Tier | Classification | Count | Role |
|------|---------------|------:|------|
| 1 | **HQ** | 1 | Hub — modes, skills, hooks, MCPs, dispatch |
| 1 | **Template** | 1 | Upstream CI/security patterns for all repos |
| 2 | **Satellite** | 6 | HQ orchestrates via mode + MCP; repo stays independent |
| 3 | **Project repo** | 2 | Template-downstream, no HQ dependency |
| 4 | **Absorb candidate** | 3 | Evaluate: extract patterns or archive |
| 5-9 | **Tidy/portfolio** | 32 | Coursework (portfolio value — tidy, don't delete), dead forks, duplicate experiments |

### 2.2 Fleet Topology

```
HQ (my_claude_dev)
├── Template (claude_template_repo)
│     └── syncs CI gates + security scaffold to all downstream repos
│
├── Satellites (HQ orchestrates, repos stay separate)
│   ├── tuoni-mcp         [red-team mode]    — OFFICIAL shell-dot/tuoni-mcp (PRIVATE; Moon-Knight13/tuoni-mcp is our fork — ARCHIVE)
│   ├── tuoni-plugins     [red-dev mode]     — C2 command plugins (PRIVATE, HIGH risk)
│   ├── homelab_infra     [homelab mode]     — IaC for home platform (PUBLIC)
│   ├── homelab_planning  [homelab mode]     — BMAD planning artifacts (PRIVATE)
│   ├── foundryvtt-docker [homelab mode]     — Containerized FoundryVTT (PUBLIC)
│   └── medicat-usb       [standalone]       — USB rescue builder (PUBLIC)
│
├── Project repos (template-downstream, independent)
│   ├── project_dungeon
│   └── foundry-gm-claude-plugin
│
└── Proposed new satellites
    └── azure-dev-harness [azure-dev mode]   — Azure IaC (keep separate, add HQ mode)
```

### 2.3 HQ Modules

HQ contains no application code. It contains:

| Module | Location | Purpose |
|--------|----------|---------|
| Modes | `.claude/modes/` | 12 operational contexts with tool-policy, skill filter, system prompt |
| Skills | `.claude/skills/` | Packaged procedures — 24 skills, mode-gated |
| Hooks | `.claude/hooks/`, `scripts/hooks/` | Safety guards, audit, injection |
| MCP config | `.mcp.json` files per mode | Spoke connectivity |
| Spoke scripts | `scripts/host/`, `scripts/lib/` | Provisioning, SSH, proxy chain |
| Deploy bridge | `scripts/ctp/` | ctp-bridge gate stack |
| CI scaffold | `.github/workflows/` | 7 template-inherited workflows |

### 2.4 Fleet Cleanup Actions

**Immediate (low effort, high cleanup):**
1. Tidy coursework repos (portfolio value — standardize READMEs, archive truly dead ones only)
2. Evaluate coursework forks — keep those with meaningful additions, archive pure forks
3. Consolidate AI experiment repos (keep Ai_Suite, archive duplicates)

**Near-term:**
4. Archive weaponised_ansible after extracting reusable patterns into HQ skills
5. Archive nosense_ip_updater after migrating functions to official tuoni-mcp/range-intel
6. Add CLAUDE.md to homelab_planning

**Result:** 45 repos → ~25. Active fleet: HQ + template + 6 satellites + 2
project repos = 10 repos that matter.

---

## 3. Deployment Target Abstraction

### 3.1 Common Pipeline Stages

Every deploy target follows the same abstract flow. Specific targets add
target-specific stages.

```
┌─────────────┐    ┌──────────┐    ┌─────────┐    ┌────────┐    ┌────────┐    ┌──────────┐
│ 1. Pre-flight│───▶│ 2. Build │───▶│ 3. Push │───▶│4. Deploy│───▶│5. Verify│───▶│ 6. Record│
│   validate   │    │  package  │    │ registry │    │ compute │    │  health │    │  state   │
└─────────────┘    └──────────┘    └─────────┘    └────────┘    └────────┘    └──────────┘
```

| Stage | What happens | Reusable? |
|-------|-------------|-----------|
| **Pre-flight** | Auth check, connectivity, inventory query, cost estimate | Yes — pattern shared |
| **Build** | `docker build`, compile, package | Yes — Docker universal |
| **Push** | Push image to registry (ACR, ECR, GHCR, Docker Hub) | Yes — registry adapter |
| **Deploy** | Create/update compute (VM, container, serverless) | No — target-specific |
| **Verify** | Health check with real traffic | Yes — HTTP probe pattern |
| **Record** | Update state file, engagement state, cost tracking | Yes — format differs |

### 3.2 Range-Specific vs General Tooling

**Important scope boundary.** Several tools exist only for the cr14 exercise range
and have no general equivalent:

| Tool | Scope | Generalizes? |
|------|-------|-------------|
| ctp-bridge | cr14 range deployment only | Safety gate pattern generalizes; tool itself does not |
| Providentia | cr14 range inventory | No equivalent outside range — cloud providers have their own catalogs |
| catapult | cr14 Ansible container | General Ansible patterns reusable; catapult container is range-specific |
| Outline wiki | cr14 range docs | General note-taking via Obsidian; wiki itself is range-specific |
| vCenter | cr14 VM management | No equivalent needed — cloud providers have native APIs |

The safety *patterns* from ctp-bridge (pre-flight, confirm, lock, verify) generalize.
The *tools* stay range-scoped. Cloud deploy skills build fresh adapters using
the same safety patterns, not by wrapping ctp-bridge.

### 3.3 Spoke Model: Range vs Personal

Spokes exist per-environment, not globally:

| Environment | Spokes | Provided by |
|-------------|--------|------------|
| cr14 range | deploybox, kali, range-git | Range infrastructure (not ours) |
| Homelab | Docker host, NAS | Operator-owned hardware |
| CTF/external | Personal kali deployment | Operator deploys own kali (Docker or VM) |
| VPS/cloud | Cloud instances | Provisioned on demand |

**Personal kali:** For CTFs outside cr14, operator needs own kali deployment —
Docker container or VM on homelab/VPS. This is a homelab-mode or ctf-mode
capability, not tied to range spokes. Design: `kali-bootstrap` skill adapted
for non-range targets (Docker Compose on any host, not catapult-specific).

### 3.4 How ctp-bridge Safety Gates Generalize

The safety gates generalize as patterns, not as the tool itself:

| ctp-bridge gate | Generalized form | Applies to |
|-----------------|-------------------|-----------|
| Gateway pre-flight | Auth + connectivity check | All targets |
| Providentia inventory query | Resource catalog read | Cloud catalog queries |
| Human confirmation gate | Operator approval before create/destroy | All billable resources |
| Concurrency lock (flock) | Mutex on deploy operations | Parallel deploy prevention |
| Liveness probe before redeploy | State check before mutation | All update operations |
| Post-deploy verification | Health endpoint check | All targets |

### 3.3 Target Adapters

Each deploy target implements the common stages plus target-specific logic:

| Target | Adapter | Target-specific stages |
|--------|---------|----------------------|
| Range VM | `ctp-bridge` | Ansible role, catapult container, Providentia state |
| Azure | `cloud-deploy-azure` | Bicep/ARM, AAD auth, resource groups, private endpoints |
| Hetzner | `cloud-deploy-hetzner` | `hcloud` API, flat networking, hourly billing |
| Homelab | `homelab-deploy` | Ansible roles, Proxmox, CIS hardening, air-gap bundle |
| Docker Compose | `compose-deploy` | Service orchestration, Cloudflare Tunnel |
| Kali bootstrap | `kali-bootstrap` | Tuoni deploy, 40+ tool matrix, ipset firewall |
| RunPod | `runpod-*` skills | GPU sizing, serverless endpoints, FlashBoot |

### 3.4 Generic Deploy Skill Architecture

Modeled on RunPod's proven router-journey pattern:

```
.claude/skills/
├── cloud-deploy/SKILL.md           # Router — classifies intent, picks journey
├── cloud-deploy-azure/SKILL.md     # Azure: Container Apps, App Service, ACI
├── cloud-deploy-hetzner/SKILL.md   # Hetzner: Cloud servers, volumes, DNS
├── cloud-deploy-aws/SKILL.md       # AWS: App Runner, ECS/Fargate, Lambda
├── cloud-deploy-vercel/SKILL.md    # Vercel: serverless, edge, static
├── cloud-deploy-doctor/SKILL.md    # Diagnose broken deploy on any provider
└── cloud-deploy-cost/SKILL.md      # Cost audit across providers
```

Key patterns carried from RunPod:

- **MCP-first, CLI-fallback.** Structured MCP tools when connected; shell to CLI when not.
- **Read-before-write.** Query catalog/state before provisioning. State cost before creating.
- **Verify-with-real-traffic.** Smoke test with actual request after every deploy.
- **Answer contract.** Consistent response: what exists, what it costs, how to reach it.
- **Golden paths.** Worked examples for common flows. Reduces token cost, prevents drift.

---

## 4. Environment Isolation Layer

### 4.1 Environment Definitions

Four environments with hard boundaries:

| Environment | Contains | Risk if leaked |
|-------------|----------|---------------|
| **Range** | Target data, Providentia intel, exploit PoCs, harvested creds | Scope violations, topology exposure |
| **Homelab** | Real credentials, UniFi config, partner-critical services | Real credential exposure, home network compromise |
| **Cloud** | API keys, billing data, RunPod/cloud tokens, DNS configs | Financial exposure, infrastructure takeover |
| **Public** | Open-source code, docs, skills, hook logic | Offensive content in public, secrets in git history |

### 4.2 Current State

**Implemented:**
- Mode-based tool isolation (12 modes, `tool-policy.yaml` deny lists)
- Secret path protection (tuoni-secret-guard, ctp-bridge path guard, gitleaks)
- Provenance and audit (tool call logging, session registration, mode alignment)
- Repo-level separation (project-routes.yaml, .gitignore, separate repos)
- Thread isolation (worktree strategy, per-thread mode override, dispatch guards)

**Gaps (ranked by risk):**

| Gap | Threat | Risk |
|-----|--------|------|
| Memory is global across sessions/modes | Creds saved to memory visible everywhere | HIGH |
| Master session context carries all environments | Cross-env data in dispatch prompts | HIGH |
| No content-level scanning that blocks (PostToolUse warn-only) | Secret in tool output written to wrong-env file | MEDIUM |
| Bash access to vault files not mode-gated | Obsidian engagement data readable via `cat` | MEDIUM |
| Repo-mode mismatch is warning, not hard deny | Thread in wrong mode operates on wrong repo | MEDIUM |
| Skills without `modes:` frontmatter pass in ALL modes | Offensive skill usable in homelab mode | LOW (double gate catches most) |

### 4.3 Proposed Layers

Six layers, building on what exists:

**Layer 0 — Environment Registry** (NEW)  
Central `environments.yaml` defining boundaries, sensitive patterns, mode
mappings, and secret stores per environment. Foundation for all other layers.

**Layer 1 — Context Walls** (NEW)  
- Dispatch context scrubber: scan dispatch prompts for cross-environment patterns
- Master session fence: routing-only context, no raw creds in master
- Memory environment tagging: memories tagged per environment, filtered on load

**Layer 2 — Secrets Management** (EXTEND)  
- Generalize tuoni-secret-guard into environment-secret-guard
- PreToolUse scan on Write/Edit for cross-env patterns in content
- Memory secret gate: block credential writes to memory files

**Layer 3 — Skill Isolation** (EXTEND)  
- Mandatory `modes:` audit on all 24 skills
- Add `environment:` tag to skill frontmatter for double gate

**Layer 4 — Repo Boundaries** (EXTEND)  
- Hard deny on cross-environment repo-mode mismatch (warn → deny)
- Commit content gate: environment-aware gitleaks patterns
- Public repo content policy: no offensive output, no engagement refs

**Layer 5 — Thread Isolation** (EXTEND)  
- Environment-scoped dispatch with path guards
- Thread-to-thread environment validation on `t3_thread_send`

**Layer 6 — Audit and Breach Detection** (EXTEND)  
- Cross-environment access log
- Session boundary audit
- Periodic git history scanner

### 4.4 Acknowledged Limitations

Hooks are string classifiers, not a sandbox. OS-level isolation does not exist
(same user account). PostToolUse cannot block output already in context. Operator
paste bypasses all file-read guards. These are documented in SAFETY_HARNESS.md.
Defense-in-depth reduces probability; it cannot eliminate it.

---

## 5. Cloud Integration Roadmap

### 5.1 Provider Priority

Based on operator mentions, existing tooling, and integration complexity:

| Priority | Provider | MCP Status | CLI | Effort | Rationale |
|----------|----------|-----------|-----|--------|-----------|
| **1** | Azure | Official GA (`microsoft/mcp`, 200+ tools) | `az` (not installed) | Medium | Operator's enterprise context, mature official MCP |
| **2** | Hetzner | Community (`hetzner-mcp-server`, 185 tools) | `hcloud` (not installed) | Low-Medium | Operator interest, simplest API, cheapest VMs |
| **3** | AWS | Official GA (`awslabs/mcp`, modular) | `aws` (not installed) | Medium-High | Largest ecosystem, highest complexity |
| **4** | Vercel | Official GA (`mcp.vercel.com`) | `vercel` (not installed) | Low | Zero-config deploys, good for frontends |
| **T3** | DigitalOcean | Official GA (`@digitalocean/mcp`) | `doctl` (not installed) | Low | Straightforward VM/PaaS |
| **T3** | Fly.io | Built-in experimental (`fly mcp server`) | `flyctl` (not installed) | Low-Medium | Good for persistent containers |

### 5.2 Integration Pattern

Each provider follows the same integration skeleton (proven by RunPod):

```
1. Install MCP server (official preferred, community evaluated, CLI fallback)
2. Write router skill (cloud-deploy-<provider>/SKILL.md)
3. Write journey skills (deploy, diagnose, cost audit)
4. Add golden path examples
5. Wire auth (env vars + CLI auth + request_secret fallback)
6. Add devcontainer CLI install (only for active providers)
7. Mode-gate: cloud-deploy skills available in dev + platform-ops modes
```

### 5.3 Foundation Work (before any provider)

- Generic `cloud-deploy` router skill
- Credential management pattern (env vars + CLI auth + `request_secret`)
- Common deploy flow template (classify → size → provision → deploy → verify)
- Terraform as universal IaC fallback (already installed)

### 5.4 Existing Assets to Leverage

| Asset | Reuse |
|-------|-------|
| `docker` (installed) | Build + push images for any provider |
| `terraform` (installed) | Universal IaC — works with all providers |
| RunPod plugin architecture | Proven router → journey → verify pattern |
| ctp-bridge gate stack | Safety pattern: pre-flight, confirm, lock, verify |
| azure-dev-harness repo | 7-phase bootstrap, Bicep modules, state tracking |

---

## 6. Context Safety

### 6.1 Problem

When a session approaches context limits, quality degrades silently. No detection.
No graceful handoff. Work gets repeated or lost.

### 6.2 Architecture — Status Line Bridge

The status line is the only runtime source of live token counts. Hooks have no
direct access. Solution: bridge via filesystem.

```
┌──────────────┐    write     ┌──────────────────┐    read     ┌──────────────┐
│  statusline  │ ───────────▶ │  /tmp/cc-context/ │ ◀───────── │  PreToolUse  │
│  (gets JSON) │              │  {session}.json   │             │    hook      │
└──────────────┘              └──────────────────┘             └──────────────┘
```

### 6.3 Thresholds

| Threshold | Trigger | Action |
|-----------|---------|--------|
| **75% context used** | Warning injected | Agent sees "begin wrapping up" message |
| **90% context used** | Hard gate | Tool calls blocked except Write to handover path |

### 6.4 Handover Mechanism

When hard gate fires:

1. Agent writes structured handover file to `.claude/handover/{session_id}.md`
2. Handover contains: original task, status, findings, decisions, next steps
3. Master-orchestrator detects handover, reads it, spawns fresh thread
4. Fresh thread gets clean context window with handover as prompt

Chain limit: 4 hops max. Beyond that, escalate to operator — task scoping is wrong.

### 6.5 Heuristic Fallback

When status line bridge unavailable (non-interactive sessions, background threads):
weighted tool-call count from audit trail gives ~±20% accuracy.

| Tool | Estimated tokens per call |
|------|--------------------------|
| Read | ~4000 (median) |
| Bash | ~1500 (median) |
| Write | ~1000 |
| Edit | ~350 |

### 6.6 Implementation Phases

1. **Bridge + Warning.** Enhance statusline.sh, add context-safety-catch.sh with warning only.
2. **Hard Gate + Handover.** Add blocking logic, handover template, Write exemption.
3. **Master Integration.** Handover monitoring in master-orchestrator, auto-continuation dispatch.
4. **Upstream.** Feature request: T3 thread-level token exposure via `t3_thread_read`.

---

## 7. Epic Decomposition

### Epic A: Fleet Cleanup

**Goal:** Reduce 45 repos to ~25. Remove noise, clarify fleet boundaries.

| Story | Effort | Dependency |
|-------|--------|-----------|
| A1: Tidy coursework repos — standardize READMEs, archive only truly dead ones (portfolio value) | S | None |
| A2: Evaluate coursework forks — keep meaningful additions, archive pure forks | S | None |
| A3: Consolidate AI experiment repos (keep Ai_Suite, archive duplicates) | S | None |
| A4: Extract weaponised_ansible patterns → HQ skills, archive | M | None |
| A5: Migrate nosense_ip_updater functions → official tuoni-mcp/range-intel, archive | M | None |
| A6: Archive Moon-Knight13/tuoni-mcp fork (using official shell-dot/tuoni-mcp) | S | None |
| A6: Add CLAUDE.md to homelab_planning | S | None |
| A7: Confirm CompTIA notes value → archive or keep | S | Operator decision |

**~7 stories. Estimated effort: 1 sprint.**

### Epic B: Environment Isolation Hardening

**Goal:** Close high-risk gaps in environment isolation.

| Story | Effort | Dependency |
|-------|--------|-----------|
| B1: Create `environments.yaml` registry (Layer 0) | M | None |
| B2: Audit all 24 skills for `modes:` frontmatter | S | None |
| B3: Add range IP/hostname patterns to `.gitleaks.toml` | S | None |
| B4: Generalize tuoni-secret-guard → environment-secret-guard (Layer 2) | M | B1 |
| B5: Dispatch context scrubber — `dispatch-context-gate.sh` (Layer 1) | M | B1 |
| B6: Memory environment tagging (Layer 1) | M | B1 |
| B7: Hard deny on cross-environment repo-mode mismatch (Layer 4) | S | B1 |
| B8: Memory secret gate — block credential writes (Layer 2) | S | B1 |
| B9: Commit content gate — environment-aware gitleaks (Layer 4) | M | B1 |
| B10: Add `environment:` tag to skill frontmatter (Layer 3) | S | B1, B2 |
| B11: Thread-to-thread environment validation (Layer 5) | S | B1 |
| B12: Cross-environment audit report (Layer 6) | M | B1 |

**~12 stories. Estimated effort: 2–3 sprints.**

### Epic C: Deploy Target Abstraction + Generic Deploy Skill

**Goal:** Common deploy pipeline with pluggable target adapters.

| Story | Effort | Dependency |
|-------|--------|-----------|
| C1: Define common pipeline stage interface | M | None |
| C2: Write `cloud-deploy` router skill | M | C1 |
| C3: Extract ctp-bridge safety gates into reusable functions | M | None |
| C4: Credential management pattern (env + CLI auth + request_secret) | M | None |
| C5: Common verify-with-traffic health check module | S | None |
| C6: Common state recording pattern | S | None |
| C7: Golden path template for new provider onboarding | S | C2 |

**~7 stories. Estimated effort: 1–2 sprints.**

### Epic D: First Cloud Provider Integration (Azure + Hetzner)

**Goal:** Two cloud deploy targets operational end-to-end.

| Story | Effort | Dependency |
|-------|--------|-----------|
| D1: Install + configure `microsoft/mcp` (Azure MCP server) | M | C2 |
| D2: Write `cloud-deploy-azure` journey skill (Container Apps) | L | D1, C4 |
| D3: Azure golden path: deploy containerized web app | M | D2 |
| D4: Evaluate Hetzner community MCP (`hetzner-mcp-server`) | M | C2 |
| D5: Write `cloud-deploy-hetzner` journey skill (cloud servers) | M | D4, C4 |
| D6: Hetzner golden path: provision VM + deploy Docker app | M | D5 |
| D7: Add `az` and `hcloud` CLIs to devcontainer | S | D1, D4 |
| D8: `cloud-deploy-doctor` journey skill (diagnose failures) | M | D2, D5 |
| D9: `cloud-deploy-cost` journey skill (cost audit) | M | D2, D5 |
| D10: Wire cloud-deploy skills into mode filter (dev + platform-ops) | S | D2, D5 |

**~10 stories. Estimated effort: 2–3 sprints.**

### Epic E: Context Safety Catch

**Goal:** Automated context limit detection, warning, hard gate, and handoff.

| Story | Effort | Dependency |
|-------|--------|-----------|
| E1: Enhance statusline.sh to write context state to bridge file | S | None |
| E2: Write `context-safety-catch.sh` PreToolUse hook (warning only) | M | E1 |
| E3: Register hook in settings.json | S | E2 |
| E4: Validate: run long session, observe warnings | S | E3 |
| E5: Add hard gate logic with Write exemption | M | E4 |
| E6: Create handover file template | S | None |
| E7: Add handover instructions to CLAUDE.md | S | E6 |
| E8: Validate: intentionally fill context, observe gate + handover | M | E5, E7 |
| E9: Add handover monitoring to master-orchestrator | L | E8, Epic F |
| E10: Implement continuation dispatch (read handover → spawn fresh thread) | L | E9 |
| E11: Chain tracking (multi-hop handover management) | M | E10 |
| E12: Heuristic fallback for non-interactive sessions | M | E2 |

**~12 stories. Estimated effort: 2–3 sprints.**

### Epic F: Master-Orchestrator Skill

**Goal:** Generalized dispatch, tracking, and chain management from master session.

| Story | Effort | Dependency |
|-------|--------|-----------|
| F1: Extract dispatch patterns from engagement-orchestration | M | None |
| F2: Generalized dispatch template (mode, model, workspace, handover instructions) | M | F1 |
| F3: Thread monitoring with native `t3_thread_wait` | M | F2 |
| F4: Multi-wave dispatch (sequential dependency chains) | L | F3 |
| F5: Handover chain management (from Epic E) | L | F3, E10 |
| F6: PR consolidation logic (batch related changes) | M | F3 |
| F7: Dispatch validation — mode, workspace, model pin enforcement | M | F2 |
| F8: Status reporting — progress summary for operator | M | F3 |

**~8 stories. Estimated effort: 2 sprints.**

---

## 8. Priority Order

### Dependency Graph

```
Epic A (Fleet Cleanup)          ── independent, do first
Epic B (Env Isolation)          ── independent, do first
Epic C (Deploy Abstraction)     ── foundation for D
Epic D (Cloud Providers)        ── depends on C
Epic E (Context Safety)         ── E1-E8 independent; E9-E11 depend on F
Epic F (Master Orchestrator)    ── independent for F1-F4; F5 depends on E
```

### Recommended Order

| Wave | Epics | Rationale |
|------|-------|-----------|
| **Wave 1** | **A** (Fleet Cleanup) + **B1-B3** (Isolation quick wins) | Highest cleanup-to-effort ratio. B1-B3 close highest-risk gaps with minimal effort. No dependencies. |
| **Wave 2** | **B4-B12** (Isolation hardening) + **E1-E4** (Context safety warning) + **F1-F3** (Orchestrator foundation) | B closes remaining gaps. E warning-only is low risk. F foundation needed before E9+. All parallelizable. |
| **Wave 3** | **C** (Deploy abstraction) + **E5-E8** (Context safety hard gate) | C builds foundation for cloud providers. E hard gate + handover is proven by Wave 2 warning data. |
| **Wave 4** | **D** (Cloud providers) + **E9-E12** (Context safety master integration) + **F4-F8** (Orchestrator completion) | D needs C. E master integration needs F. F completion enables full autonomous dispatch. |

### Decision Criteria

1. **Security first** (B before D) — environment isolation gaps are active risk. Cloud integration adds new surfaces.
2. **Foundation before features** (C before D, F before E9+) — abstractions prevent rework.
3. **Cleanup before building** (A first) — fewer repos = less noise, clearer fleet.
4. **Validate before hardening** (E warning before E hard gate) — calibrate thresholds from real data.
5. **Parallel where possible** — Waves 1-2 have no cross-epic dependencies.

### Rough Timeline

| Wave | Stories | Estimated sprints |
|------|--------:|------------------:|
| Wave 1 | ~10 | 1 |
| Wave 2 | ~19 | 2–3 |
| Wave 3 | ~11 | 2 |
| Wave 4 | ~22 | 3–4 |
| **Total** | **~62** | **8–10** |

---

## Appendix A: Cross-Contamination Risk Matrix

| Repo | Public? | Offensive? | Risk if closer to HQ |
|------|---------|-----------|---------------------|
| tuoni-mcp (official: shell-dot/tuoni-mcp) | No | Yes (C2) | CRITICAL — stays separate, private. Moon-Knight13/tuoni-mcp fork → archive |
| tuoni-plugins | No | Yes (payloads) | CRITICAL — must stay separate, private |
| weaponised_ansible | No | Yes (exploitation) | HIGH — extract patterns, don't merge |
| nosense_ip_updater | No | Partial | MEDIUM — migrate functions only |
| homelab_planning | No | No, identity-linking refs | MEDIUM — never make public |
| All others | Mixed | No | LOW/NONE |

## Appendix B: Existing Hook Execution Order (with new hooks marked)

```
UserPromptSubmit:
  1. mode-inject.sh              → mode prompt, repo-mode match
  2. secret-scan.sh              → secrets in user input

PreToolUse (all):
  3. audit-trail.sh              → log with environment tag
  4. pretooluse-provenance.sh    → session + mode verification
  5. mode-tool-gate.sh           → MCP deny per tool-policy.yaml
  6. dispatch-validation-guard.sh → workspace strategy

PreToolUse (Bash/Read/Write/Edit):
  7. environment-secret-guard.sh → cross-env path deny [NEW — B4]
  8. pretooluse-ctp.sh           → ctp-bridge path guard
  9. write-content-scanner.sh    → cross-env pattern in write [NEW — B9]
  10. context-safety-catch.sh    → context limit warning/gate [NEW — E2]

PreToolUse (Skill):
  11. skill-mode-gate.sh         → mode + environment validation

PreToolUse (dispatch):
  12. master-dispatch-guard.sh   → force T3 threads
  13. dispatch-context-gate.sh   → cross-env data in prompt [NEW — B5]
  14. remote-thread-approval-guard.sh → remote launch approval

PostToolUse:
  15. response-scanner.sh        → warn on secrets (cannot block)
  16. auto-log-finding.sh        → engagement finding extraction

Stop:
  17. session-end-audit.sh       → cross-env access report [EXTENDED — B12]
```

## Appendix C: Environment-to-Mode Mapping

```
range:    red-team, purple, pentest, ctf, green-dev, bounty
homelab:  homelab
cloud:    dev, platform-ops
public:   dev, platform-ops, base
```

`dev` and `platform-ops` map to both `cloud` and `public` — they work on public
repos that may reference cloud infrastructure. Tool-policy denies prevent
offensive tool access. Content gates prevent secret leakage.

`base` maps to `public` only. Fully permissive for dispatch routing. Never
directly executes environment-specific work.
