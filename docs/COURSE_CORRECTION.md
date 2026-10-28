# Course Correction — October 2026

## What Changed

The project has migrated from **remote deploybox as primary workspace** to
**devcontainer on host laptop as primary**, with the deploybox becoming a spoke.

| Before (deploybox-primary) | After (devcontainer-primary) |
|---|---|
| Claude runs ON the deploybox | Claude runs in devcontainer on host laptop |
| ctp-bridge uses local `docker exec` | ctp-bridge needs remote execution path |
| SSH agent forwarding from laptop | Direct `gh` auth in devcontainer |
| Shared OS account, killswitch needed | Personal laptop, single user |
| Provisioning script sets up box | `setup-day0.sh` sets up devcontainer |
| Box has Docker, Java, build tools | Build tools on box, reached as spoke |

## What Was Dropped

- **SP1a orchestrator/gate** — 28 issues closed, code archived to
  `archive/sp1a-gate` branch. Opus 4.6 eliminates need for local-model routing
  and sensitivity classification. Routing subsystem removed (commit 141d96f).
- **Killswitch** — shared-account credential hygiene, not needed on personal laptop.
- **SSH agent socket juggling** — devcontainer has direct `gh` auth.
- **Local model routing** — dropped in favour of Opus 4.6 primary, OpenCode +
  local model as manual failover.

## What Stays (v2 architecture, confirmed)

From the Oct 2026 design session (memory: `my-claude-dev-architecture-v2`):

- **Hub-and-spoke model** with 5 modes (red-team, red-dev, green-dev, purple,
  range-build)
- **15+ MCP servers** per mode (see memory: `mcp-research-stack`)
- **Kali spoke** via Tuoni agent as primary weapons platform
- **Deploy box spoke** via catapult/ctp-bridge (needs remote exec path)
- **Truth hierarchy:** Providentia > deploy box > Kali state
- **Failover:** Opus 4.6 primary → OpenCode + local model → CLI helper scripts
- **Mode switching:** `run.sh` generates `.claude/CLAUDE.md` + settings from
  mode templates + `.env` + range profile

## Current State (what's built and working)

### Infrastructure (devcontainer)
- Guard hooks (commit, safety, git, PII) — installed on setup, all passing
- Default model (Opus 4.6) — set on setup
- Firewall, plugin install, config deploy — automated
- Memory, projects, Claude config — bind-mounted from host, persistent
- GitHub settings, Kanban board — bootstrapped

### Range tooling (built on deploybox, needs spoke adaptation)
- **ctp-bridge** — works locally on box, no remote exec path from devcontainer
- **range-intel MCP** — 7 tools, Providentia + GitLab READMEs (connects over VPN)
- **tuoni-mcp** (shell-dot official) — installed, PR #1 open
- **tuoni-plugins** — 12 attack modules deployed, plugin architecture v2 designed
- **ctp-deploy-range** — ordered bulk deploy script (local `docker exec`)

### Not built yet (from v2 design)
- Mode switching mechanism (`run.sh`, templates, range profiles)
- Skills content (recon, initial-access, deploy-agent procedures)
- Attack tree / task state management
- Operator takeover protocol
- Report export pipeline (Obsidian → DOCX/PDF)
- Purple scoring
- Platform-ops monitoring

## Open Issues (10 remaining)

| # | Category | Summary |
|---|----------|---------|
| 82 | Enhancement | Block prompts containing pasted secrets |
| 79 | Infra | Docker prune scheduling |
| 78 | Bug | test-day0.sh failures (PR #158 pending merge) |
| 55 | Infra | CVE trivyignore (check if still needed) |
| 37 | Constraint | gh-CLI only board, no GitLab portability |
| 36 | Dead | Killswitch SSH key material (close: not needed) |
| 34 | Security | Rotate connection detail in git history |
| 31 | Infra | Firewall IPv4-only |
| 30 | Infra | postStartCommand chain fragility |
| 29 | Infra | Firewall UDP/53 no TCP/53 |

## Critical Gaps (input for planning)

1. **ctp-bridge remote execution** — devcontainer cannot reach box's catapult
   container. Options: SSH command wrapping or keep bridge on box + trigger
   remotely. This blocks all deploy operations.

2. **PROJECT.md rewrite** — still describes "provisioning for remote developer
   boxes" as primary purpose. Needs devcontainer-first identity.

3. **Spoke SSH tunnel setup** — `scripts/local/bootstrap-devbox.sh` exists for
   laptop→box SSH but needs adaptation for devcontainer→box path.

4. **Mode switching** — v2 architecture core feature, not built. `run.sh` +
   mode templates + `.env` + range profile.

5. **Docs rewrite** — SAFETY_HARNESS.md, README.md describe box-primary model.

## Hardware (host laptop)

- AMD Ryzen AI 9 HX 370 (12C/24T Zen 5)
- 92GB RAM (LPDDR5x)
- Radeon 890M iGPU (RDNA 3.5, no CUDA)
- Local model: qwen2.5-coder:32b via Ollama CPU (~8-15 tok/s)

## Decision Record

| Date | Decision | Supersedes |
|---|---|---|
| 2026-10-27 | Archive SP1a gate, drop routing subsystem | SP1-SP6 roadmap |
| 2026-10-27 | Opus 4.6 primary, OpenCode + local failover | LiteLLM gateway |
| 2026-10-28 | Migrate to devcontainer-first | Deploybox as primary |
| 2026-10-28 | Close 28 SP1a issues as superseded | SP1a board |
| 2026-10-28 | v2 hub-spoke with 5 modes confirmed | v1 orchestrator |
