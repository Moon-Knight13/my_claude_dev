## Active Mode: homelab

Homelab infrastructure development and management. Production home network —
partner depends on connectivity. Non-destructive default, dry-run-first.

### Priority

1. **Don't break the network.** Partner and household depend on it.
2. Security — no credential leaks, no exposed services.
3. Correctness — config matches intent, idempotent deploys.
4. Maintainability — reproducible, documented, version-controlled.
5. Delivery speed.

### What this mode is for

- Docker Compose service definitions, deployment, and lifecycle management
- UniFi network configuration and monitoring (read-only default)
- Ansible playbook/role development for homelab infrastructure
- NixOS configuration and flake management
- Service onboarding (FoundryVTT, Jellyfin, monitoring, etc.)
- Network configuration, DNS, and VLAN management
- Backup strategy and monitoring setup
- Defensive vulnerability scanning and patch prioritization
- Hardware provisioning and Medicat USB workflows

### What this mode is NOT for

- Any offensive operation (use red-team)
- Exploit development or RE (use red-dev)
- Range infrastructure deployment (use green-dev)
- Framework/harness development (use platform-ops)
- Attack + detection testing (use purple)

### Safety posture — ENFORCED

#### Non-destructive default
All infrastructure changes must be previewed before applying:
- Docker: `docker compose config` to validate, then `docker compose up --dry-run` before real deploy
- Ansible: `--check --diff` before real run
- UniFi: read operations by default; write operations require explicit operator approval
- Network changes: announce impact scope before executing

#### UDR7 write caution
UniFi controller lives on UDR7. Write operations (firewall rules, VLAN changes,
port profiles, WiFi config) affect the entire home network. Read-only by default.
Write operations require the operator to explicitly confirm after reviewing the
proposed change.

#### AD-13: Leak prevention
Device names, hostnames, model strings, and identity handles from private
inventory MUST NOT appear in public repositories (homelab_infra). The
`homelab-leak-guard.sh` hook enforces this at the tool level. When writing to
public repos, use generic references (e.g., "primary router" not the device
hostname).

### Context isolation — ENFORCED

This mode has NO access to range/engagement data:
- tuoni-mcp: **BLOCKED** (C2 framework — offensive only)
- range-intel: **BLOCKED** (range recon — not relevant)
- rea-mcp: **BLOCKED** (reverse engineering — not relevant)
- outline: **BLOCKED** (range wiki — context isolation)

No range IPs, target data, engagement state, or offensive tooling output
should appear in homelab context. No homelab credentials should flow to range
threads.

### Available MCPs

- **docker-mcp** — Docker container/compose lifecycle management
- **unifi-mcp** — UniFi controller queries and (with approval) configuration
- **cve-mcp** — CVE lookup for patch prioritization and EOL assessment
- **nuclei-mcp** — Template-based vulnerability scanning of homelab services
- **mitre-mcp** — Threat modeling for network/access design decisions
- **hacktricks-mcp** — Defensive awareness for CIS hardening
- **lolbins-mcp** — Host hardening awareness
- **obsidian-mcp** — Homelab knowledge base in LLM Wiki
- All standard development tools (git, bash, ssh)

### Two-repo model

| Repo | Purpose | Visibility |
|------|---------|------------|
| `homelab_planning` | Planning artifacts, specs, inventory, sprint status | **Private** |
| `homelab_infra` | IaC code, Ansible roles, Docker configs, docs | **Public** |

AD-13 applies at the boundary: private data must not cross into the public repo.

### Knowledge base

Homelab knowledge lives in `homelab_planning` repo (not a separate Obsidian
vault). The repo contains 70+ pages of planning specs, inventory, and decision
records. Use `obsidian-mcp` for the LLM Wiki knowledge base pattern when
cross-referencing techniques, decisions, and deployment records.

### Readiness check

On session start:
1. Verify Docker daemon reachable (`docker info`)
2. Check obsidian-mcp for documentation access
3. If targeting a network device, confirm UniFi controller reachable
4. If targeting a specific host, confirm SSH reachability before changes

### Projects

Primary workspace: homelab_planning (Moon-Knight13/homelab_planning)
Public IaC: homelab_infra (Moon-Knight13/homelab_infra)
Related: foundryvtt-docker, medicat-usb
