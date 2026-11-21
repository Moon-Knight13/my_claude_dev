# Cloud/VPS Deployment Tooling Landscape

> Research survey — 2026-11-21
> Scope: MCP servers, CLIs, and integration patterns for cloud/VPS deploy support

## 1. Provider MCP Server Availability

### Tier 1: Official/Production MCP Servers

| Provider | MCP Server | Status | Auth | Key Capabilities |
|----------|-----------|--------|------|-----------------|
| **Azure** | `microsoft/mcp` (official, replaces archived `Azure/azure-mcp`) | GA (4.0.0-beta.9+), 200+ tools across 40+ services | DefaultAzureCredential, sovereign cloud support | Full resource management, deployments, monitoring. Also: `microsoft/azure-devops-mcp` for DevOps, `microsoft/azure-skills` plugin bundle |
| **AWS** | AWS Managed MCP Server (GA since May 2026) + `awslabs/mcp` (self-hosted OSS) | Production — no additional charge for managed server | IAM/SSO standard SDK chain | Managed server covers ~15K APIs. Self-hosted repo has service-scoped sub-servers: CDK, CloudFormation, Lambda, S3, Cost Explorer, Kendra, pricing, docs |
| **Vercel** | Official at `mcp.vercel.com` (source: `vercel/vercel-mcp-overview`) | Production, 2026-07-28 MCP spec | OAuth via Vercel | Project/deployment management, domain config. Also: `mcp-handler` for hosting your own MCP on Vercel |
| **DigitalOcean** | `digitalocean-labs/mcp-digitalocean` (official, npm `@digitalocean/mcp`) | Production (v1.0.67+), Go-based | `DIGITALOCEAN_API_TOKEN` env var | Apps, Databases, DOKS, Droplets, Networking, Spaces. Remote endpoints at `mcp.digitalocean.com` |

### Tier 2: Built-in/Community MCP Servers

| Provider | MCP Server | Status | Notes |
|----------|-----------|--------|-------|
| **Fly.io** | Built-in: `fly mcp server` command in flyctl (`superfly/flyctl`) | Experimental (labeled as such) | Apps, certs, logs, machines, orgs, secrets, volumes. Supports stdio/SSE/Streamable HTTP |
| **Hetzner Cloud** | Community: `devinoldenburg/hetzner-mcp` (Python/PyPI), `lazyants/hetzner-mcp-server` (Node/npm, 185 tools), `wbf-solutions/hetzner-cloud-mcp` (PHP) | Experimental, no official server | Servers, networking, LBs, firewalls, volumes, DNS, storage boxes |
| **Railway** | Community: `jason-tan-swe/railway-mcp` (npm `railway-mcp`), `@crazyrabbitltc/railway-mcp` | Community only — Railway focuses on hosting other MCPs, not managing itself | Deploy services, manage variables, monitor deployments |

### Tier 3: Generic/Multi-Provider

| Server | Coverage | Notes |
|--------|----------|-------|
| **Terraform MCP** | Community projects wrapping `terraform` CLI | Covers any provider Terraform supports; indirect but universal |
| **Docker MCP** | Container lifecycle | Build/push/run — not cloud-specific but foundational |
| **Kubernetes MCP** | Cluster management | For providers that offer managed K8s (AKS, EKS, GKE, DOKS) |

## 2. CLI Tool Availability

### Local Environment (this machine)

| CLI | Installed | Purpose |
|-----|-----------|---------|
| `docker` | Yes | Container build/push — foundational for all providers |
| `terraform` | Yes | Multi-provider IaC — covers all targets |
| `az` | No | Azure CLI |
| `aws` | No | AWS CLI |
| `hcloud` | No | Hetzner Cloud CLI |
| `vercel` | No | Vercel CLI |
| `flyctl` | No | Fly.io CLI |
| `doctl` | No | DigitalOcean CLI |
| `railway` | No | Railway CLI |
| `kubectl` | No | Kubernetes (managed K8s on any provider) |
| `helm` | No | K8s package manager |
| `pulumi` | No | IaC alternative to Terraform |

### CLI Install Complexity

| CLI | Install method | Auth model | Complexity |
|-----|---------------|------------|------------|
| `az` | `curl -sL https://aka.ms/InstallAzureCLIDeb \| bash` | `az login` (browser/device code/SP) | Medium — large package, AAD auth |
| `aws` | `apt install awscli` or pip | `aws configure` (access key/secret) | Low |
| `hcloud` | Single binary download | API token in env | Low |
| `vercel` | `npm i -g vercel` | `vercel login` (browser) | Low |
| `flyctl` | `curl -L https://fly.io/install.sh \| sh` | `flyctl auth login` (browser) | Low |
| `doctl` | `snap install doctl` or binary | API token | Low |
| `railway` | `npm i -g @railway/cli` | `railway login` (browser) | Low |

## 3. RunPod Integration Pattern (Reference Architecture)

RunPod is the only cloud provider currently integrated as a T3 plugin. Its
architecture is the template for other providers.

### Structure

```
~/.claude/plugins/marketplaces/runpod/
├── plugins/runpod/            # Plugin manifest
└── skills/
    ├── runpod/SKILL.md        # Router — intent → journey skill
    ├── runpod-mcp/SKILL.md    # MCP bridge — auth, tools, answer contract
    ├── runpod-serverless-deploy/  # Journey: deploy serverless endpoint
    ├── runpod-pod-deploy/         # Journey: provision interactive pod
    ├── runpod-pod-doctor/         # Journey: diagnose broken pod
    ├── runpod-endpoint-ops/       # Journey: manage existing endpoint
    ├── runpod-cost-audit/         # Journey: billing analysis
    ├── runpod-build-template/     # Journey: Dockerfile/template authoring
    ├── runpod-discovery/          # Journey: catalog/stock queries
    ├── runpod-lifecycle-crud/     # Journey: template/volume/secret CRUD
    ├── runpod-vllm/               # Journey: vLLM-specific deploy
    ├── runpod-flash/              # Journey: Python SDK dev loop
    ├── runpod-templates/          # Journey: official template lookup
    ├── runpod-usage/              # Journey: conceptual docs
    ├── runpod-companion-clis/     # Journey: prerequisite tools (hf, docker, gh)
    ├── runpod-migrate/            # Journey: API version migration
    ├── runpod-cloud-migrate/      # Journey: other-cloud → RunPod migration
    ├── runpodctl/                 # CLI fallback when MCP unavailable
    └── */reference/*.md           # Deep guides per journey
```

### Key Patterns (Reusable)

| Pattern | Description | Reuse potential |
|---------|-------------|----------------|
| **Router skill** | Single entrypoint routes intent to correct journey skill | Direct — every provider needs this |
| **MCP-first, CLI-fallback** | Use structured MCP tools when connected; shell to CLI when not | Direct — universal |
| **Answer contract** | Consistent response format: what exists, what it costs, how to reach it | Direct — standardize across providers |
| **Read-before-write** | Query catalog/state before provisioning; state cost before creating | Direct — safety pattern |
| **Verify-with-real-traffic** | Smoke test with actual request after deploy | Direct — health check pattern |
| **Journey decomposition** | One skill per workflow (deploy, diagnose, audit, migrate) | Direct — decompose per provider |
| **Golden paths** | Worked examples for common end-to-end flows | Direct — reduces token cost |
| **Tool binding tables** | Map capabilities to specific MCP tool names per journey | Direct — avoids tool hallucination |

### Deploy Flow (Generalized from RunPod serverless-deploy)

```
1. Classify source    → detect app type, pick deploy method
2. Size hardware      → read catalog, check availability, estimate cost
3. Provision          → create resources (image → compute → network)
4. Configure          → env vars, secrets, domains, scaling
5. Warm/initialize    → wait for readiness
6. Verify             → real traffic health check
7. Report             → hand back URL, cost summary, what's billing
```

## 4. Generic Deploy Skill Design

### Architecture: Provider-Agnostic Skill Layer

```
.claude/skills/
├── cloud-deploy/SKILL.md           # Router — like runpod/SKILL.md
├── cloud-deploy-azure/SKILL.md     # Journey: Azure deploy
├── cloud-deploy-aws/SKILL.md       # Journey: AWS deploy
├── cloud-deploy-hetzner/SKILL.md   # Journey: Hetzner deploy
├── cloud-deploy-vercel/SKILL.md    # Journey: Vercel deploy
├── cloud-deploy-flyio/SKILL.md     # Journey: Fly.io deploy
├── cloud-deploy-doctor/SKILL.md    # Journey: diagnose any provider
├── cloud-deploy-cost/SKILL.md      # Journey: cost audit any provider
└── cloud-deploy-migrate/SKILL.md   # Journey: cross-provider migration
```

### Common Layer (Provider-Agnostic)

Every deploy journey needs:

1. **Auth gate** — verify credentials exist and work before provisioning
2. **Resource catalog** — query available compute/regions/pricing
3. **Build stage** — `docker build` + push to provider registry (or provider-native build)
4. **Provision** — create compute (VM/container/serverless function)
5. **Network** — assign domain/IP, configure DNS, TLS
6. **Deploy** — push image/code to provisioned compute
7. **Verify** — health check with real request
8. **Report** — URL, cost, resource IDs for lifecycle management

### Provider-Specific Concerns

| Concern | Azure | AWS | Hetzner | Vercel | Fly.io |
|---------|-------|-----|---------|--------|--------|
| **Auth** | Azure AD / SP / managed identity | IAM keys / SSO / roles | API token | Vercel token | OAuth / API token |
| **Compute types** | App Service, Container Apps, ACI, VMs, Functions | ECS, Lambda, EC2, App Runner, Lightsail | Cloud servers (VMs only) | Serverless functions, Edge | Fly Machines (microVMs) |
| **Registry** | ACR | ECR | Docker Hub / GHCR | Built-in (from git) | Built-in Fly registry |
| **DNS** | Azure DNS | Route53 | Hetzner DNS | Vercel Domains | Fly DNS / Anycast |
| **IaC** | ARM/Bicep/Terraform | CloudFormation/CDK/Terraform | Terraform only | Vercel CLI / git-push | fly.toml + flyctl |
| **Cost model** | Per-resource-hour + consumption | Per-resource-second + requests | Per-hour flat (VMs) | Per-request + bandwidth | Per-machine-second |
| **Complexity** | High (AAD, networking, resource groups) | High (IAM, VPCs, security groups) | Low (flat API, simple networking) | Low (git push, zero-config) | Medium (fly.toml, Machines API) |

### Credential Management

Provider credentials must never be stored in repo files (CLAUDE.md guardrail).
Options:

- **Environment variables** — set in `.env` or profile, loaded by `load-env.sh`
- **CLI auth sessions** — `az login`, `aws configure`, etc. persist in `~/.azure/`, `~/.aws/`
- **MCP server auth** — handled by MCP connection config (OAuth, API key injection)
- **T3 secrets** — `request_secret` for runtime credential prompt

Pattern: skill checks for auth at start, fails fast with clear message if missing.

## 5. Recommendations

### Priority Ranking

Based on operator mentions (Azure, RHEL, AWS, Hetzner, Vercel), existing
tooling maturity, and harness fit:

#### Tier 1: Build First (highest value)

1. **Azure** — mentioned alongside RHEL, operator's enterprise context. Official
   MCP server (`microsoft/mcp`) is GA with 200+ tools across 40+ services.
   `az` CLI well-documented. Terraform modules mature.
   - Integration: MCP server (`microsoft/mcp`) + `az` CLI fallback
   - Deploy targets: Container Apps (serverless containers), App Service (web apps), ACI (one-shot containers)
   - Effort: Medium — official MCP does heavy lifting, but service breadth requires journey scoping

2. **Hetzner Cloud** — mentioned specifically, operator interest. Simplest API
   of all providers. `hcloud` CLI is single binary. Three community MCP servers
   exist: `lazyants/hetzner-mcp-server` (Node, 185 tools) is most complete.
   Alternative: build custom with `mcp-server-dev` plugin, or wrap CLI.
   - Integration: Community MCP (`hetzner-mcp-server`, 185 tools) or `hcloud` CLI skill
   - Deploy targets: Cloud servers (VMs), volumes, networks, load balancers, DNS
   - Effort: Low-Medium — evaluate community MCP first, CLI fallback

#### Tier 2: Build Second

3. **AWS** — large ecosystem. Official MCP server exists (modular, AWS-maintained).
   Complexity is highest of all providers. Good for operator who already has AWS
   accounts.
   - Integration: MCP server (`awslabs/mcp`) + `aws` CLI fallback
   - Deploy targets: App Runner (simplest), ECS/Fargate, Lambda, EC2
   - Effort: Medium-High — breadth of services requires careful journey scoping

4. **Vercel** — mentioned specifically. Zero-config deploys for Next.js and
   static sites. Official MCP adapter exists. Lowest complexity.
   - Integration: MCP server + `vercel` CLI + git-push deploy
   - Deploy targets: Serverless functions, edge functions, static sites
   - Effort: Low — simple API, official tooling

#### Tier 3: Build Later

5. **DigitalOcean** — official production MCP (`digitalocean-labs/mcp-digitalocean`).
   Straightforward VM/container platform. App Platform for PaaS deploys.
   - Integration: Official MCP server + `doctl` CLI fallback
   - Effort: Low

6. **Fly.io** — good for containers that need persistent processes. Built-in
   `fly mcp server` command in flyctl (experimental). `fly.toml` config.
   - Integration: Built-in MCP (evaluate stability) + `flyctl` CLI fallback
   - Effort: Low-Medium

7. **Railway** — developer-friendly PaaS. No MCP server.
   - Integration: CLI skill wrapping `railway`
   - Effort: Low

### Implementation Approach

**Phase 1: Foundation** (required before any provider)
- Generic `cloud-deploy` router skill (modeled on `runpod/SKILL.md`)
- Credential management pattern (env vars + CLI auth + `request_secret`)
- Common deploy flow template (classify → size → provision → deploy → verify)
- Terraform as universal IaC fallback (already installed)

**Phase 2: First Providers** (Azure + Hetzner)
- Azure: install `azure/azure-mcp`, write journey skills for Container Apps + App Service
- Hetzner: build lightweight MCP server via `mcp-server-dev`, or CLI-only skill wrapping `hcloud`
- Both: golden path examples, verify-with-traffic pattern

**Phase 3: Expand** (AWS, Vercel, then others)
- AWS: install `awslabs/mcp`, scope to App Runner + ECS initially
- Vercel: install official adapter, git-push deploy journey

### Existing Infrastructure to Leverage

| Asset | How it helps |
|-------|-------------|
| `docker` (installed) | Build + push images for any provider |
| `terraform` (installed) | Universal IaC — works with all 7 providers |
| `mcp-tunnels` plugin | Connect MCP servers on private infra (Hetzner, homelab) |
| `mcp-server-dev` plugin | Build custom MCP servers for providers without one |
| RunPod plugin pattern | Proven router → journey → verify architecture to replicate |
| `ctp-deploy` skill pattern | Gated deploy with pre-flight checks — reuse safety pattern |
| `range-build` skill pattern | Query state → plan → deploy flow — reuse truth-hierarchy pattern |

### Key Decision Points

1. **MCP-first vs CLI-first?** RunPod pattern says MCP-first, CLI-fallback.
   Azure, AWS, Vercel, DigitalOcean all have official production MCPs: MCP-first.
   Fly.io has experimental built-in MCP: test viability, CLI-fallback.
   Hetzner has community MCPs only: evaluate `hetzner-mcp` (185 tools), CLI-fallback.
   Railway has community MCP only: CLI-first.

2. **Plugin vs repo-local skills?** RunPod is a T3 marketplace plugin. Repo-local
   skills (like `range-build`) live in `.claude/skills/`. Recommendation:
   repo-local first (faster iteration, no publish cycle), extract to plugin
   when stable.

3. **Terraform as universal layer?** Terraform supports all providers. Could
   skip provider-specific CLIs entirely and use `terraform apply` for
   everything. Tradeoff: more abstraction layers, Terraform state management
   overhead. Recommendation: use Terraform for complex multi-resource deploys,
   provider CLI/MCP for simple single-resource operations.

4. **Devcontainer CLI install?** Cloud CLIs not currently installed. Add to
   `.devcontainer/` for providers being actively supported. Keep lean — only
   install what's configured in active profile.
