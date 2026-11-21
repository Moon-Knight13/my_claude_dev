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

### 1.7 Sandcastle (mattpocock/sandcastle)

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
- **Maturity:** Production. Well-funded startup. Large community.
- **Fit for us:** Best IaC option for our TypeScript-heavy stack. MCP server
  would let HQ call Pulumi directly. Stack-per-target maps cleanly to our
  deploy target abstraction.
- **Link:** https://www.pulumi.com/topics/agentic-infrastructure/mcp-for-infrastructure-as-code/

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
  targets (GKE fleet clusters).
- **Maturity:** GA. GCP only.
- **Fit for us:** Multi-target parallel deploy is exactly our pattern. GCP-only
  limits adoption. Pattern is portable.
- **Link:** https://docs.cloud.google.com/deploy/docs/parallel

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

1. **MCP deploy servers** (Railway, ArgoCD, Flux) as target adapters
2. **Agent orchestrators** (VocanicZ/Harness, daopapp/software-factory) for
   dispatch patterns
3. **IaC tools** (Pulumi with MCP) for infra provisioning

Our value-add is the **glue layer**: mode-aware dispatch, secret
compartmentalization, context-safety, and the adapter abstraction that makes
"deploy to range" and "deploy to cloud" feel identical to the operator.

---

*Research method: Web search (2026-11-21). Links not all verified for current
availability. Star counts and commit dates should be confirmed before adoption
decisions.*
