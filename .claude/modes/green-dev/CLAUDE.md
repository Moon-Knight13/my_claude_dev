
## Active Mode: green-dev

Range infrastructure build and configuration. Deploy boxes via catapult spoke.

### What this mode is for
- Building and configuring exercise zone systems
- Providentia-driven infrastructure: IP allocation, network topology, host records
- GitLab README documentation for deploy targets
- Catapult container deployments via ctp-bridge spoke
- Range network configuration and validation

### What this mode is NOT for
- Offensive operations (use red-team)
- Exploit development (use red-dev)
- Framework self-maintenance (use platform-ops)

### Development Rules — ENFORCED

#### Segmentation
- **SEG-001:** R-Edge is interconnection point between Control and Exercise zones.
- **SEG-005:** Exercise Zone systems MUST NOT authenticate against CRP AD DCs.

#### Development General
- **DEV-002:** Providentia is single source of truth for networks, compute, IP allocation.
- **DEV-004:** Tech Lead approval before developing production system.
- **DEV-005:** Requirement documented as GitLab issue before development.
- **DEV-006:** Code and artefacts committed to GitLab branches and merged.

#### Networks
- **NET-001:** vCenter network segment changes through change management.

### Source Priority

1. **Providentia** via range-intel MCP — ground truth: OS, IPs, services, team, role
2. **GitLab READMEs** via range-intel MCP — deploy notes, config, known defaults
3. **Wiki repo-docs** via outline-readonly — broader context
4. **Wiki architecture docs** via outline-readonly — zone model, design decisions

### Deploy Workflow

1. **Query Providentia** — get target host record, network, IP allocation
2. **Read GitLab README** — understand current state, deploy notes
3. **Develop** — build/configure in catapult container
4. **Deploy via ctp-bridge** — use `/ctp-deploy` skill
5. **Validate** — compare deployed state against Providentia expected state
6. **Document** — update GitLab README with changes

### Available MCP Servers
- range-intel — Providentia + GitLab READMEs (ground truth)
- outline-readonly — wiki (repo-docs, architecture, doctrine)
- local-ollama — code assistance
