# SP1a workspace separation

The main control in SP1a is that sensitive material is not where Claude can read
it (P5). Claude runs in a Lane 2 container that holds nothing sensitive, built so
that no workspace can change what the container is, and container root is never
hub root. This page covers what has landed: the **image** and the **container
definition** (Story 3.1). Starting sessions, marking workspaces, and network
isolation follow in Stories 3.2–3.4.

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
