# Project instructions

Repository-specific context, per the pointer in `CLAUDE.md`. `CLAUDE.md` holds
the workflow contract; project rules belong here. The repository is detached
from its template (2026-10-16), so no sync overwrites either file.

## What this repository is

An AI-driven cyber operations operator framework, built on a hub-and-spoke
architecture. Three things live here, and confusing them wastes time:

1. **The hub** — the primary purpose. A devcontainer (`.devcontainer/`) that
   serves as the operating environment for Claude Code sessions. It wires up MCP
   servers, SSH proxy chains, safety gates, and mode-specific configuration so an
   operator can run base, platform-ops, green-dev, red-team, red-dev, purple,
   and homelab workflows from a single seat (7 modes). The hub reaches spokes through `.env`-configured
   connections, not hardcoded endpoints.
2. **Spoke integrations** — MCP servers and SSH tunnels that connect the hub to
   range infrastructure and security research tooling: Kali (Tuoni C2, Hashcat),
   deploy box (catapult/ctp-bridge), Providentia (CMDB), GitLab, Outline wiki,
   Obsidian vault, and standalone research MCPs (CVE, MITRE ATT&CK, HackTricks,
   LOLBins, Nuclei, BloodHound, REA). Each spoke is configured by hostname/token
   in `.env` and derived at startup by `scripts/lib/load-env.sh`.
3. **Provisioning for remote developer boxes** — a secondary capability. A laptop
   bootstrap (`scripts/local/`) wires up SSH and Remote-SSH; an on-box
   provisioner (`scripts/host/provision-remote-box.sh`) brings a shared box to a
   known good state. This is what other developers consume.

Because provisioning scripts in `scripts/` are shared between the devcontainer
and remote-box surfaces, a change to one affects both.

## Operating environment

The hub runs as a **devcontainer on the operator's laptop**, connecting to
spokes on a **restricted network** used for development and security-testing
work. The remote boxes are **shared, multi-user workstations** on that same
network.

- **Shared OS account** (on remote boxes). No per-developer boundary.
- **Sensitive working data.** Must not leave the box or reach this repository.
- **Restricted egress.** Network access is limited; `/firewall-allow` for changes.

### Hub-and-spoke topology

- **Hub:** this repo's devcontainer, running Claude Code with 13 MCP servers.
- **Kali spoke (primary):** Tuoni C2 agent is main channel. SSH is fallback.
- **Deploy box spoke:** catapult container, ctp-bridge gate.
- **Range services:** Providentia (CMDB), GitLab (code), Outline wiki (docs).
- **Obsidian vault:** engagement documentation, findings, timeline.

SSH reaches spokes through a proxy chain: container → host → deploybox/kali.

### Truth hierarchy

When sources conflict: **Providentia > deploy box > Kali state** (authoritative).
**GitLab > Outline wiki > Obsidian vault** (reference only). Never parse wiki
tables for config/allocations. Operator puts allocations in `.env`.

### Authorized scope

Confined to **one authorized range**, on boxes the organisation owns, for
**training and authorized security-testing**. The tool bridge is scoped to a
**single named box** in code. Nothing operational enters the repository.

## Rules

### This repository is public

No domains, hostnames, IP addresses, account names, network topology, or details
of work performed — in code, comments, commit messages, issues, or documentation.

### Credentials never enter the repository

Tokens and passwords are entered live and stored outside the workspace. `.env` is
gitignored. The killswitch shreds credentials when no live SSH session exists.

### Provisioning must not lie

A step that fails must not be reported as success. `host_fail` records failures;
re-run retries. Never downgrade a real failure to a bare warning.
Bump `PROVISION_VERSION` when provisioning steps change.

### `.env` only works because something loads it

`scripts/lib/load-env.sh` parses it (never sources). Environment wins over file.

### sudo is for one step, not for the whole run

`scripts/host/lib/host-common.sh` resolves `CLAUDE_TARGET_USER` and
`CLAUDE_TARGET_HOME`. Any user-level step in a host script must go through
`run_as_target`.

### Build-tooling commands are confirmed manually

Every tool command is confirmed manually. The ctp-bridge is the **only** path to
run `ctp`. Gates: team gate (`CTP_ALLOWED_TEAM`), box allow-list
(`CTP_ALLOWED_TARGET`). No `ASSUME_YES`/`--yes`. Non-interactive callers are refused.
Full details: [`docs/SAFETY_GATES.md`](SAFETY_GATES.md).

### Network changes are deliberate

Egress changes go through `/firewall-allow`. Firewall is IPv4-only. IPv6 denied
wholesale. Details: [`docs/TROUBLESHOOTING.md`](TROUBLESHOOTING.md).

### Pinning third-party installers

Pinned to specific tag + recorded commit SHA. Refuses install on drift.

## Verification

- `bash scripts/check-day0.sh` (or `/day0-check`) — day-0 state on either surface.
- `bash scripts/validate-template.sh` — template invariants; runs in CI.
- `pre-commit run --all-files` — covers gitleaks and semgrep.

## Skill mode filtering

Skills (`.claude/skills/*/SKILL.md`) and commands (`.claude/commands/*.md`)
declare which modes they belong to via `modes:` YAML frontmatter:

```yaml
---
name: recon
description: "..."
modes: [red-team, purple]
---
```

Two layers enforce filtering:

1. **Soft guidance** (`scripts/hooks/mode-inject.sh`, UserPromptSubmit) — injects
   a filtered skill/command list into each prompt so Claude sees only relevant
   entries.
2. **Hard enforcement** (`.claude/hooks/skill-mode-gate.sh`, PreToolUse on
   `Skill`) — denies Skill tool calls when the active mode is not in the skill's
   `modes:` list. Returns a structured deny with the allowed modes.

Skills or commands without a `modes:` field are allowed in all modes (backwards
compatible). The `mode` and `day0-check` commands intentionally omit `modes:` so
they remain universally available.

## Deep-dive references

- [`docs/SAFETY_GATES.md`](SAFETY_GATES.md) — ctp-bridge, destructive-action gate, git guard, path guard, commit guard, secret/PII protection details
- [`docs/TROUBLESHOOTING.md`](TROUBLESHOOTING.md) — DNS prereqs, ECONNRESET diagnosis, debug log noise vs real failures
- [`docs/SAFETY_HARNESS.md`](SAFETY_HARNESS.md) — operator/demonstrator view of the safety harness
