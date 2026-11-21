# Existing Frameworks Survey — E2E Factory Prior Art

**Status:** Draft — operator review  
**Date:** 2026-11-21  
**Companion to:** e2e-factory-architecture.md

---

## 1. Agent-Driven Deployment / Orchestration

### 1.1 VocanicZ/Harness

- **What:** Project-agnostic orchestrator that drives a fixed pool of autonomous
  Claude Code sessions against a GitHub issues board. Stateless, resumable from
  any host. Claims issues authored by the authenticated user (configurable via
  `HARNESS_AUTHOR_ALLOWLIST`). Installs superpowers + matt-pocock skills
  automatically.
- **Maturity:** Active GitHub project, single developer. Exact star count not
  confirmed. Ships as a one-line curl install.
- **Fit for us:** Issue-driven dispatch pattern is similar to our `/next-issue`
  board.sh model. Does NOT handle deployment targets — it orchestrates coding
  work, not releases. Could inform how we structure multi-session dispatch.
- **Gap:** No deploy pipeline, no environment awareness, no mode concept.
- **Link:** https://github.com/VocanicZ/Harness

### 1.2 daopapp/software-factory

- **What:** 26 specialised agents with parallel wave dispatch for Claude Code.
  Installed as symlinks so edits take effect immediately.
- **Maturity:** GitHub project. Agent roster not fully confirmed from search
  snippets. Appears to be a community project, not widely adopted.
- **Fit for us:** Parallel wave dispatch is similar to our thread dispatch model.
  Worth reading their agent role definitions and wave sequencing.
- **Gap:** No deploy targets, no environment isolation, no MCP integration
  mentioned.
- **Link:** https://github.com/daopapp/software-factory

### 1.3 SethGammon/Citadel

- **What:** Agent orchestration system for Claude Code. Copy `.claude`,
  `.planning`, and `scripts` folders into your project.
- **Maturity:** Not widely referenced. Appears to be a personal project.
- **Fit for us:** Similar "copy skills into project" approach. Worth checking
  their planning structure.
- **Link:** https://github.com/SethGammon/Citadel

### 1.4 pikehouse/crew

- **What:** Multi-agent orchestrator for Claude Code using git worktrees per
  agent.
- **Maturity:** Not widely referenced.
- **Fit for us:** Worktree-per-agent matches our T3 `workspaceStrategy:
  worktree` pattern. Worth verifying their implementation.
- **Link:** https://github.com/pikehouse/crew

### 1.5 leighmcculloch/orc

- **What:** Picks up pending tasks and starts Claude Code agents automatically.
- **Maturity:** Minimal project.
- **Fit for us:** Simplest possible auto-dispatch. Too minimal for our needs but
  demonstrates the pattern.
- **Link:** https://github.com/leighmcculloch/orc

### 1.6 ruvnet/metaharness

- **What:** Generates a custom agent harness for a repo, with Claude Code as
  one host option.
- **Maturity:** Not widely referenced.
- **Fit for us:** "Generate harness per repo" is an interesting pattern for
  satellite repos.
- **Link:** https://github.com/ruvnet/metaharness

### 1.7 Claude Code Native Multi-Agent Layers

Claude Code ships three orchestration layers (2026):

| Layer | Since | Use case |
|---|---|---|
| **Subagents** | v2.0+ | Worker definitions in `.claude/agents/` Markdown files, spawned per task |
| **Agent Teams** | v2.1.32 (Feb 2026) | Research preview. Agents claim tasks from board, merge changes, resolve conflicts. Single-model constraint. |
| **Dynamic Workflows** | May 2026 | Script-driven orchestration of dozens of subagents. Deterministic reruns. |

**Fit for us:** We already use subagents and workflows. Agent Teams could replace
manual `/run-epic` dispatch if it matures. Single-model constraint is fine (we
pin opus-4-6 anyway).

**Gap:** None of these handle *deployment targets* — they orchestrate code work,
not infra lifecycle.

Sources:
- [Tembo: Claude Code Multi-Agent Orchestration](https://www.tembo.io/blog/claude-code-multi-agent-orchestration)
- [Addy Osmani: Code Agent Orchestra](https://addyosmani.com/blog/code-agent-orchestra/)

### 1.8 AWS Well-Architected Agentic AI Lens

AWS published AgentOps guidance adding behavioral evaluation gates to CI/CD:
- Behavioral evaluation gate (not just unit tests)
- Security scan stage
- Staged rollout with automated rollback

**Fit for us:** Our safety gates (pre-commit, semgrep, gitleaks) cover security.
Behavioral evaluation gate is a gap — we don't test agent behavior as part of CI.

Source: [AWS AgentOps](https://docs.aws.amazon.com/wellarchitected/latest/agentic-ai-lens/agentops03-bp02.html)

### 1.9 Sandcastle (mattpocock/sandcastle)

- **What:** Runs coding agents in isolated Docker/Podman/Vercel sandboxes.
  Claude Code is the default agent provider. Single invocation produces at most
  one commit.
- **Maturity:** Active, well-known in TypeScript community. Provider-agnostic
  (supports Claude Code, Codex, Pi, Cursor, OpenCode, Copilot).
- **Fit for us:** Sandbox isolation is valuable for untrusted code execution.
  NOT a deployment tool — it produces commits, not releases. No deploy pipeline.
- **Gap:** No multi-environment awareness, no deploy targets.
- **Link:** https://github.com/mattpocock/sandcastle

---

## 2. Claude Code Ecosystem — Deploy Skills & Plugins

### 2.1 Railway Plugin (railwayapp/railway-claude-plugin)

- **What:** Official Railway plugin for Claude Code. Skills in `SKILL.md` files,
  loads via `--plugin-dir`.
- **Maturity:** Official vendor plugin. Railway is a production PaaS.
- **Fit for us:** Best example of a vendor deploy skill. Could use as a
  reference for writing our own deploy adapter skills.
- **Link:** https://github.com/railwayapp/railway-claude-plugin

### 2.2 brewtools:deploy (kochetkov-ma/claude-brewcode)

- **What:** Handles GitHub Actions workflows and deploy-admin agent generation.
- **Maturity:** Community skill. Limited adoption data.
- **Fit for us:** Shows how to wrap CI/CD triggers as a Claude Code skill.
- **Link:** https://skillselion.com/skills/kochetkov-ma/claude-brewcode/brewtools%3Adeploy

### 2.3 fluid-notion-labs/claude-deploy-skill

- **What:** Deploy skill focused on GitHub push workflows. Notes that
  api.github.com is blocked, no SSH, tokens expire after 1 hour.
- **Maturity:** Community skill. Documents real sandbox limitations.
- **Fit for us:** Useful for understanding Claude Code sandbox constraints when
  deploying from agent context.
- **Link:** https://skills.cat/skills/fluid-notion-labs/claude-deploy-skill

### 2.4 Skill Registries

Multiple registries exist for discovering Claude Code skills:
- claudskills.com — open SKILL.md registry
- claudemarketplaces.com — skill marketplace
- skillselion.com — skill directory

None had a mature multi-target deploy skill. Most "deploy" skills push to a
single platform (GitHub Pages, Railway, Netlify).

### 2.5 Claude Agent SDK — Hosting Patterns

Anthropic's official Agent SDK hosting docs describe deployment patterns:
- **Ephemeral sessions:** Stateless, one-shot.
- **Resumable sessions:** Resume by ID against shared store.
- **Multi-agent container:** Multiple SDK processes in one container.
- **Deployment targets:** Docker, Modal, Kubernetes (cookbook examples).

**Gap:** SDK provides session primitives, not deployment orchestration. Teams
build retry logic, durable execution, multi-tenant deployment, and observability
themselves.

**Link:** https://code.claude.com/docs/en/agent-sdk/hosting

---

## 3. MCP-Based Deploy Servers (Vendor)

### 3.1 Railway MCP

- **What:** Official MCP server. Create projects, deploy templates, manage
  environments, pull variables, redeploy. Local server has full capabilities;
  remote at mcp.railway.com is limited.
- **Maturity:** Production. Official vendor.
- **Fit for us:** Excellent adapter candidate for cloud VPS target. Already
  provides environment management.
- **Link:** https://docs.railway.com/ai/mcp-server

### 3.2 Netlify MCP

- **What:** Official server (June 2026). 9 tools — create projects, deploy
  apps, manage infrastructure.
- **Maturity:** Production. Official vendor.
- **Fit for us:** Static site / JAMstack deploy target. Less relevant for our
  container-heavy workloads.
- **Link:** https://www.netlify.com/blog/netlify-mcp-server-ai-agents-deploy-your-code

### 3.3 Vercel MCP

- **What:** Official remote MCP with OAuth at mcp.vercel.com. All plans. Only
  works with Vercel-approved AI clients.
- **Maturity:** Production. Official vendor.
- **Fit for us:** Limited by client approval list. Less relevant unless
  deploying Next.js frontends.

### 3.4 Qovery

- **What:** Blog describes MCP server for infrastructure deploy with AI agents.
  Exposes deploy, provision, scale, observe as MCP tools.
- **Maturity:** Blog-level description. Full MCP server not confirmed as GA.
- **Fit for us:** Governance model (who deploys where, budget, audit trail) is
  relevant to our multi-target architecture.
- **Link:** https://www.qovery.com/blog/mcp-server-for-infrastructure-deploy-with-ai-agents

### 3.5 DeployHQ MCP

- **What:** AI-powered deployment management via MCP.
- **Maturity:** Announced. Limited details from search.
- **Fit for us:** Worth monitoring.
- **Link:** https://www.deployhq.com/blog/introducing-the-deployhq-mcp-server-ai-powered-deployment-management

---

## 4. GitOps / Multi-Cluster Tools with MCP

### 4.1 ArgoCD MCP Server

- **What:** Open-source MCP server in argoproj-labs/mcp-for-argocd (by Akuity).
  Stdio and HTTP transports. Works with VS Code, Cursor, Claude Desktop. PyPI
  package `mcp-argocd` also available.
- **Maturity:** Official argoproj-labs project. Akuity (commercial ArgoCD
  vendor) maintains it. Active as of October 2026.
- **Fit for us:** Strong candidate if we adopt ArgoCD for any target. Read-only
  mode available. Could query app sync status, trigger syncs.
- **Gap:** No Backstage integration via MCP. Would need separate wiring.
- **Link:** https://github.com/argoproj-labs/mcp-for-argocd

### 4.2 FluxCD MCP Server

- **What:** Experimental MCP server in Flux Operator project (AGPL-3.0). Reads
  kubeconfig for auth, switches between cluster contexts. Cross-cluster
  comparison. Read-only mode available. Homebrew install. Streamable HTTP.
- **Maturity:** Experimental. Maintained by ControlPlane.io (Flux commercial
  entity). Enterprise customers use at own discretion.
- **Fit for us:** Best multi-cluster GitOps MCP option. Cross-cluster comparison
  is directly useful for fleet model. Agent Skills include
  `gitops-cluster-debug`.
- **Gap:** Experimental status. AGPL license may be a concern for some.
- **Link:** https://fluxoperator.dev/mcp-server/

### 4.3 Backstage MCP

- **What:** Backstage exposes catalog + Software Templates as MCP tools via its
  MCP Actions Backend. Can define multiple named servers (catalog, scaffolding).
  Red Hat Developer Hub 1.8 adds catalog and TechDocs MCP plugins.
- **Maturity:** Built into Backstage (Spotify). Production for Backstage users.
- **Fit for us:** Software catalog concept maps to our fleet model. Could
  register deploy targets as catalog entities. Overkill for single-operator —
  Backstage targets platform teams, not solo operators.
- **Gap:** Heavy infrastructure requirement (Backstage instance, PostgreSQL,
  plugins). Solo-operator overhead too high.
- **Link:** https://backstage.io/docs/ai/mcp-actions

---

## 5. IaC Multi-Environment Orchestration

### 5.1 Pulumi

- **What:** IaC in real languages (TypeScript, Python, Go). Pulumi MCP server
  exists (local and hosted). Fleet provisioning via stacks. Native Terraform/HCL
  support added January 2026.
- **Stack model:** One stack per environment. Cross-stack dependencies for shared
  resources. Deployment Settings per stack. Scheduled drift detection runs.
  Stack promotion pattern (dev→staging→prod) with approval gates. Kargo
  integration for K8s verification-before-promotion.
- **Automation API:** TypeScript/Python library — drive Pulumi programmatically
  without CLI. Can embed in agent workflows directly.
- **Maturity:** Production. Well-funded startup. Large community.
- **Fit for us:** Best IaC option. Stack model maps to our target profiles
  (range/homelab/cloud). Single-operator friendly — stacks are config, no team
  overhead. Automation API means HQ can call Pulumi from skills without shelling
  out to CLI.
- **Gap:** Cloud-hosted control plane optional. We use local state + CLI, not SaaS.
- **Links:**
  - https://www.pulumi.com/topics/agentic-infrastructure/mcp-for-infrastructure-as-code/
  - https://www.pulumi.com/docs/platform/deployments/
  - https://www.pulumi.com/guides/solutions/pulumi-cicd-promotion/pulumi-deployments/

### 5.2 Spacelift

- **What:** IaC orchestration platform. Stack dependencies pass outputs between
  stacks. Per-stack state, policies, lifecycle.
- **Maturity:** Production. Enterprise pricing (~$16k/yr at 3 workers).
- **Fit for us:** Too expensive and enterprise-focused for single operator.
  Stack dependency model is a useful pattern to study.
- **Link:** https://spacelift.io/blog/env-zero-vs-spacelift

### 5.3 env0

- **What:** IaC automation. Dependent deployment runs across environments.
  Org/project/environment access controls.
- **Maturity:** Production. Enterprise pricing (~$18k/yr at 80 environments).
- **Fit for us:** Same as Spacelift — too expensive. "Apply all" for
  multi-environment is a useful UX pattern.
- **Link:** https://env0.com/solutions/automate-the-full-deployment-lifecycle

### 5.4 Google Cloud Deploy

- **What:** Delivery pipeline with multi-target parallel deploys to child
  targets (GKE fleet clusters). Single pipeline stage fans out to child targets.
  Cross-project targets. Approval gates. Execution environment inheritance.
- **Maturity:** GA. GCP only.
- **Fit for us:** Multi-target fan-out pattern is exactly what we need for
  parallel deploys. GCP-only limits adoption. Pattern is portable.
- **Links:**
  - https://docs.cloud.google.com/deploy/docs/parallel
  - https://docs.cloud.google.com/deploy/docs/deploy-app-parallel

### 5.5 Rafay Fleet Plans

- **What:** Fleet-wide operations across environments (Jan 2026). Multi-level
  filtering by projects, labels, and templates. Scheduled runs. Central dashboard.
- **Maturity:** New (Jan 2026). K8s-focused.
- **Fit for us:** Closest to "fleet model with modes/profiles" concept. Filtering
  by labels maps to our mode system. Fleet-wide operations with rollout control
  is what our dispatcher needs.
- **Gap:** Kubernetes-only. SaaS control plane.
- **Link:** https://docs.rafay.co/blog/2026/01/29/managing-environments-at-scale-with-fleet-plans/

---

## 6. MCP Infrastructure Patterns

### 6.1 Red Hat MCP Lifecycle Operator

- **What:** Deploys MCP servers on OpenShift via MCPServer CRD. Health probes,
  autoscaling.
- **Maturity:** Red Hat supported. OpenShift only.
- **Fit for us:** Shows how to containerize and operate MCP servers in K8s.
  Pattern useful even without OpenShift.
- **Link:** https://www.redhat.com/en/blog/manage-mcp-servers-red-hat-openshift-mcp-lifecycle-operator

### 6.2 MCP Spec July 2026 Changes

- The July 2026 MCP spec revision removed the initialize handshake and protocol-
  level sessions. Any healthy replica can handle a request. Simplifies horizontal
  scaling of MCP servers.
- **Fit for us:** Important for our MCP server design. Stateless MCP servers are
  now first-class.

---

## 7. Software Factory Frameworks (General)

### 7.1 Twin Sun Scarif

- **What:** Nashville agency built autonomous factory using Claude Code agents
  for most of SDLC. Named "Scarif."
- **Maturity:** Reported by ZenML. No public repo found.
- **Fit for us:** Closest real-world analogue to our vision. Confirm via their
  published case study if details available.
- **Link:** https://zenml.io/llmops-database/building-an-ai-powered-software-factory-with-autonomous-code-generation-and-review

### 7.2 FlorianBruniaux/claude-code-ultimate-guide

- **What:** Community guide with sections on agentic software factories and
  agentic tools. Describes harness → orchestration → skills → delivery stack.
- **Maturity:** Community documentation.
- **Fit for us:** Good conceptual alignment. Worth reading the factory and tools
  sections.
- **Link:** https://github.com/FlorianBruniaux/claude-code-ultimate-guide

---

## 8. Summary — What to Adopt vs Build

### Adopt directly (MCP servers as deploy adapters)

| Tool | Target | Action |
|------|--------|--------|
| ArgoCD MCP | K8s clusters with ArgoCD | Install, configure per target |
| FluxCD MCP | K8s clusters with Flux | Install (experimental), evaluate |
| Railway MCP | Cloud VPS (Railway) | Install, write deploy skill |
| Pulumi MCP | Multi-cloud IaC | Evaluate for infra provisioning |

### Study and adapt patterns

| Pattern | Source | Apply to |
|---------|--------|----------|
| Issue-driven dispatch | VocanicZ/Harness | Validate our board.sh model |
| Parallel wave dispatch | daopapp/software-factory | Thread wave sequencing |
| Worktree-per-agent | pikehouse/crew | T3 worktree strategy |
| Deploy skill structure | Railway plugin | Write our adapter skills |
| Sandbox constraints | fluid-notion-labs | Agent deploy guardrails |
| Governance model | Qovery blog | Multi-target access control |
| Multi-target parallel | Google Cloud Deploy | Pipeline stage design |
| Stateless MCP | July 2026 spec | MCP server architecture |
| Stack-per-environment | Pulumi / Terraform | Target profile structure |
| Variable scoping hierarchy | Terraform Cloud | mode → target → operation secret isolation |
| Fleet repo with per-target dirs | Flux CD | `targets/<name>/` layout in HQ |
| Tiered rollout | Flux CD | range/test → homelab → cloud promotion |
| Pull-based reconciliation | ArgoCD Agent | ctp-bridge already implements this |
| Behavioral evaluation gate | AWS AgentOps | Agent behavior testing in CI |
| Fleet label filtering | Rafay Fleet Plans | Mode system as fleet filter |

### Build ourselves (nothing exists)

| Component | Why |
|-----------|-----|
| Mode-aware deploy dispatcher | No tool handles mode-based environment isolation |
| Multi-target adapter layer | No single tool spans range + homelab + cloud |
| Context-safety handoff | No factory tool detects context exhaustion |
| Secret compartmentalization | No MCP deploy tool enforces our mode-based walls |
| ctp-bridge integration | Range-specific, no existing tool |

### Skip (doesn't fit single-operator model)

| Tool | Reason |
|------|--------|
| Backstage | Platform-team scale; too heavy |
| Spacelift / env0 | Enterprise pricing, team-oriented |
| Vercel MCP | Client approval restriction |

---

## 9. Key Takeaway

No existing framework combines agent orchestration + multi-environment deploy +
mode-based isolation + single-operator scale. The closest pieces are:

1. **MCP deploy servers** (Railway, ArgoCD, Flux, InfraOps) as target adapters
2. **Agent orchestrators** (VocanicZ/Harness, daopapp/software-factory) for
   dispatch patterns
3. **IaC tools** (Pulumi with MCP + Automation API) for infra provisioning
4. **GitOps patterns** (ArgoCD hub-spoke, Flux fleet repo layout) for
   multi-target reconciliation

**Critical insight from IaC survey:** Every orchestration tool (Pulumi Cloud,
Terraform Cloud, Spacelift, env0, Rafay) uses a stack/workspace-per-environment
model — but all assume a SaaS control plane or CI/CD pipeline as execution
context. None support agent-driven orchestration from a local seat. That gap is
what our factory fills.

**Critical insight from factory discourse:** Most "AI software factory" diagrams
stop at deploy (LaunchDarkly observation). Post-deploy verification, observability,
and rollback are underdeveloped everywhere. We must build this explicitly.

Our value-add is the **glue layer**: mode-aware dispatch, secret
compartmentalization, context-safety, post-deploy verification, and the adapter
abstraction that makes "deploy to range" and "deploy to cloud" feel identical
to the operator.

---

---

## Appendix A — Expanded Web Survey (2026-11-21, second pass)

### A.1 GitOps Multi-Cluster Patterns (Deep Dive)

**ArgoCD architectural patterns:**
- **Hub-and-spoke:** One ArgoCD manages all clusters. Works to ~10-20 clusters. Beyond that, federated model recommended. ([Red Hat guide](https://developers.redhat.com/articles/2025/06/24/how-automate-multi-cluster-deployments-using-argo-cd))
- **ApplicationSets with generators:** Fan one app to N clusters via cluster labels or Git directory generators. The pattern that most resembles our "shared pipeline + per-target config." ([AWS EKS best practices](https://aws-samples.github.io/sample-apex-skills/docs/skills/eks-best-practices/references/argocd-patterns))
- **Argo CD Agent (pull-based):** Agents on spoke clusters pull changes from hub. No exposed cluster APIs. ([Red Hat OpenShift GitOps 1.21](https://docs.redhat.com/it/documentation/red_hat_openshift_gitops/1.21/html/argo_cd_agent_architecture/argocd-agent-architecture)) — Maps directly to ctp-bridge's pull model.
- **App of Apps:** Parent Application declares children. Combined with ApplicationSets for platform bootstrapping.

**Flux CD architectural patterns:**
- **Distributed (recommended by maintainers):** Each cluster runs its own Flux, reconciles from shared repo. Best blast-radius isolation. ([Stefan Prodan, Flux maintainer](https://medium.com/@stefanprodan/fluxcd-multi-cluster-architecture-e426fb2bca0f))
- **Fleet repo layout:** `clusters/<name>/` directories with shared infra + per-target overrides. Direct model for our `targets/<name>/` layout.
- **Tiered rollout:** Pilot groups of 2-5 clusters receive changes first, then promote. Maps to our range/test → homelab → cloud promotion.
- **Flux Operator:** FluxInstance resource per cluster gives version-controlled installs across fleet.

**Adoptable patterns for our model:**

| GitOps pattern | Our adaptation |
|---|---|
| Fleet repo with per-target directories | `targets/<target-name>/` in HQ |
| Pull-based reconciliation (Argo CD Agent) | ctp-bridge already implements this |
| ApplicationSets / generators | Deploy skill generates per-target config from shared template |
| Distributed reconciliation | Each target verifies its own state independently |
| Tiered rollout | Range/test → homelab → cloud promotion |

### A.2 Terraform Cloud Multispace Pattern

HashiCorp's official guidance ([multispace pattern](https://hashicorp.com/en/blog/terraform-apply-as-code-the-multispace-pattern), [recommended practices](https://developer.hashicorp.com/terraform/cloud-docs/recommended-practices/part1)):

- One workspace per component per environment. Cross-workspace ordering via run triggers or `tfe_workspace_run`.
- Variable scoping: account → environment → workspace inheritance. Lower scope wins. — Maps to our mode → target → operation secret isolation.
- Auto-apply for pre-prod, manual approve for prod. — Maps to auto-deploy range/test, confirm homelab/cloud.
- Workspace structure should mirror permissions model.

**What doesn't fit:** SaaS pricing for single operator. Pulumi CLI + local state more appropriate at our scale.

### A.3 AI Software Factory Discourse (2026)

The term is new and mostly vendor-driven. Key observations:

- **LaunchDarkly** ([blog](https://launchdarkly.com/software-factory/)): Most factory diagrams stop at deploy. Production side (release, observe, iterate) is underdeveloped. **Directly relevant** — we must build post-deploy verification.
- **ZenML** ([case study](https://zenml.io/llmops-database/building-autonomous-software-factories-with-ai-agents)): Factory using Claude + Codex. Notes agents need "dangerous levels of access." Safety gates are critical.
- **Encore** ([guide](https://encore.dev/articles/how-to-build-an-ai-software-factory)): Deploy step can still be CI/CD, now fed agent-validated changes.
- **Augment Code** ([definition](https://www.augmentcode.com/guides/what-is-a-software-factory)): Specs and merge approvals under human control, everything else automated.
- **Mastra** ([blog](https://mastra.ai/blog/software-factory)): Building factories with AI agents in TypeScript.

**Our differentiator:** Single-operator fleet model with mode-based security walls, not team-scale platform engineering. No existing factory addresses mode-based isolation.

### A.4 Additional MCP Deploy Servers

| Server | Targets | Maturity | Notes | Link |
|---|---|---|---|---|
| **InfraOps MCP** | 7 providers (Coolify, Hetzner, Cloudflare, etc.) | Community, 195 tools | Multi-provider, runs locally over stdio. Hetzner coverage interesting for our cloud VPS target. | [Glama](https://glama.ai/mcp/servers/AlobarQuest/infraops-mcp-server) |
| **GARZA OS / Last Rock** | Fly.io + generic | Community | State tracking, distributed locking, auto-rollback. Good safety patterns worth studying. | [Glama](https://glama.ai/mcp/servers/@itsablabla/lastrock-mcp) |
| **Dokploy MCP** | Dokploy PaaS | Community | Status, logs, metrics, project management | [Glama](https://glama.ai/mcp/servers/firebaseStudio/dokploy-mcp) |
| **Porter PaaS MCP** | Your own cloud (Porter PaaS) | Production | Browser-based OAuth — no headless/CI use. NOT the CNAB Porter. | [docs.porter.run](https://docs.porter.run/mcp/overview) |

### A.5 Additional ArgoCD MCP Variants

| Server | Notes | Link |
|---|---|---|
| **Akuity argocd-mcp** | Apache-2.0, session-based tokens (keeps API token out of prompts/logs) | [mcpservers.org](https://mcpservers.org/servers/akuity/argocd-mcp) |
| **talkops-argocd-mcp-server** | FastMCP, Docker, write-gated via `MCP_ALLOW_WRITE` | [PyPI](https://pypi.org/project/talkops-argocd-mcp-server/) |
| **argocd-mcp-server** (asklokesh) | Progressive delivery focus (canary, blue-green), multi-cluster config | [PyPI](https://pypi.org/project/argocd-mcp-server) |

### A.6 Additional Community Harness Projects

| Project | What | Fit |
|---|---|---|
| **stellarlinkco/myclaude** | Multi-agent orchestration across Claude Code, Codex, Gemini, OpenCode | Pattern reference. We already have mode-based orchestration. |
| **wshobson/agents** | Automation + multi-agent orchestration for Claude Code (MIT) | Worth scanning for dispatch patterns. |
| **gabrielkoerich/orchestrator** | Lightweight bash orchestrator for autonomous coding agents | Bash-first orchestration precedent (like our `board.sh`). |
| **Chachamaru127/claude-code-harness** | Harness with deploy + monitoring skills; installable via `npx skills add` | Deploy skill at `codex/.codex/skills/deploy` worth reading. Active, Japanese community. |

### A.7 CLAUDE.md Deploy Patterns in the Wild

| Pattern | Source | Description |
|---|---|---|
| **Separate deploy doc** | [PRQL PR #5553](https://github.com/PRQL/prql/pull/5553) | Keep detailed deploy procedures out of CLAUDE.md; point to `development.md`. Keeps context window clean. |
| **Per-environment settings** | [claudekit](https://duthaho.github.io/claudekit/commands/deploy) | CLAUDE.md lists staging + production, with `Auto-deploy: No` for production. |
| **Hook vs rule** | [r/claude.md](https://github.com/r/claude.md) | CLAUDE.md rule is advisory; hook is enforced. Deploy guardrails should be hooks. We already follow this. |
| **Config-driven deploy** | [centminmod/my-claude-code-setup](https://github.com/centminmod/my-claude-code-setup) | CLAUDE.md templates with memory-bank file system. |

### A.8 Kubernetes MCP Servers (for future K8s targets)

| Server | Status | Link |
|---|---|---|
| **kubectl-mcp-server** | 270+ tools, deploy prompts, multi-context | [PyPI](https://pypi.org/project/kubectl-mcp-server/) |
| **kubernetes-mcp-server** (manusa) | 1,642 stars, Apache-2.0, K8s + OpenShift | [Glama](https://glama.ai/mcp/best/kubernetes) |

Relevant only if we add K8s targets to fleet. Not immediate priority.

---

*Research method: Web search (2026-11-21, two passes). Links not all verified for
current availability. Star counts and commit dates should be confirmed before
adoption decisions.*
