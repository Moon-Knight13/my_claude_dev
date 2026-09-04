# my_claude_dev

[![ci](https://github.com/Moon-Knight13/my_claude_dev/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/Moon-Knight13/my_claude_dev/actions/workflows/ci.yml)
[![semgrep](https://github.com/Moon-Knight13/my_claude_dev/actions/workflows/semgrep.yml/badge.svg?branch=main)](https://github.com/Moon-Knight13/my_claude_dev/actions/workflows/semgrep.yml)
[![secret-scan](https://github.com/Moon-Knight13/my_claude_dev/actions/workflows/secret-scan.yml/badge.svg?branch=main)](https://github.com/Moon-Knight13/my_claude_dev/actions/workflows/secret-scan.yml)

> **Created from the [`claude_template_repo`](https://github.com/Moon-Knight13/claude_template_repo) template.**
> That template supplies the secure Claude-first scaffolding (AI routing, security
> gates, BMAD, Kanban, devcontainer) this repo is *built with*. What this repo *does*
> is provision remote dev boxes — see below.

**Get a developer onto a shared remote dev box and bring that box to a known-good,
Claude-ready state.** You Remote-SSH into a box and use it directly as your dev
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

## Connect to a box

### Phase 1 — on your laptop (SSH + VSCode Remote-SSH)

```bash
bash scripts/local/bootstrap-devbox.sh                              # macOS / Linux
# Windows:
powershell -ExecutionPolicy Bypass -File scripts\local\bootstrap-devbox.ps1
```

It **prompts** for your per-dev values — box number, hostname prefix, your username, the box
domain, and an optional IP — then:

- asks the git server which of your existing keys it already accepts and **reuses** that one,
  generating `~/.ssh/id_ed25519_<user>_<machine>` only when there is nothing to reuse — a
  second, unregistered key would compete for position in agent order, which is the fault
  the identity check below exists to catch;
- writes an idempotent `~/.ssh/config` `Host` block with `IdentityFile` and `ForwardAgent` (**outside the repo**);
- runs `ssh-copy-id` so login is passwordless — **your box password is entered live, once, and never stored**;
- installs the VSCode **Remote-SSH** extension and sets `remote.SSH.useExecServer=false` + agent forwarding;
- prints a reminder to add your **public** key to the git server;
- **verifies which identity the git server actually returns**, from this machine and from the
  box, and pins the box to the right key only if the two disagree. A wrong key authenticates
  *successfully*, so without this check nothing surfaces until a push is refused;
- then the connect + provision handoff.

The SSH key passphrase and the box password are entered interactively and are **never
committed**. The domain is not hardcoded (this repo is public) — pass it via `DEVBOX_DOMAIN`
or answer the prompt. Re-running the script is safe; it won't duplicate config.

### Phase 2 — on the box (provision to golden state)

Connect (`F1 → Remote-SSH: Connect to Host`, or `ssh <box-host>`), clone this repo
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
5. **SSH agent forwarding** — read-only check that the box permits agent
   forwarding and that a forwarded key is reachable. Warns; never edits `sshd`.

**Reconnect-safe.** A completion marker at `/var/lib/claude-devbox/provisioned` lets a
re-run on the *same* box short-circuit with "Already provisioned — skipping." The marker
lives on the box filesystem, so a **re-imaged** box has none and re-provisions in full.
Force a re-run with `--force`. If the ansible step adds you to the `docker` group, **reboot
the box** for the Docker execution environment to work without `sudo`.

> **Agent forwarding is required** — the downstream build tooling uses your
> *forwarded* SSH key. After connecting, ensure VSCode `remote.SSH.useExecServer`
> is off, **reconnect**, then verify on the box with `ssh-add -l`. See
> [SSH agent forwarding](scripts/host/README.md#ssh-agent-forwarding).

Finally run `make start` to configure the downstream build tooling — it prompts for a
password interactively, and that secret is likewise never stored by these scripts.

### The killswitch (shared account)

The boxes are a **shared account** with sudo for everyone. `setup-killswitch.sh`
installs a PAM hook + systemd timer that shred the developer credentials left on the box
once the target user has **no** live SSH session — so the next connector must authenticate
as themselves:

| File | Credential |
| --- | --- |
| `~/.claude/.credentials.json` | Claude subscription token |
| `~/.config/gh/hosts.yml` | GitHub token from `gh auth login` |
| `~/.git-credentials` | plaintext git credential store, if present |

Only credentials are removed — losing any of them costs a re-login, never data. Settings,
history, and `projects/` are deliberately **kept**: Claude Code stores session transcripts
locally and nowhere else, so deleting them would destroy the developer's own history rather
than protect anything. Keep sensitive detail out of prompts on a shared box.

This is a **sequential-reuse hygiene control, not a defense against a malicious insider**:
concurrent sessions still share whichever token is logged in, and a peer with `sudo` can
disable it. The durable fix is org-level (per-dev accounts/keys, or each dev on their own
subscription). See [`scripts/host/README.md`](scripts/host/README.md) for the full run,
verify, honest-limitations, and rollback details.

### The safety harness (on the box)

When Claude works on a provisioned box, a set of controls sits between the agent
and the box and turns the risky actions into a human decision — or refuses them
outright. It is built backwards from four "what if" worries: Claude **leaking
Org PII/IP** into the transcript, **committing secrets/PII**, running a
**destructive command**, or making an **unauthorized web connection**. It is
defense-in-depth and human-in-the-loop, deliberately **not** a sandbox — the
shared-sudo box gives no OS isolation, an accepted risk.

Each control is **demonstrable** — feed the PreToolUse hook a tool call and read
its verdict, or ask Claude to do the risky thing and watch the confirm/deny. The
full active-usage walkthrough and copy-paste demo is in
**[docs/SAFETY_HARNESS.md](docs/SAFETY_HARNESS.md)**; the subsections below cover
the built controls, and `check-day0.sh` reports each one's posture honestly.

### Commit guard (warn-only, on the box)

Provisioning installs a user-scope commit guard so accidental secrets or PII are
caught on **every** commit — human or agent — in any repo, including the range
checkout. It is **warn-only**: it prints each finding and logs `rule/file/line`
(never the value) to `~/.local/state/commit-guard/`, then lets the commit
through. For a secret that means rotating it per [SECURITY.md](SECURITY.md) —
warn-only shifts the mitigation to fast reaction, not prevention. Like the other
on-box hooks it is defense-in-depth, not a boundary (`--no-verify` bypasses it).
The blocking pre-commit + CI gitleaks gates still apply when developing this repo
in the devcontainer.

### Destructive-action gate (on the box)

The same user-scope PreToolUse hook that fronts the build-tooling bridge also
**confirms destructive shell commands** before an agent runs them — `rm -rf`,
`shred`, `mkfs`, `dd of=`, `dropdb`, `DROP`/`TRUNCATE` SQL, `terraform destroy`,
`kubectl delete`, `docker system prune`. With no human to confirm it **fails
closed** to a deny. It classifies segmented command words (not raw strings) via
the shared `cmd-segment.sh`, is model-agnostic (the classifier is a lib any
executor routes through), and deliberately does **not** cover git/commit (the
commit guard's domain) or `ctp` (already gated). Defense-in-depth, not a sandbox.

### Keeping Org data out of Claude (path guard, on the box)

Hooks can deny a read but **cannot redact tool output**, so the way to keep Org
PII/IP out of the transcript is to refuse the read. List Org-data path globs in
`CTP_PII_PATHS` (in `~/.ctp-bridge.conf`) and the hook denies any tool Read/Write
or Bash command that names them — a separate, owner-tuned list from the credential
`CTP_SECRET_PATHS`. **Opt-in** (empty by default). Path-based only; intelligent
content-level redaction is the job of the local-model orchestrator (planned),
which can rephrase sensitive content — including tool output — before Claude sees
it. Defense-in-depth, not OS containment.

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
one-page briefing (technical and non-technical) covering the box provisioning flow,
the devcontainer, the two routing engines, caveman token compression, the CI gates, and
the on-box safety harness in action.
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
scripts/local/       Developer-laptop bootstrap (SSH + VSCode Remote-SSH to a box)
scripts/host/        Remote box provisioning (killswitch, extensions, ansible-lint)
scripts/             Bootstrap (incl. board), routing, CI helpers, and template validator
.devcontainer/       Dev environment (for developing this repo) — deny-by-default firewall, pre-installed tooling
.claude/commands/    Claude Code skills (/bmad, /bmad-to-board, /next-issue, /run-epic, /day0-check, /route-task, /security-audit, /firewall-allow)
.github/             Workflows (CI, secret scan, semgrep, container scan, weekly audit); issue & PR templates
docs/                SAFETY_HARNESS.md, ORCHESTRATOR.md, TEMPLATE_GUIDE.md, AI_ROUTING_POLICY.md, BMAD_WORKFLOW.md, KANBAN_WORKFLOW.md, explainer/
```

## License

Apache 2.0 — see [LICENSE](LICENSE).
