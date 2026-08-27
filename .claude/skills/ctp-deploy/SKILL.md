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

**The team suffix is a hard boundary.** Range hosts carry a team suffix
(`..._t02`). Only the **authorised team** (`CTP_ALLOWED_TEAM`) is for dev/test;
other `_tNN` are live teams. The bridge refuses any mutating target that is not in
the authorised team, in code — but treat it as a real boundary, not a safety net:
never try to reach another team's host. A deploy to the wrong team is an outage
for someone else.

## The only way to run ctp

Run **`ctp-bridge <args...>`** — the wrapper installed at user scope on the box
(`~/.local/bin/ctp-bridge`; `scripts/ctp-bridge.sh` in this repo before install).
It works from anywhere, including the range checkout where the work happens. Never
`docker exec` into the container and never a bare `ctp` — a `PreToolUse` hook
(installed into `~/.claude/`) denies both, because the bridge is where every gate
lives. Reachable verbs:

- `host deploy <box>` — full deploy of the box (mutating; team + box gated).
- `host deploy-role <box>` — redeploy just the role; the quicker iteration path
  when only the box's content/config changed, not its base (mutating; gated).
- `host list <box>` — read-only; use it to confirm a box resolves before you act.
- `project update-inventory` — regenerate ctp's inventory from Providentia. Run it
  after creating a box on Providentia, or the box will not appear in ctp.

`host vars`, `redeploy`, `remove` are not reachable; `secrets` and `make` are
refused outright. **Every** run is confirmed by the operator — policy, not a bug to
route around. Do not pass `--yes` or set `ASSUME_YES`; the gate refuses them.

## The developer loop

1. Make the box on Providentia (outside ctp).
2. `project update-inventory` — so ctp learns the new box. Without this, the next
   step finds nothing.
3. `host list <box>` — confirm it resolves, and that the name carries the
   authorised team suffix.
4. Write/adjust the playbooks and role content as ordinary files (no bridge
   needed — this is where most of the work is).
5. First stand-up: `host deploy <box>`.
6. Iterate content: edit files, then `host deploy-role <box>` — faster than a full
   deploy because it reapplies the role only.
7. Repeat 6. Reach for a full `deploy` again only if the base box itself is wrong.

## The deployment model — read a failure by its stage

A ctp deploy runs a fixed 12-step tree (per the vendor docs). Knowing which step
failed tells you what owns the failure and whether a `deploy-role` re-run helps:

1. variable loading · 2. deploy_vars (catapult defaults) · 3. machine_operations
(VM create on vSphere/Providentia) · 4. configure_networking · 5. connection (SSH
setup) · 6. accounts · 7. os_configuration · 8. customization_pre_vm_role ·
9. **customization** (the app/role config — what you iterate) · 10.
customization_post_vm_role · 11. finalize (test/cleanup) · 12. get_ip.

Steps 1–8 are catapult building the box; step 9 is *your* role content; 10–12
finish it. A failure in 1–7 is usually infrastructure (VM, network, SSH) — not
your playbook, and not something to fix by editing the role. A failure at step 9
is your content: fix the failing task and `deploy-role` again. `deploy-role`
reapplies the role (roughly step 9) without rebuilding the box, so it only helps
for step-9 failures.

## Reading a result instead of guessing

The bridge returns the **real ctp exit status**. On failure, map the output to the
step above before changing anything:

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
