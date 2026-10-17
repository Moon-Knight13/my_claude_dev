# SP1a workspace separation

The main control in SP1a is that sensitive material is not where Claude can read
it (P5). Claude runs in a Lane 2 container that holds nothing sensitive, built so
that no workspace can change what the container is, and container root is never
hub root. This page covers what has landed: the **image** and the **container
definition** (Story 3.1), and **marking workspaces** with the **mount scan**
(Story 3.2). Starting sessions and network isolation follow in Stories 3.3–3.4.

## Marking workspaces

Only a workspace you mark `mountable` can ever be mounted into Lane 2:

```bash
scripts/hub/lane2 mark <workspace> mountable     # as the operator, on the hub
scripts/hub/lane2 mark <workspace> sensitive
```

- **Unmarked means sensitive.** A workspace with no mark, a corrupt entry, or an
  unreadable store is never mountable; a corrupt or unreadable store is a fault.
  While any entry is corrupt, nothing can be marked `mountable` (the sensitive-path
  check cannot be trusted), until you fix or remove that entry.
- **Marking `sensitive` always succeeds:** it only reduces exposure.
- The mark is recorded against the workspace's canonical real path in the
  `workspaces` store, under a per-workspace lock, with one metadata-only event
  (workspace id and mark, no path) in `events/lane2.jsonl`.
- **Refused paths** (exit 2): missing, not a directory, a symlink, or inside the
  hub state root, the install prefix, or the policy checkout.

`mountable` is also refused (exit 3) when the workspace:

- lies under a work repository root (`LANE2_WORK_REPO_ROOTS`);
- has a remote, nested repository, submodule, or `url.<…>.insteadOf` rewrite
  naming a work git host or a subdomain of one (`LANE2_WORK_GIT_HOSTS`). Git
  config is read as text; no git command runs in the workspace;
- contains, or is contained by, a path marked `sensitive`.

```bash
# /etc/lane2/lane2.conf
LANE2_WORK_GIT_HOSTS=<work git host>[, <another>]
LANE2_WORK_REPO_ROOTS=<path>[, <path>]
```

Every scan repeats these checks, so a work remote or nested repository added after
marking blocks the mount.

## The mount scan

```bash
scripts/hub/lane2 scan <workspace>              # exit 0 clean, 3 blocked (prints the ref), >=4 fault
```

Before any mount, the floor runs over the workspace's **full content and history**:

- every working-tree file — tracked, untracked, and ignored;
- every git object, loose and packed, reachable or not (so deleted files and
  rewritten history are scanned too);
- every ref, packed ref, branch and tag name, the stash, every reflog;
- every commit and tag message (they are objects);
- every instruction file (`CLAUDE.md` at any depth, `.claude/`), and imports they
  name must stay inside the workspace;
- LFS objects, and the workspace's own git config and hooks — as text to scan,
  never used.

**No git command runs inside the workspace.** `.git` is copied as plain files into
a hub-owned scan directory; its config and hooks are scanned and then replaced
with a minimal config; objects are listed there with no system or global config,
an empty `HOME`, and hooks and fsmonitor off. Alternates inside the workspace are
copied too. These are faults (exit 4, never a partial scan):

- a symlink, gitfile, `commondir`, or `objects/info/alternates` that points
  outside the workspace;
- an instruction-file import outside the workspace;
- more files than `LANE2_SCAN_MAX_FILES` (default 50000) or bytes than
  `LANE2_SCAN_MAX_BYTES` (default 512 MiB).

The manifest goes to the gate's `mount_scan` op on the hub socket; the gate reads
it under its own identity, never the workspace, within `GATE_SCAN_BUDGET` seconds
(default 900, in `gate.conf`). Results:

| Result | State | Exit |
|---|---|---|
| clean, every item | `clean` (logged) | 0 |
| a floor hit | `scan-blocked <ref>`; the hit detail (which item, which term as a hash) is a retained payload; an operator log line and notification | 3, prints only the ref |
| a gate fault, budget overrun, or escape | `unscanned` (blocks the mount too) | ≥ 4 |

Only a full clean scan writes `clean`. The mount (Story 3.3) needs `mountable`
and `clean`.

**The scan is floor-only (FR-28).** It catches your listed terms, disguised or
not; it does not judge meaning. Content that is sensitive only by inference is
kept out by marking, not by the scan: leave such a workspace unmarked.

### Exclusions

When a scan hit is not sensitive after all, record an exclusion instead of
deleting the content:

```bash
sudo scripts/hub/lane2 review show gr-…                         # see what hit
sudo scripts/hub/lane2 review exclude gr-… --path tree:docs/a.md [--term <sha256>]
```

An exclusion covers **exactly one item and one term** (give `--term` from the
retained payload when several terms hit that item). It never hides a hit on
another item or another term — the same text in a git object is another item.
Directories, globs, and empty paths are refused. Exclusions are hub-only
(`exclusions/exclusions.jsonl`), written only by `lane2 review`, and apply to
later scans; `lane2 health` lists each by id and item with the count, never the
term. A corrupt exclusion store makes every scan a fault.

## The image

`lane2 install` builds the image on the hub, from the installed commit only:

- The build context is a fresh directory holding the installed tree's
  `scripts/hub/container/Dockerfile` and the managed settings rendered from
  `scripts/hub/integration/managed-settings.base.json`. Never a workspace, never
  the checkout you ran it from.
- The base image and Claude Code version come from `scripts/hub/pin-manifest.json`.
  The base is pulled by digest; Claude Code is installed at exactly the pinned
  version, root-owned.
- The image id, the Claude Code version and binary sha256, and the managed
  settings digest (`integration_digest`) are recorded in the install record.
  Containers are started only by that image id.
- A failed build stops the install before anything swaps: the previous install
  and image stay in force.

### Pinning

| Pin | Rule |
|---|---|
| `container.base_image` + `base_digest` | `node:24` and its `sha256:` digest. Install refuses to build without the digest. |
| `container.claude_code.version` | An exact `X.Y.Z` at or above **2.1.299**, from npm's `latest` dist-tag. A range, the literal `latest`, or the `stable` channel (below the floor) is refused. |

To pin or move the base, on the hub, then commit the digest in a reviewed PR:

```bash
docker pull node:24
docker image inspect --format '{{index .RepoDigests 0}}' node:24   # node@sha256:…
```

Moving Claude Code: change the version in the pin manifest by a merged PR, then
`lane2 install` (AD-23).

Auto-update is off: the image carries `/etc/claude-code/managed-settings.json`
(`autoUpdates: false`, `DISABLE_AUTOUPDATER=1`), root-owned and read-only to the
container user. This file is the seed of the Epic 4 integration policy.

## The container definition

`scripts/hub/container/lane2-container.json` declares how every Lane 2 container
runs; Story 3.3 (`lane2 up`) starts containers only from it. It requires:

- a read-only root filesystem with tmpfs scratch;
- all capabilities dropped and `no-new-privileges`;
- a non-root default user (`node`);
- no `--privileged`, no device, no host PID, user, or network namespace, no
  network at all (`none`), no host-gateway alias, no `LOCAL_MODEL_*` variable;
- only the AD-21 mounts — workspace (rw), host-executed members (ro), integration
  policy (ro), agent-writable settings files (ro), the per-session socket
  directory (ro), the per-workspace Claude config volume (rw) — with sources
  resolved per session, never a fixed host path, and never a container-runtime
  control socket.

`scripts/tests/test-lane2-image.sh` fails on any change that breaks one of these.

## userns-remap

Lane 2 runs on **rootful** Docker with `userns-remap` to a dedicated user: inside
the container uid 0 is an unprivileged host uid that owns no hub store. Setup is
in [SP1A_HUB_SETUP.md](SP1A_HUB_SETUP.md#docker). `lane2 install --verify` checks
it and `lane2 health` reports the result (its `image` line); Story 3.3 refuses
`lane2 up` without it. It fails
when remap is off, the daemon is rootless, the remap user is `default` or shared,
the subordinate range overlaps the operator or a service identity, or a probe
container's root is not inside that range.

## Checks

```bash
sudo scripts/hub/lane2 install --verify
```

reports the image present by its pinned id, the claude binary matching its pin,
`claude --version` at or above 2.1.299, and userns-remap in effect.

## Tests

- `scripts/tests/test-lane2-image.sh` (tier `ci`, stub docker): definition lint,
  runtime-socket and extra-mount refusal, the version floor and the `latest`,
  range, and `stable` refusals, the build and its records, digest checks, and
  every userns-remap failure.
- `scripts/tests/test-lane2-image-hub.sh` (tier `hub`): the real image, its pins,
  the userns probe, and that container root's host uid can read no AD-7 store and
  no runtime socket.
