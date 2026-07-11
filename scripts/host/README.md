# Remote dev-box provisioning (`scripts/host/`)

These scripts bring a **MCD Deploybox** (the remote box you Remote-SSH into and
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
```

Order it performs:

1. **VSCode server extensions** — `anthropic.claude-code`, `redhat.ansible`.
2. **Ansible-lint** (`setup-ansible-lint.sh`) — merges the ansible settings into
   the Remote-SSH Machine `settings.json` and checks Docker prereqs.
3. **Caveman + Claude plugins** — reuses `scripts/install-caveman.sh` and
   `scripts/install-claude-plugins.sh`, then installs
   `skill-creator@claude-plugins-official` and `gitlab@claude-plugins-official`.
4. **Killswitch** (`setup-killswitch.sh`).
5. **SSH agent-forwarding check** — verifies the box permits agent forwarding and
   that a forwarded key is reachable (read-only; see below).

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

## SSH agent forwarding (Catapult / ctp)

Downstream tools on the box — **Catapult / `ctp` / `make start`** — authenticate
with your **forwarded** SSH key (`~/.ssh/id_ed25519_MCD`, comment `MCD_<user>`).
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
   (checked in provisioning step 5; `provision-remote-box.sh` warns if it's `no`).

**Verify on the box:**

```sh
ssh-add -l     # should list your key (comment MCD_<user>); "no identities" = broken
```

If it's empty, walk the four points above in order (usually a missed reconnect
after `useExecServer` was turned off).

## The killswitch

`setup-killswitch.sh` installs `/usr/local/sbin/claude-killswitch.sh` plus a PAM
`close_session` hook, a 30-second systemd timer backstop, and an sshd keepalive
drop-in. When the target user has **no** live SSH session, the script shreds
`~/.claude/.credentials.json`, so the next person on the shared account must
`/login` with their own credentials. Only the token file is removed — settings,
history, and `projects/` are kept.

Operate / verify:

```sh
systemctl status claude-killswitch.timer
sudo tail -f /var/log/claude-killswitch.log     # one line per wipe
sudo /usr/local/sbin/claude-killswitch.sh       # manual fire (no-op while connected)
```

### Honest limitations (shared account)

The Deployboxes are a **shared `gt` account** with sudo for everyone:

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
