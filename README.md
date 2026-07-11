# my_claude_dev

[![ci](https://github.com/Moon-Knight13/my_claude_dev/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/Moon-Knight13/my_claude_dev/actions/workflows/ci.yml)
[![semgrep](https://github.com/Moon-Knight13/my_claude_dev/actions/workflows/semgrep.yml/badge.svg?branch=main)](https://github.com/Moon-Knight13/my_claude_dev/actions/workflows/semgrep.yml)
[![secret-scan](https://github.com/Moon-Knight13/my_claude_dev/actions/workflows/secret-scan.yml/badge.svg?branch=main)](https://github.com/Moon-Knight13/my_claude_dev/actions/workflows/secret-scan.yml)

> **Created from the [`claude_template_repo`](https://github.com/Moon-Knight13/claude_template_repo) template.**
> That template supplies the secure Claude-first scaffolding (AI routing, security
> gates, BMAD, Kanban, devcontainer). This repo builds on it.

A Claude-first secure development repo. It carries the full
[`claude_template_repo`](https://github.com/Moon-Knight13/claude_template_repo)
scaffolding — secure defaults, AI task routing, BMAD workflow, and deterministic
CI gates — **plus** its distinguishing feature: the **MCD Deploybox golden-provisioning
workflow** that brings a shared remote dev box to a known-good state (see
[Remote Deploybox provisioning](#remote-deploybox-provisioning-non-container)).

## What's Included

- **AI routing** — routes low-risk work to a local Ollama model; escalates to Claude for security, architecture, and cross-cutting changes
- **Security gates** — gitleaks secret scanning, semgrep SAST (including MITRE ATLAS AI/ML rules), Trivy container scanning, all enforced in CI
- **BMAD workflow** — structured product → engineering planning via the `/bmad` skill
- **Kanban orchestration** — a per-repo GitHub Project board where a human orchestrator hands work to Claude sessions or local models; agents claim issues collision-free via `/next-issue` and `/run-epic` (see [docs/KANBAN_WORKFLOW.md](docs/KANBAN_WORKFLOW.md))
- **Devcontainer** — deny-by-default network firewall, pre-installed tooling, Claude CLI with mounted auth volume
- **Branch protection bootstrap** — one-command GitHub branch protection with required status checks
- **Day-0 validation** — `/day0-check` walks you through every setup step with pass/fail output and remediation hints

## How it works

Work comes in as a board card, gets **routed** by risk — to a human, to Claude, or to a
cheaper local model — and every change runs the same security gates before it merges. The
whole loop runs inside a devcontainer whose network is deny-by-default.

📊 **[Open the visual overview →](https://moon-knight13.github.io/my_claude_dev/)** —
a one-page briefing (for technical and non-technical readers) covering the devcontainer, the
two engines, caveman token compression, and the CI gates. Served from
[`docs/explainer/`](docs/explainer/index.html) via GitHub Pages; the page is self-contained,
so you can also open the HTML locally.

- **Routing** derives from `scripts/route-model.sh`; the same Human/Claude/Local decision
  shows up as the **Route** field on each board card.
- **Gates are required, not advisory** — a red check blocks the merge (see
  [`.github/workflows/`](.github/workflows/)).
- **Caveman** trims Claude's prose to cut output tokens and surfaces a live per-session
  token/cost tally in the statusline (see [docs/TEMPLATE_GUIDE.md](docs/TEMPLATE_GUIDE.md)).

## Prerequisites

- Docker + VS Code Dev Containers extension
- Git with SSH access to GitHub
- Claude Code CLI (authenticated before first session)
- Optional: Ollama on host port 11434 for local model offload

See [docs/TEMPLATE_GUIDE.md](docs/TEMPLATE_GUIDE.md) for the full setup guide including Caveman token compression and PII-Shield.

## Quick Start

1. **Use this template** — click "Use this template" on GitHub, or clone and re-init:
   ```bash
   git clone <this-repo> my-project && cd my-project && rm -rf .git && git init
   ```

2. **Open in devcontainer** — VS Code prompts to reopen; accept. The container installs all tooling automatically on start.

3. **Complete day-0 setup** — two browser logins; everything else is applied automatically on container start:
   ```bash
   gh auth login --hostname github.com --git-protocol https --web -s project && gh auth setup-git
   claude auth login
   bash scripts/setup-day0.sh   # finishes the auth-gated bootstraps, prints status
   ```
   Verify anytime with `bash scripts/check-day0.sh` — or from Claude: `/day0-check`

4. **Validate the template** — confirm all template integrity checks pass:
   ```bash
   bash scripts/validate-template.sh
   ```

## Remote Deploybox provisioning (non-container)

For the MCD workflow where you Remote-SSH into a shared **Deploybox** and use it
directly as your dev environment (no local devcontainer), two scripts bring a box
to the golden state:

1. **On your laptop** — configure SSH + VSCode Remote-SSH (prompts for the box
   number and your login; no secrets are stored in the repo):
   ```bash
   bash scripts/local/bootstrap-devbox.sh      # macOS/Linux
   # Windows: powershell -ExecutionPolicy Bypass -File scripts\local\bootstrap-devbox.ps1
   ```
2. **On the box** (after connecting + cloning this repo there) — install the
   killswitch, Claude + Ansible extensions, ansible-lint (Docker EE), caveman,
   and the Claude plugins:
   ```bash
   sudo bash scripts/host/provision-remote-box.sh
   ```

> **Agent forwarding is required** — downstream tools (Catapult/`ctp`) use your
> *forwarded* SSH key. After connecting, ensure VSCode `remote.SSH.useExecServer`
> is off, **reconnect**, then verify on the box with `ssh-add -l`. See
> [SSH agent forwarding](scripts/host/README.md#ssh-agent-forwarding-catapult--ctp).

See [`scripts/host/README.md`](scripts/host/README.md) for details, the
subscription **killswitch** (wipes the Claude token when no SSH session remains
on the shared account), and its honest limitations.

## Repository Structure

```
.claude/commands/    Claude Code skills (/bmad, /bmad-to-board, /next-issue, /run-epic, /day0-check, /route-task, /security-audit, /firewall-allow)
.devcontainer/       Dev environment with deny-by-default firewall and pre-installed tooling
.github/             Workflows (CI, secret scan, semgrep, container scan, weekly audit); issue & PR templates
docs/                TEMPLATE_GUIDE.md, AI_ROUTING_POLICY.md, BMAD_WORKFLOW.md, KANBAN_WORKFLOW.md
scripts/             Bootstrap (incl. board), routing, CI helpers, and template validator
scripts/local/       Developer-laptop bootstrap (SSH + VSCode Remote-SSH to a Deploybox)
scripts/host/        Remote Deploybox provisioning (killswitch, extensions, ansible-lint)
```

## Deriving a New Project

When you start a new project from this template:

1. Replace this `README.md` with your project README — use [`docs/README.template.md`](docs/README.template.md) as a starting point.
2. Add `scripts/ci/lint-*.sh` and `scripts/ci/test-*.sh` for your language stack (see `scripts/ci/README.md`).
3. Do the two day-0 logins (quick start step 3) — `scripts/setup-day0.sh` then fills CODEOWNERS, copies configs, applies branch protection, and creates the Kanban board (see [docs/KANBAN_WORKFLOW.md](docs/KANBAN_WORKFLOW.md)).
4. Replace or remove `docs/explainer/` — it describes *this template*, not your project. If you keep a project explainer there, enable GitHub Pages to serve it (**Settings → Pages → Source: "GitHub Actions"**); the `pages` workflow publishes it on the next push. Leave Pages disabled if the page shouldn't be public.

## License

Apache 2.0 — see [LICENSE](LICENSE).
