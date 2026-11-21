# Deployment Target Inventory

Survey of all deployment patterns across Moon-Knight13 repositories.
Conducted 2026-11-21 from local files and `gh api` reads.

## Inventory

| Target class | Repo / component | Deploy mechanism | Maturity | Common patterns |
|---|---|---|---|---|
| **Range VM (catapult)** | my_claude_dev / ctp-bridge | Ansible via catapult container, gated by `ctp-bridge.sh` wrapper. 12-step deploy tree (variable load → VM create → networking → SSH → role → finalize). Two verbs: `host deploy` (full) and `host deploy-role` (role-only iteration). | Production — daily use, safety-gated, operator-confirmed | Pre-flight gateway check, Providentia inventory query, human confirmation gate, flock-based concurrency lock, liveness check before redeploy, remote docker exec via SSH |
| **Range inventory refresh** | my_claude_dev / ctp-bridge | `project update-inventory` regenerates ctp inventory from Providentia. Dynamic inventory plugin means exit code 1 is expected (not a failure). | Production | Providentia-driven, verify with `host list` |
| **Kali spoke bootstrap** | my_claude_dev / kali-bootstrap skill | SSH + Tuoni API + SCP. 8-step procedure: firewall → SSH auth → Tuoni docker-compose → self-agent deploy → plugin deploy → tool verification → state record. | Production — full engagement pre-flight | ipset firewall check, SSH key auth, docker-compose health, Tuoni payload generation, SCP binary transfer, 40+ tool verification matrix |
| **Tuoni plugins** | tuoni-plugins + my_claude_dev / deploy-tuoni-plugins.sh | Git clone → `build_scripts.py` (inlines shared code) → SCP to Kali `/srv/tuoni/data/scripts/` → restart tuoni-server → verify 16 modules. Offline fallback: restore from Kali backup. | Production — 16 DynamicAlias modules | Build-time code inlining (GraalPy sandbox workaround), SCP deploy, docker-compose restart, module count verification |
| **Persistence (agent deploy)** | my_claude_dev / persist-swarm skill | Tuoni C2 payload create → download → execute on target. Two-round: low-priv on landing, high-priv after escalation. Operational + sleeper beacons per target. | Production — mandatory in red-team ops | Dual-beacon pattern, two-round lifecycle, Obsidian state tracking |
| **Lateral movement** | my_claude_dev / lateral-move skill | Tuoni native jump commands (SSH/WMI/WinRM/service) with persist-on-landing enforcement. SOCKS proxy from footholds for Kali tool routing. | Production | Credential-based, scope-checked, persist-before-proceed |
| **Azure cloud (IaC)** | azure-dev-harness | Bicep modules + `azd up`. 7-phase bootstrap validator. VNet with private endpoints, managed identity, zero passwords. State tracked in `.state/environment.json`. | Mature — full IaC pipeline | Bicep modules (VNet/ACR/Key Vault/SQL/App Service), `azd` CLI, 7-phase validation, private endpoint DNS, cost estimation ($160–$1882/mo tiers), state persistence |
| **Azure CI/CD** | azure-dev-harness / .github/workflows | 7 workflows: ci, container-scan, pages, repository-audit, secret-scan, semgrep, template-sync | Production | Standard template CI gates |
| **Homelab platform (IaC)** | homelab_infra | Ansible roles + playbooks. Proxmox virtualisation, pfSense policy-as-code firewall, CIS Level 2 hardening. Overlay-nested or template-fork adoption. Private overlay for secrets/inventory. | Architecture complete, build sequenced — greenfield | Ansible roles, PXE bare-metal provisioning, policy-as-code firewall, CIS benchmarks, evidence-based compliance, 4-hour rebuild guarantee |
| **Homelab CI** | homelab_infra / .github/workflows | 7 workflows: ci, container-scan, pages, repository-audit, secret-scan, semgrep, template-sync | Production | Same template CI gates as azure-dev-harness |
| **FoundryVTT server** | foundryvtt-docker | Docker Compose (`compose.yml`) with felddy/foundryvtt image. Optional Cloudflare Tunnel overlay (`compose.cloudflare.yml`). Content pipeline: `compile-game.mjs` → `build.mjs` → `ship-game.sh` (compile → gate → build → sync → restart). | Production — daily use | Docker Compose, bind-mount data, Cloudflare Tunnel (zero inbound ports), content-as-code pipeline, golden base provisioning (`foundry-base.json`), art-coverage gate |
| **FoundryVTT CI** | foundryvtt-docker / .github/workflows | 10 workflows: ci, codeql, container-scan, content-tests, dependency-review, pages, pin-freshness, repository-audit, secret-scan, semgrep | Production — most comprehensive CI | Content-tests and pin-freshness unique to this repo |
| **Foundry content module** | foundry-gm-claude-plugin | Claude Code plugin. `scripts/content/` scaffolded into project. JSON → compendium module with deterministic IDs. `@UUID` cross-links validated at build. | Production | Content-as-code, deterministic ID generation (sha256), host-side sync, routing guard hook |
| **MediCat USB stick** | medicat-usb | `make-stick.sh`: fetch → verify checksums → f3probe capacity test → Ventoy write → extract MediCat tree → copy ISOs. Offline recipe — nothing bootable in repo. | Production — single script | Checksum verification per source, counterfeit-stick detection, MBR/GPT partition styles, aria2 download, idempotent update |
| **Self-hosted AI stack** | Ai_Suite (fork of coleam00) | Docker Compose: Ollama + Open WebUI + n8n + Supabase + Qdrant + Neo4j + SearXNG + Caddy + Flowise + Langfuse | Fork — operational | Multi-service compose, managed TLS via Caddy, .env configuration |
| **Offensive automations** | weaponised_ansible | Ansible playbooks + Python scripts. `run.sh` generates engagement profile from parameters. Enclave-based targeting with firewall discovery. | Operational | Ansible playbooks, dynamic inventory generation, enclave templates, roster management |
| **Template CI scaffold** | claude_template_repo | GitHub template. 6 workflows: ci, secret-scan, semgrep, container-scan, pages, template-sync. Devcontainer with deny-by-default firewall. | Production — template for all repos | Gitleaks, semgrep (MITRE ATLAS), Trivy, pre-commit hooks, branch protection bootstrap |
| **Tuoni MCP server** | tuoni-mcp | Node.js MCP server. No deploy mechanism beyond npm install. | Production — running in devcontainer | MCP protocol, .env-based config, JWT auth flow |
| **Hub devcontainer** | my_claude_dev / .devcontainer | Dockerfile + devcontainer.json + init-firewall.sh. Deny-by-default egress. 13 MCP servers wired per mode. | Production | iptables firewall, mode-based MCP loading, SSH proxy chain, .env-driven spoke config |
| **Remote dev box provisioning** | my_claude_dev / scripts/host/ | `provision-remote-box.sh` brings shared workstations to known state. Versioned (`PROVISION_VERSION`). | Production | sudo scoping, `run_as_target` for user-level ops, failure tracking, idempotent re-run |
| **Model failover (planned)** | my_claude_dev (design only) | Claude MAX → RunPod vLLM → homelab vLLM → local Ollama. RunPod integration referenced in HQ restructure design. | Design — not yet deployed | Multi-tier failover chain, RunPod serverless planned |

## Common Stages Across Targets

| Stage | Range VM | Azure IaC | Homelab | Docker Compose | USB Build | Agent Deploy |
|---|---|---|---|---|---|---|
| **Pre-flight / validate** | Gateway ping, Providentia query | 7-phase bootstrap | Day-0 check | — | Checksum verify | Scope check, cred verify |
| **Provision infra** | VM create (vSphere) | `azd provision` (Bicep) | PXE boot + Ansible | `docker compose up` | Ventoy write | Listener create |
| **Configure networking** | catapult step 4 | Private endpoints + DNS zones | pfSense policy-as-code | Cloudflare Tunnel (optional) | — | SOCKS proxy |
| **Deploy application** | Ansible role (step 9) | `azd deploy` | Ansible roles | Image pull + bind mounts | Extract + copy | Payload generate + execute |
| **Verify** | Re-query Providentia, SSH test | Health endpoint, state update | CIS scan, service checks | Health check | f3probe, boot test | Agent callback, beacon confirm |
| **State record** | — | `.state/environment.json` | Compliance evidence | — | — | Obsidian target page, engagement YAML |

## Target-Specific Stages

| Target | Unique stage | Purpose |
|---|---|---|
| Range VM | Human confirmation gate | Safety — operator approves every deploy |
| Range VM | Concurrency lock (flock) | Prevent parallel deploys to same box |
| Range VM | Liveness probe before redeploy | Refuse redeploy of live host without override |
| Azure | Cost estimation | SKU pricing validation before provision |
| Azure | Private endpoint DNS verification | Ensure PE resolves before app deploy |
| Homelab | CIS Level 2 hardening gate | Compliance enforcement at merge time |
| Homelab | Air-gap promotion bundle | Offline-capable artifact packaging |
| FoundryVTT | Content-as-code pipeline | JSON → compendium with art-coverage gate |
| FoundryVTT | Pin-freshness workflow | Detect upstream module version drift |
| Kali bootstrap | 40+ tool verification matrix | Ensure engagement toolchain complete |
| Persist-swarm | Two-round lifecycle | Low-priv insurance, then high-priv durable |
| MediCat USB | Counterfeit-stick detection | f3probe rejects fake-capacity drives |

## Reusable Abstractions vs Target-Specific

### Reusable (already shared or easily extracted)

| Pattern | Currently in | Used by |
|---|---|---|
| Devcontainer + deny-by-default firewall | claude_template_repo | my_claude_dev, azure-dev-harness, homelab_infra |
| CI gate suite (gitleaks, semgrep, Trivy, secret-scan) | claude_template_repo | All 5 active repos + template |
| Day-0 validation (`check-day0.sh`) | claude_template_repo | All derived repos |
| Board/Kanban orchestration (`board.sh`) | claude_template_repo | All derived repos |
| Spoke health check | my_claude_dev skill | Could generalize to any hub-spoke topology |
| Gateway pre-flight | my_claude_dev (`gateway-preflight.sh`) | ctp-deploy skill, spoke-health skill |
| State tracking pattern | azure-dev-harness (`.state/`), my_claude_dev (engagement YAML + Obsidian) | Could unify into standard state file |

### Inherently target-specific

| Pattern | Why not reusable |
|---|---|
| ctp-bridge gate stack | Tied to catapult container, Providentia inventory plugin, Ansible vault |
| Bicep modules | Azure-specific IaC |
| pfSense policy-as-code | Hardware firewall specific |
| Tuoni C2 agent lifecycle | C2 platform specific |
| Content-as-code pipeline | FoundryVTT-specific schema and tooling |
| MediCat build recipe | Hardware USB-specific, vendor-specific checksums |
| Docker Compose overlays | Service-specific container orchestration |

## Gaps: Deploy Targets with No Agent Support

| Gap | Current state | Impact |
|---|---|---|
| **RunPod serverless** | Referenced in HQ restructure design spec; RunPod MCP plugin available but unauthenticated this session. No deploy skill or automation exists. | Model failover chain incomplete — no automated GPU provisioning |
| **Homelab service onboarding** | Architecture documented, roles planned, but no skill or automation for deploying a new service to Proxmox/Docker on homelab. Build not started. | Manual process for each new homelab service |
| **Homelab CIS hardening** | Documented as requirement. No automated scan-and-remediate pipeline built yet. | Compliance verification is manual |
| **Ai_Suite stack management** | Fork with no Claude skills, no health checks, no state tracking. Docker Compose only. | No agent visibility into local AI stack health |
| **weaponised_ansible** | Ansible playbooks exist but no Claude skill wrapping them. No safety gates comparable to ctp-bridge. | Offensive automation without agent-level guardrails |
| **Cloudflare Tunnel lifecycle** | FoundryVTT uses it but setup is manual. No skill to provision/rotate tunnels. | Manual tunnel management |
| **Template sync propagation** | template-sync workflow exists but sync verification after propagation is manual. | Drift between template and derived repos undetected until CI fails |
| **Docker image build/push** | No repos build custom Docker images. All use published images. If custom images needed (homelab services, RunPod workers), no pipeline exists. | Would need image registry + build pipeline for custom workloads |
| **Backup/restore automation** | Homelab promises 4-hour rebuild but no automated backup verification. FoundryVTT has golden-base rebuild but no scheduled backup. | Recovery depends on manual drill discipline |
