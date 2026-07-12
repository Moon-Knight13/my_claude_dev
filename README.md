# my_claude_dev

[![ci](https://github.com/Moon-Knight13/my_claude_dev/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/Moon-Knight13/my_claude_dev/actions/workflows/ci.yml)
[![semgrep](https://github.com/Moon-Knight13/my_claude_dev/actions/workflows/semgrep.yml/badge.svg?branch=main)](https://github.com/Moon-Knight13/my_claude_dev/actions/workflows/semgrep.yml)
[![secret-scan](https://github.com/Moon-Knight13/my_claude_dev/actions/workflows/secret-scan.yml/badge.svg?branch=main)](https://github.com/Moon-Knight13/my_claude_dev/actions/workflows/secret-scan.yml)

> **Created from the [`claude_template_repo`](https://github.com/Moon-Knight13/claude_template_repo) template.**
> That template supplies the secure Claude-first scaffolding (AI routing, security
> gates, BMAD, Kanban, devcontainer) this repo is *built with*. What this repo *does*
> is provision remote dev boxes — see below.

**Get a developer onto a shared remote MCD Deploybox and bring that box to a known-good,
Claude-ready state.** You Remote-SSH into a Deploybox and use it directly as your dev
environment (no local container). Two scripts do the work:

1. **On your laptop** — a bootstrap wires up SSH keys + VSCode Remote-SSH. You supply your
   own credentials **live at the prompt**; nothing sensitive is ever written into the repo.
2. **On the box** — a provisioner installs the golden toolset: the Claude Code + Ansible
   VSCode extensions, ansible-lint (Docker execution environment), **caveman** token
   compression, the Claude plugins, and a subscription **killswitch** for the shared account.

Because the boxes are a **shared account** used by a wider team, the killswitch wipes the
Claude token when you disconnect so the next person logs in with their own credentials.

> The repo *itself* is developed inside a devcontainer inherited from the template — see
> [Developing this repo](#developing-this-repo-devcontainer).

## Connect to a Deploybox

### Phase 1 — on your laptop (SSH + VSCode Remote-SSH)

```bash
bash scripts/local/bootstrap-devbox.sh                              # macOS / Linux
# Windows:
powershell -ExecutionPolicy Bypass -File scripts\local\bootstrap-devbox.ps1
```

It **prompts** for your per-dev values — Deploybox number, your range username, the box
domain, and an optional IP — then:

- reuses or generates an `ed25519` SSH key (`~/.ssh/id_ed25519_MCD`) and adds it to your agent;
- writes an idempotent `~/.ssh/config` `Host` block with `ForwardAgent yes` (**outside the repo**);
- runs `ssh-copy-id` so login is passwordless — **your box password is entered live, once, and never stored**;
- installs the VSCode **Remote-SSH** extension and sets `remote.SSH.useExecServer=false` + agent forwarding;
- prints a reminder to add your **public** key to GitLab, then the connect + provision handoff.

The SSH key passphrase and the box password are entered interactively and are **never
committed**. The domain is not hardcoded (this repo is public) — pass it via `DEVBOX_DOMAIN`
or answer the prompt. Re-running the script is safe; it won't duplicate config.

### Phase 2 — on the box (provision to golden state)

Connect (`F1 → Remote-SSH: Connect to Host`, or `ssh deployboxNN.<domain>`), clone this repo
there, and run the provisioner:

```bash
git clone https://github.com/Moon-Knight13/my_claude_dev
cd my_claude_dev
sudo bash scripts/host/provision-remote-box.sh          # interactive
sudo bash scripts/host/provision-remote-box.sh --yes    # unattended
```

It runs, in order (each step idempotent; destructive bits confirm-gated):

1. **VSCode server extensions** — `anthropic.claude-code`, `redhat.ansible`.
2. **Ansible-lint + Docker** — merges ansible settings and checks the Docker
   execution-environment prerequisites (`setup-ansible-lint.sh`).
3. **Caveman + Claude plugins** — `install-caveman.sh` and `install-claude-plugins.sh`
   (skill-creator, frontend-design, code-review, superpowers, commit-commands), plus the
   on-box extras `skill-creator@` and `gitlab@claude-plugins-official`.
4. **Killswitch** — `setup-killswitch.sh` (see below).

**Reconnect-safe.** A completion marker at `/var/lib/claude-devbox/provisioned` lets a
re-run on the *same* box short-circuit with "Already provisioned — skipping." The marker
lives on the box filesystem, so a **re-imaged** box has none and re-provisions in full.
Force a re-run with `--force`. If the ansible step adds you to the `docker` group, **reboot
the box** for the Docker execution environment to work without `sudo`.

Finally run `make start` to configure Catapult — it uses your GitLab/VPN password
interactively, and that secret is likewise never stored by these scripts.

### The killswitch (shared account)

The Deployboxes are a **shared account** with sudo for everyone. `setup-killswitch.sh`
installs a PAM hook + systemd timer that shred `~/.claude/.credentials.json` once the target
user has **no** live SSH session — so the next connector must `/login` with their own
credentials. Only the token file is removed; settings, history, and `projects/` are kept.

This is a **sequential-reuse hygiene control, not a defense against a malicious insider**:
concurrent sessions still share whichever token is logged in, and a peer with `sudo` can
disable it. The durable fix is org-level (per-dev accounts/keys, or each dev on their own
subscription). See [`scripts/host/README.md`](scripts/host/README.md) for the full run,
verify, honest-limitations, and rollback details.

## Developing this repo (devcontainer)

Work *on this repo* happens inside a devcontainer carried over from
[`claude_template_repo`](https://github.com/Moon-Knight13/claude_template_repo): a
deny-by-default network firewall, AI task routing (low-risk work to a local Ollama model,
escalating to Claude for security/architecture/cross-cutting changes), the BMAD planning
workflow, a per-repo GitHub Project **Kanban** board, and deterministic **CI security gates**
(gitleaks, semgrep incl. MITRE ATLAS AI/ML rules, Trivy) enforced on every merge.

Open the repo in the devcontainer (VS Code prompts to reopen; accept — tooling installs on
start), then do the two day-0 logins:

```bash
gh auth login --hostname github.com --git-protocol https --web -s project && gh auth setup-git
claude auth login
bash scripts/setup-day0.sh    # finishes the auth-gated bootstraps, prints status
```

Verify anytime with `bash scripts/check-day0.sh` — or from Claude: `/day0-check`.

📊 **[Open the visual overview →](https://moon-knight13.github.io/my_claude_dev/)** — a
one-page briefing (technical and non-technical) covering the Deploybox provisioning flow,
the devcontainer, the two routing engines, caveman token compression, and the CI gates.
Served from [`docs/explainer/`](docs/explainer/index.html); the page is self-contained, so
you can also open the HTML locally.

## Prerequisites

**Laptop (to connect):** VS Code with the Remote-SSH extension · an SSH client · a GitLab
account you can add a public key to.

**Box (to provision):** `sudo` on the shared account · Docker (for the ansible-lint execution
environment).

**Repo development (devcontainer):** Docker + the VS Code Dev Containers extension · the
Claude Code CLI (authenticated) · optional Ollama on host port 11434 for local-model offload.

See [docs/TEMPLATE_GUIDE.md](docs/TEMPLATE_GUIDE.md) for the full setup guide including
Caveman token compression and PII-Shield.

## Repository Structure

```
scripts/local/       Developer-laptop bootstrap (SSH + VSCode Remote-SSH to a Deploybox)
scripts/host/        Remote Deploybox provisioning (killswitch, extensions, ansible-lint)
scripts/             Bootstrap (incl. board), routing, CI helpers, and template validator
.devcontainer/       Dev environment (for developing this repo) — deny-by-default firewall, pre-installed tooling
.claude/commands/    Claude Code skills (/bmad, /bmad-to-board, /next-issue, /run-epic, /day0-check, /route-task, /security-audit, /firewall-allow)
.github/             Workflows (CI, secret scan, semgrep, container scan, weekly audit); issue & PR templates
docs/                TEMPLATE_GUIDE.md, AI_ROUTING_POLICY.md, BMAD_WORKFLOW.md, KANBAN_WORKFLOW.md, explainer/
```

## License

Apache 2.0 — see [LICENSE](LICENSE).
