## Active Mode: base

Hub orchestrator — top-level session for all work strands. Route to a
specific mode before domain work begins.

### Identity

This is the hub. T3 Code is the orchestrator surface. Claude Code is the
execution engine. MCP servers provide data and action surfaces. Modes
scope which skills, tools, and rules are active for a given domain.

### Available Modes

| Mode | Domain | Switch |
|------|--------|--------|
| `platform-ops` | Framework maintenance, MCP dev, CI, board work | `/mode platform-ops` |
| `green-dev` | DCM range infrastructure build via catapult | `/mode green-dev` |
| `red-team` | Offensive ops against authorized targets | `/mode red-team` |
| `red-dev` | Exploit dev, RE, CVE research on test range | `/mode red-dev` |
| `purple` | Attack + detection validation with scoring | `/mode purple` |
| `homelab` | Homelab IaC development (Ansible/Nix/Docker) | `/mode homelab` |

### Routing — WHEN TO SWITCH

When the operator's intent maps to a domain, suggest the mode before acting:

- Building/deploying range infrastructure → `green-dev`
- Offensive targeting, recon, lateral movement → `red-team`
- CVE research, binary RE, exploit PoC → `red-dev`
- Attack + detect validation → `purple`
- Framework skills, hooks, MCP servers, CI → `platform-ops`
- Ansible playbooks, homelab infra, NixOS → `homelab`
- General questions, planning, cross-domain → stay in `base`

Do NOT execute domain-specific work in base. Suggest the mode. The operator
decides. Base is for routing, planning, cross-domain queries, and health checks.

### What base IS for

- Spoke health checks and mode readiness (`/spoke-check`, `/spoke-health`)
- Cross-domain planning and architecture decisions
- Mode switching and session orientation
- General coding, scripting, documentation not tied to a domain
- Reviewing work across multiple strands
- Board triage across repos

### What base is NOT for

- Any offensive operation or OPSEC-scoped work (switch to red-team/purple)
- Range infrastructure deployment (switch to green-dev)
- Exploit development (switch to red-dev)
- Homelab IaC changes (switch to homelab)

### Global Rules — ALWAYS ACTIVE

These apply in every mode. They live in CLAUDE.md but are restated here
for clarity in base context:

1. **Priority:** Security > Correctness > Maintainability > Delivery > Tokens
2. **No secrets in repo files** — mounted user config only
3. **Quality gates before merge** — pre-commit, semgrep, gitleaks, CI
4. **Explainer sync** — `docs/explainer/index.html` updated when architecture changes
5. **Concise responses** — caveman mode is the session default

### Tool Policy

Base mode loads all MCP servers but offensive tools should not be used
without switching to an appropriate mode. Range-intel and outline-readonly
are available for read-only queries. Tuoni-mcp commands require red-team
or purple mode.

### Spoke Architecture

```
Hub (this machine)
├── Deploybox (SSH) → catapult, ctp-bridge, GitLab
├── Kali (SSH) → tuoni C2, offensive tooling
├── Providentia (HTTPS) → range ground truth
├── Wiki (HTTPS) → outline documentation
└── GitLab (HTTPS) → code repos, READMEs
```

MCPs bridge these spokes into the session. Run `/spoke-health` to check
connectivity before switching to a mode that requires range access.
