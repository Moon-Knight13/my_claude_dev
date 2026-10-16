# SP1a hub setup — `lane2 install`

The hub runs only code from a **merged** commit, installed by root into a prefix
no workspace, operator, or service can write. `lane2 install` is the only way
hub code, units, and stores get there (AD-18, FR-22, FR-52). It never reads the
checkout you run it from, so a dirty or unmerged local tree cannot reach the hub.

## Before the first install

1. Run the hardware check on the host ([SP1A_HARDWARE_CHECK.md](SP1A_HARDWARE_CHECK.md)).
2. Install the tools: `bash`, `jq`, `socat`, `systemd`, `git`, `tar`, `flock`.
   `lane2 install` stops with ` FAIL required tool missing: <tool>` otherwise.
3. Create the state root, root-owned and mode 0755:
   `sudo install -d -o root -g root -m 755 /var/lib/lane2`
4. Write `/etc/lane2/lane2.conf` (root-owned, not world-writable):

   ```bash
   LANE2_ORIGIN=https://<git host>/<you>/<this repo>.git
   LANE2_DEFAULT_BRANCH=main
   LANE2_OPERATOR=<your login>
   # optional, shown with defaults:
   LANE2_PREFIX=/opt/lane2
   LANE2_STATE_ROOT=/var/lib/lane2
   LANE2_UNIT_DIR=/etc/systemd/system
   LANE2_KEEP_INSTALLS=3
   ```

   The file is parsed, never sourced; the last assignment of a key wins. The
   origin must be an `https://` or `ssh://` URL with no credentials in it. A
   local path or `file://` URL is refused, because it could point into a
   workspace the agent writes.

## Install

Merge the change on the git host first, then on the hub:

```bash
sudo scripts/hub/lane2 install <full 40-character commit id>
```

Run it from any copy of the repository; it reads none of it. It:

1. refuses inside a container, as non-root, for an abbreviated id, a branch or
   tag name, or a local-path origin (exit 4);
2. fetches the default branch from the origin into a hub-owned bare clone and
   refuses a commit that is not on it (exit 3: unknown or unmerged);
3. creates the service identities and the stores (below);
4. exports the commit's tree with `git archive` into `<prefix>/<commit>/`,
   root-owned, nothing group- or world-writable;
5. renders and lints the units in `scripts/hub/units/` from that tree;
6. swaps `<prefix>/current` to the new commit atomically;
7. installs the units, enables only the boot allowlist, restarts installed
   services, and records the digests.

Every step before the swap can fail without changing anything: the previous
install keeps running and `current` stays where it was. Exit codes: 0 ok,
2 usage, 3 unknown or unmerged commit, 4 or more for every other refusal or fault.

## Upgrade and rollback

- **Upgrade:** merge, then `lane2 install <new commit>`. The new tree goes beside
  the old one, `current` swaps, hub services restart.
- **Rollback:** `lane2 install <earlier commit>`. If its tree is still installed,
  it is checked against its record and reused.
- Older commit directories beyond `LANE2_KEEP_INSTALLS` (current included) are
  removed after a successful install. Current is never removed.

## Verify

```bash
sudo scripts/hub/lane2 install --verify
```

Recomputes the installed-code digest (sha256 over the sorted file list and
contents of the installed tree) and the gate-code digest (the same over the gate
code only) and compares them with the install record. It also fails on any path
in the install that is not root-owned or is group- or world-writable. Any
mismatch is ` FAIL` with exit 4 or more.

The record is `<state root>/install/manifest.json` (mode 0600): commit, time,
both digests, and the tracked pin manifest (`scripts/hub/pin-manifest.json`) once
Story 1.2 adds it. The gate-code digest is an input to `policy_version` (AD-19,
Story 2.2).

## Stores (AD-7)

One directory per store under the state root, owned by its only writer. Mode is
0700, or 0750 where another identity must read it, through the group.

| Store | Owner (writer) | Group | Mode | Readers |
|---|---|---|---|---|
| `gate-policy` | operator (`lane2 policy update`) | `lane2-gate` | 0750 | gate |
| `gate-store` | `lane2-gate` | `lane2-gate` | 0700 | gate (`lane2 review` access arrives with Story 2.4) |
| `operator-log` | `lane2-gate` | operator | 0750 | notifier, review, health |
| `events` | operator (supervisor, `lane2` commands) | operator | 0700 | notifier, health |
| `sessions` | operator (supervisor) | `lane2-gate` | 0750 | gate, health, review |
| `workspaces` | operator (`lane2` commands) | operator | 0700 | supervisor, push, relay, health, rescan |
| `exclusions` | operator (`lane2 review`) | `lane2-gate` | 0750 | gate |
| `eval` | operator | operator | 0700 | eval harness ([SP1A_EVAL_SET.md](SP1A_EVAL_SET.md)) |
| `fleet` | operator | operator | 0700 | parallel-verify records ([SP1A_FLEET.md](SP1A_FLEET.md)) |
| `push` | operator (push step) | operator | 0700 | push step |
| `install` | root | root | 0700 | `lane2 install` (bare clone, record, unit list) |

`lane2 install` creates a missing store with exactly this owner, group, and mode.
An existing store with anything else fails the install, naming the store. It
never runs `chmod` or `chown` on an existing store: fix it by hand, on purpose.

## Service identities

| Identity | Runs |
|---|---|
| `lane2-gate` | the gate (Story 2.3) |
| `lane2-fleet-orchestrator` | the orchestrator model unit (Story 1.2) |
| `lane2-fleet-classifier` | the classifier model unit (Story 1.2) |

Each is a system account with no home and no login shell, distinct from each
other and from the operator. The gate can read the policy checkout and write only
the gate store and the operator log. The supervisor and push step run as the
operator; the notifier is an operator user unit (Story 2.4).

## Units and boot

Units live in `scripts/hub/units/` (see its README for placeholders and the lint
rules) and are rendered only from the installed tree. Each service runs as a
non-root `User=` with `NoNewPrivileges`, `ProtectSystem=strict`, `ProtectHome`,
`PrivateTmp`, and core dumps off; no unit may reference a home or workspace path.

Only the gate sockets (`gate-*.socket`), the fleet units (`fleet-*.service`), and
the notifier (`lane2-notify.service`) are enabled at boot, each with
`Restart=on-failure`. A unit not on that list that has an `[Install]` section
fails the lint. No supervisor, Lane 2 container, or session starts at boot.

## Tests

- `scripts/tests/test-lane2-install.sh` (tier `ci`): a local bare-repo fixture
  covers each refusal, dirty-checkout isolation, store creation and wrong-owner
  or loose-mode refusal, unit lint, the boot set, upgrade, rollback, the keep
  count, failed installs, and `--verify`.
- `scripts/tests/test-lane2-install-hub.sh` (tier `hub`): a real install as root
  on the hub, then identities, stores, units, and unit start.
  `sudo LANE2_HUB_TEST=1 LANE2_HUB_TEST_COMMIT=<commit> bash scripts/tests/test-lane2-install-hub.sh`.
  Elsewhere it skips.

## Limits

- The CI suite replaces root, `chown`, account creation, and uid lookup; only the
  hub suite proves the real owners and identities.
- Refusing inside a container is defence in depth; the boundary is that no
  container ever runs as root on the hub.
- Until Story 1.2 ships units in `scripts/hub/units/`, an install renders none.
