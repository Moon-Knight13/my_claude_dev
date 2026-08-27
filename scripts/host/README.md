# Remote dev-box provisioning (`scripts/host/`)

These scripts bring a **remote dev box** (the box you Remote-SSH into and
use as your dev environment) to the golden state: killswitch, Claude Code +
Ansible extensions, ansible-lint with a Docker execution environment, caveman,
and the Claude plugins.

They run **on the box**, need `sudo` for the host-level killswitch, and are
**idempotent** — every destructive step is confirm-gated (pass `--yes` to
auto-confirm). This is the "pull after connect" half of the flow; the local
half (`scripts/local/bootstrap-devbox.sh`) sets up your laptop's SSH + VSCode.

## Run it

After you have Remote-SSH'd onto the box and cloned this repo there:

```sh
cd my_claude_dev
sudo bash scripts/host/provision-remote-box.sh          # interactive
sudo bash scripts/host/provision-remote-box.sh --yes    # unattended

# with the step that proves the build tooling actually works:
sudo bash scripts/host/provision-remote-box.sh --verify-cmd '<inventory-listing command>'
```

Order it performs:

1. **VSCode server extensions** — `anthropic.claude-code`, `redhat.ansible`.
2. **Ansible-lint** (`setup-ansible-lint.sh`) — merges the ansible settings into
   the Remote-SSH Machine `settings.json` and checks Docker prereqs.
3. **Caveman + Claude plugins** — reuses `scripts/install-caveman.sh` and
   `scripts/install-claude-plugins.sh`, then installs
   `skill-creator@claude-plugins-official` and `gitlab@claude-plugins-official`.
4. **Killswitch** (`setup-killswitch.sh`).
5. **Git identity** — prompted, and **repo-local by default**. `git config
   --global` writes to the shared account's home, so the first developer to set
   it silently becomes the committer identity for every colleague without an
   override. It never overwrites an existing value, and `--git-identity-global`
   opts in only on a box genuinely dedicated to you. The step prints the two
   commands to run in your own project checkout.
6. **Build tooling verification** — runs `--verify-cmd` and treats a failure as a
   failed step, so the box gets no completion marker and a re-run retries. The
   command is site-specific and this repository is public, so it is passed in
   rather than baked in; use whatever proves your tooling can talk to its
   inventory. Without it the step says plainly that this run could not confirm
   the tooling works, and the marker records `tool_verified=unconfigured` —
   it does not quietly claim success.
7. **SSH agent-forwarding check** — verifies the box permits agent forwarding and
   that a forwarded key is reachable (read-only; see below).

A failed step means **no marker and a non-zero exit**, so the next run retries
instead of short-circuiting. That gate covers the whole run: it previously sat
before the last two steps, where a late failure could not have stopped it.

You can also run any step on its own, e.g.
`bash scripts/host/setup-ansible-lint.sh`.

### Reconnect vs. re-image

`provision-remote-box.sh` writes a completion marker at
`/var/lib/claude-devbox/provisioned`. On a later reconnect to the **same** box it
sees the marker and short-circuits with "Already provisioned — skipping", so you
don't re-run setup every time. Because the marker lives on the box filesystem, a
**re-imaged** box has no marker and the full post-install setup runs again
automatically.

```sh
sudo bash scripts/host/provision-remote-box.sh --force   # reprovision anyway
sudo rm -f /var/lib/claude-devbox/provisioned            # or clear the marker
```

Bump `PROVISION_VERSION` in the script when the steps change so already-marked
boxes re-provision on next run.

> **Docker group needs a reboot.** If the ansible step adds you to the `docker`
> group, reboot the box before the Docker execution environment works without
> sudo (matches the manual dev-setup guide).

## SSH agent forwarding

Downstream build tooling on the box — invoked via **`make start`** — authenticates
with your **forwarded** SSH key (`~/.ssh/id_ed25519_<user>_<machine>`, comment `<user>_<machine>`).
Nothing on the box holds your private key; it stays on your laptop and is reached
over the forwarded agent. If forwarding isn't working, those tools fail. Four
things must all be true:

1. **Key is in your laptop's persistent agent** — `ssh-add -l` on your laptop
   lists it. `scripts/local/bootstrap-devbox.sh` adds it, but a key only survives
   in your *login* agent (the script refuses to spawn a throwaway one).
2. **`~/.ssh/config` forwards it** — the Host block has `ForwardAgent yes`
   (the local bootstrap writes this).
3. **VSCode `remote.SSH.useExecServer` is OFF** — set by the local bootstrap.
   It only takes effect on a **fresh** connection, so fully close and reopen the
   Remote-SSH window after the first connect.
4. **The box permits it** — `sshd -T | grep allowagentforwarding` → `yes`
   (checked in provisioning step 7; `provision-remote-box.sh` warns if it's `no`).

**Verify on the box:**

```sh
ssh-add -l     # should list your key (comment <user>_<machine>); "no identities" = broken
```

If it's empty, walk the four points above in order (usually a missed reconnect
after `useExecServer` was turned off).

**A different failure looks identical.** After a dropped connection the editor's
agent socket can be a *dangling symlink*: the agent it pointed at died, the
reconnect started a new one elsewhere, and shells opened before the reconnect keep
the old path. `ssh-add -l` then reports:

```
Error connecting to agent: No such file or directory
```

That is stale, not missing, and forwarding is fine. Repair the current shell:

```sh
eval "$(bash scripts/host/fix-agent-sock.sh)"
```

Do **not** attach to the newest socket under `/tmp/ssh-*/` by hand. The account is
shared, so every connected developer's agent lives there owned by the same user —
"newest" means "whoever reconnected last", and attaching authenticates you as them.

**If the agent works but git pushes are attributed to the wrong account,** the
identity is being decided by agent *order*: ssh offers keys in order and stops at
the first the server accepts, and a wrong-but-known key authenticates
successfully. Diagnose with `bash scripts/host/diagnose-git-auth.sh`; fix by
re-running the laptop bootstrap, which verifies the returned identity and pins it.

## Local model routing on a box

The routing contract in `CLAUDE.md` sends low-risk work to a local model. That
model runs on **your own machine**, not on the box, and `http://host.docker.internal`
resolves only inside the devcontainer — so on a box every routing decision used to
fall through to Claude with `local_unreachable_fallback`, while `.env` and day-0
both reported local routing as configured.

The endpoint reaches the box over a reverse tunnel that
`scripts/local/bootstrap-devbox.sh` writes into your laptop's SSH `Host` block:

```
RemoteForward 127.0.0.1:<box-port> 127.0.0.1:<laptop-port>
```

VSCode Remote-SSH reads that same config, so the tunnel comes up with your normal
connection. Two consequences worth knowing:

- **It is established at connect time.** Adding the line to an open session does
  nothing until you reconnect.
- **The port is bound on the box's loopback**, not published to the network
  (sshd's `GatewayPorts` defaults to `no`). It is still reachable by anyone with a
  shell on that box while your session is open — the account is shared — and
  nothing authenticates to it. The bootstrap refuses to reuse a port already bound
  on the box, because that port would be another developer's tunnel and your
  prompts would leave for their machine.

Then set the matching endpoint in `.env` **on the box**:

```
LOCAL_MODEL_ENDPOINT=http://127.0.0.1:<box-port>
```

`bash scripts/check-day0.sh` verifies this per surface: on a box, local routing
that is enabled but unreachable is a **FAIL**, not a warning — the point is that
the reported state matches the routed state. Set `LOCAL_MODEL_ENABLED=false` if
you would rather route everything to Claude.

Never bind the model to `0.0.0.0` to make a box reach it. That advice belongs to
the container surface; on a box it publishes a personal machine's model onto the
range network.

## The killswitch

`setup-killswitch.sh` installs `/usr/local/sbin/claude-killswitch.sh` plus a PAM
`close_session` hook, a 30-second systemd timer backstop, and an sshd keepalive
drop-in. When the target user has **no** live SSH session, the script shreds
the developer credentials left on the box — `~/.claude/.credentials.json` (Claude
token), `~/.config/gh/hosts.yml` (GitHub token from `gh auth login`) and
`~/.git-credentials` if present — so the next person on the shared account must
authenticate as themselves. Only credentials are removed; losing any of them costs
a re-login, never data. Settings, history, and `projects/` are deliberately kept,
because Claude Code stores transcripts locally and nowhere else — deleting them
would destroy the developer's own history rather than protect anything.

Operate / verify:

```sh
systemctl status claude-killswitch.timer
sudo tail -f /var/log/claude-killswitch.log     # one line per wipe
sudo /usr/local/sbin/claude-killswitch.sh       # manual fire (no-op while connected)
```

### Honest limitations (shared account)

The boxes are a **shared account** with sudo for everyone:

- **Concurrent** sessions still share the token — while two devs are connected
  at once, both can use whichever subscription is logged in. No on-box mechanism
  can prevent that. The killswitch solves the **sequential** case (you leave →
  wiped → a later connector can't reuse it).
- A peer with `sudo` can disable the timer or PAM hook. This is a hygiene /
  accidental-reuse control, **not** a defense against a malicious insider.

The durable fix is org-level: per-dev accounts / keys, or each dev using their
own subscription. The killswitch complements that, it doesn't replace it.

## Rollback (killswitch)

```sh
sudo systemctl disable --now claude-killswitch.timer
sudo rm -f /etc/systemd/system/claude-killswitch.timer \
           /etc/systemd/system/claude-killswitch.service
sudo systemctl daemon-reload
sudo cp -a /etc/pam.d/sshd.bak.killswitch /etc/pam.d/sshd   # restore PAM
sudo rm -f /etc/ssh/sshd_config.d/10-killswitch-keepalive.conf \
           /usr/local/sbin/claude-killswitch.sh
sudo sshd -t && sudo systemctl reload ssh
```
