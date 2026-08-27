---
name: ctp-deploy
description: Use when deploying or iterating a box on the authorized range with the build tooling (ctp) — how to run it through the bridge, and how to read a deploy result instead of guessing.
---

# Deploying a box through the ctp bridge

## Scope this operates in

Work is confined to **one authorized range**, on boxes the organisation owns, for
training and authorized security-testing. The bridge targets a **single
configured box** (`.ctp-bridge.conf`), not the range. If a task needs a different
box, that is a config change the owner makes — not something to work around.

## The only way to run ctp

Run **`scripts/ctp-bridge.sh host <verb> <box>`**. Never `docker exec` into the
container and never a bare `ctp` — a `PreToolUse` hook denies both, because the
bridge is where every gate lives. Reachable verbs in this slice:

- `host deploy <box>` — full deploy of the box.
- `host deploy-role <box>` — redeploy just the role; the quicker iteration path
  when only the box's content/config changed, not its base.

Everything else (`list`, `vars`, `redeploy`, `remove`, `secrets`, `make`) is
refused here. Each run is confirmed by the operator — that is policy, not a bug
to route around. Do not pass `--yes` or set `ASSUME_YES`; the gate refuses them.

## The developer loop

1. Write/adjust the playbooks and role content as ordinary files (no bridge
   needed — this is where most of the work is).
2. First stand-up: `host deploy <box>`.
3. Iterate content: edit files, then `host deploy-role <box>` — faster than a
   full deploy because it reapplies the role only.
4. Repeat 3. Reach for a full `deploy` again only if the base box itself is wrong.

## Reading a result instead of guessing

The bridge returns the **real ctp exit status**. On failure, read the streamed
output for which stage failed before changing anything:

- **Connectivity / SSH stage** — the box is unreachable or its IP clashed. This
  is not a playbook bug; a full redeploy of the box is the vendor's remedy for a
  stuck-on-SSH box, and that is `redeploy` — **out of this slice**, so stop and
  hand back to the operator rather than escalating verbs yourself.
- **Role / task stage** — a specific Ansible task failed. This *is* a
  content/playbook bug. Fix the failing task, then `deploy-role` again. Name the
  failing task and file when you report; do not blind-retry.
- **Vault locked** — the bridge refuses before running and says to run
  `make start`. That is an owner step (credential entry); surface it, do not
  attempt it.

A half-finished deploy leaves the box in an unknown state. Do not assume a retry
is safe — inspect what the failing stage owns first, fix at that layer, then
re-run the single role.

## What never goes in the repo or the transcript

Box detail, range topology, credentials, vault contents. The hook blocks reads of
secret paths; keep it that way — never work around it to inspect a key, `.env`, or
the vault file. On a shared box the next occupant can read this transcript.
