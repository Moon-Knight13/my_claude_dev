# my_claude_dev

[![ci](https://github.com/Moon-Knight13/my_claude_dev/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/Moon-Knight13/my_claude_dev/actions/workflows/ci.yml)
[![tests](https://github.com/Moon-Knight13/my_claude_dev/actions/workflows/tests.yml/badge.svg?branch=main)](https://github.com/Moon-Knight13/my_claude_dev/actions/workflows/tests.yml)
[![semgrep](https://github.com/Moon-Knight13/my_claude_dev/actions/workflows/semgrep.yml/badge.svg?branch=main)](https://github.com/Moon-Knight13/my_claude_dev/actions/workflows/semgrep.yml)
[![secret-scan](https://github.com/Moon-Knight13/my_claude_dev/actions/workflows/secret-scan.yml/badge.svg?branch=main)](https://github.com/Moon-Knight13/my_claude_dev/actions/workflows/secret-scan.yml)

Hub platform for AI-assisted red team operations. Runs on the operator's laptop
with Claude Opus 4.6 as the primary session, MCP servers for targeting and C2
intelligence, and dev boxes connected as spokes via SSH tunnels.

## Architecture

```
 Operator Laptop (hub)
 +-----------------------------------------+
 |  Claude Opus 4.6 primary session        |
 |                                         |
 |  MCP servers:                           |
 |    outline-readonly  (wiki intel)       |
 |    range-intel       (targeting)        |
 |    GitLab MCP        (coming soon)      |
 |                                         |
 |  ctp-bridge          (deploy tooling)   |
 +-----------+-----------------------------+
             |  SSH tunnels
     +-------+-------+
     |               |
  dev-box-1       dev-box-N   (spokes)
```

**Backup plan:** If Opus 4.6 is unavailable, fall back to OpenCode + OpenRouter
with a local abliterated model.

**Archived:** The local model orchestrator, sensitivity routing, and SP1a gate
are archived on the `archive/sp1a-gate` branch.

## MCP Servers

All servers live under `mcp-servers/`:

| Server | Purpose | Stack |
|--------|---------|-------|
| `outline-readonly` | Read-only access to the Outline wiki for doctrine, rules, and planning docs | Node.js, zero dependencies |
| `range-intel` | Providentia range data + GitLab VM README vulnerability profiles for targeting intel | Python (FastMCP) |
| GitLab MCP | Source code and issue access | Coming soon |

## Connect to a Box

### Phase 1 -- on your laptop (SSH + VSCode Remote-SSH)

```bash
bash scripts/local/bootstrap-devbox.sh                              # macOS / Linux
# Windows:
powershell -ExecutionPolicy Bypass -File scripts\local\bootstrap-devbox.ps1
```

It **prompts** for your per-dev values -- box number, hostname prefix, your username, the box
domain, and an optional IP -- then:

- asks the git server which of your existing keys it already accepts and **reuses** that one,
  generating `~/.ssh/id_ed25519_<user>_<machine>` only when there is nothing to reuse -- a
  second, unregistered key would compete for position in agent order, which is the fault
  the identity check below exists to catch;
- writes an idempotent `~/.ssh/config` `Host` block with `IdentityFile` and **`ForwardAgent no`** (**outside the repo**).
  The box account is shared, so agent forwarding and the local-model reverse tunnel are **opt-in**:
  `SCOPE_AGENT=true SCOPE_AGENT_KEYS="..."` forwards only the listed keys (OpenSSH >= 8.9; older clients get no
  forwarding), `FORWARD_AGENT=all` forwards every agent key (needed to deploy from the box until the
  required keys are known), and `LOCAL_MODEL_TUNNEL=true` adds the tunnel. For onward hops prefer
  `ssh -J <alias> <next-host>` (ProxyJump). A re-run warns if an older block still forwards;
- runs `ssh-copy-id` so login is passwordless -- **your box password is entered live, once, and never stored**;
- installs the VSCode **Remote-SSH** extension and sets `remote.SSH.useExecServer=false`, and switches VSCode agent forwarding on only if you opted in above (it is a global VSCode setting, so it is never forced off);
- prints a reminder to add your **public** key to the git server;
- **verifies which identity the git server actually returns**, from this machine and from the
  box, and pins the box to the right key only if the two disagree. A wrong key authenticates
  *successfully*, so without this check nothing surfaces until a push is refused;
- then the connect + provision handoff.

The SSH key passphrase and the box password are entered interactively and are **never
committed**. The domain is not hardcoded (this repo is public) -- pass it via `DEVBOX_DOMAIN`
or answer the prompt. Re-running the script is safe; it won't duplicate config.

### Phase 2 -- on the box (provision to golden state)

Connect (`F1 -> Remote-SSH: Connect to Host`, or `ssh <box-host>`), clone this repo
there, and run the provisioner:

```bash
git clone https://github.com/Moon-Knight13/my_claude_dev
cd my_claude_dev
sudo bash scripts/host/provision-remote-box.sh          # interactive
sudo bash scripts/host/provision-remote-box.sh --yes    # unattended
```

It runs, in order (each step idempotent; destructive bits confirm-gated):

1. **VSCode server extensions** -- `anthropic.claude-code`, `redhat.ansible`.
2. **Ansible-lint + Docker** -- merges ansible settings and checks the Docker
   execution-environment prerequisites (`setup-ansible-lint.sh`).
3. **Caveman + Claude plugins** -- `install-caveman.sh` and `install-claude-plugins.sh`
   (skill-creator, frontend-design, code-review, superpowers, commit-commands), plus the
   on-box extras `skill-creator@` and `gitlab@claude-plugins-official`.
4. **Killswitch** -- `setup-killswitch.sh` (see below).
5. **SSH agent forwarding** -- read-only check that the box permits agent
   forwarding and that a forwarded key is reachable. Warns; never edits `sshd`.

**Reconnect-safe.** A completion marker at `/var/lib/claude-devbox/provisioned` lets a
re-run on the *same* box short-circuit with "Already provisioned -- skipping." The marker
lives on the box filesystem, so a **re-imaged** box has none and re-provisions in full.
Force a re-run with `--force`. If the ansible step adds you to the `docker` group, **reboot
the box** for the Docker execution environment to work without `sudo`.

Finally run `make start` to configure the downstream build tooling -- it prompts for a
password interactively, and that secret is likewise never stored by these scripts.

### The killswitch (shared account)

The boxes are a **shared account** with sudo for everyone. `setup-killswitch.sh`
installs a PAM hook + systemd timer that shred the developer credentials left on the box
once the target user has **no** live SSH session -- so the next connector must authenticate
as themselves:

| File | Credential |
| --- | --- |
| `~/.claude/.credentials.json` | Claude subscription token |
| `~/.config/gh/hosts.yml` | GitHub token from `gh auth login` |
| `~/.git-credentials` | plaintext git credential store, if present |

Only credentials are removed -- losing any of them costs a re-login, never data. Settings,
history, and `projects/` are deliberately **kept**: Claude Code stores session transcripts
locally and nowhere else, so deleting them would destroy the developer's own history rather
than protect anything. Keep sensitive detail out of prompts on a shared box.

This is a **sequential-reuse hygiene control, not a defense against a malicious insider**:
concurrent sessions still share whichever token is logged in, and a peer with `sudo` can
disable it. The durable fix is org-level (per-dev accounts/keys, or each dev on their own
subscription). See [`scripts/host/README.md`](scripts/host/README.md) for the full run,
verify, honest-limitations, and rollback details.

## Safety Guards

Controls between the agent and the box that turn risky actions into a human
decision or refuse them outright. Built around four concerns: **leaking Org
PII/IP**, **committing secrets**, **destructive commands**, and **unauthorized
web connections**. Defense-in-depth; not a sandbox.

- **Commit guard** -- user-scope hook on every commit. Warn-only: prints findings, logs
  `rule/file/line` (never the value) to `~/.local/state/commit-guard/`.
- **Destructive-action gate** -- PreToolUse hook confirms `rm -rf`, `shred`, `mkfs`,
  `dd of=`, `dropdb`, `DROP`/`TRUNCATE`, `terraform destroy`, `kubectl delete`,
  `docker system prune` before execution. Fails closed with no human present.
- **Path guard** -- denies tool reads/writes to paths listed in `CTP_PII_PATHS`
  (`~/.ctp-bridge.conf`). Opt-in, owner-tuned.

Full walkthrough in [docs/SAFETY_HARNESS.md](docs/SAFETY_HARNESS.md).

## Developing This Repo

Work *on this repo* happens inside a devcontainer from
[`claude_template_repo`](https://github.com/Moon-Knight13/claude_template_repo):
deny-by-default network firewall, BMAD planning workflow, per-repo GitHub Project
Kanban board, and deterministic CI security gates (gitleaks, semgrep incl. MITRE
ATLAS AI/ML rules, Trivy) enforced on every merge.

```bash
gh auth login --hostname github.com --git-protocol https --web -s project && gh auth setup-git
claude auth login
bash scripts/setup-day0.sh    # finishes the auth-gated bootstraps, prints status
```

Verify anytime with `bash scripts/check-day0.sh` or from Claude: `/day0-check`.

## Tests

Every `scripts/tests/test-*.sh` suite runs in CI on each push and PR (the `tests`
workflow), using local mocks -- no live model or network endpoint. Run them the same
way locally:

```bash
bash scripts/tests/run-all.sh            # all suites, one PASS/FAIL line each
bash scripts/tests/run-all.sh guard ctp  # only suites whose name contains a filter
```

A suite that fails for a tracked reason is listed in `scripts/tests/known-failures.txt`
with its issue number; it is still run and reported but does not fail the build.

## Repository Structure

```
mcp-servers/         MCP servers (outline-readonly, range-intel)
scripts/local/       Developer-laptop bootstrap (SSH + VSCode Remote-SSH to a box)
scripts/host/        Remote box provisioning (killswitch, extensions, ansible-lint)
scripts/             Bootstrap, CI helpers, and template validator
.devcontainer/       Dev environment (for developing this repo)
.claude/commands/    Claude Code skills
.github/             Workflows (CI, secret scan, semgrep, container scan); issue & PR templates
docs/                SAFETY_HARNESS.md, TEMPLATE_GUIDE.md, BMAD_WORKFLOW.md, KANBAN_WORKFLOW.md
```

## Prerequisites

**Laptop (hub):** Claude Code CLI (authenticated) with Opus 4.6 access. Node.js (for
outline-readonly). Python 3.12+ (for range-intel). VS Code with Remote-SSH extension.

**Box (spoke):** `sudo` on the shared account. Docker (for the ansible-lint execution
environment).

**Repo development (devcontainer):** Docker + the VS Code Dev Containers extension.

## License

Apache 2.0 -- see [LICENSE](LICENSE).
