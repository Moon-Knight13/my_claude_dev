# SP1a gate

The gate is the hub's one sensitivity decision core (AD-1). Story 2.3 adds the
gate service. This page starts with what has landed: the gate's **policy** and
the rule that the gate never runs without it.

## Policy repository

The gate's policy is two files kept in **your private repository**, never in
this public one:

| File | What it is |
|---|---|
| `term-list.txt` | The term floor: one term per line. Matched by code, case-insensitive, on word boundaries. `#` lines and blank lines are ignored. Entries shorter than 3 characters are rejected, not used. |
| `classifier-prompt.md` | The classifier's instructions. Must not be empty. |
| `fixtures/*.gpg`, `fixtures/*.age` | Optional eval fixtures, **encrypted only**. A plaintext fixture (or any `.jsonl`, `.json`, or `.csv`) fails validation. |
| `README.md`, `.gitignore`, `.gitattributes` | Allowed. Any other file fails validation. |

`scripts/orchestrator/term-list.example.txt` shows the term-list format with
synthetic entries; it is the only term list in this repository.

### Setup

1. Create a private repository with the two files above.
2. Make sure the hub's operator account can fetch it with its own SSH config
   (`ssh -T` to the git host works as the operator).
3. Add to `/etc/lane2/lane2.conf`:

   ```bash
   LANE2_POLICY_REPO=<user>@<git host>:<you>/<policy repo>.git   # or ssh:// or https://
   LANE2_POLICY_BRANCH=main                                      # optional
   ```

   A local path or `file://` URL is refused.

### Update

As the operator, on the hub:

```bash
scripts/hub/lane2 policy update
```

It fetches the branch into a bare clone in the gate policy store (hooks,
fsmonitor, and submodules off), exports the commit into a staging tree,
validates it, and only then swaps `current` to it atomically. It is the only
writer of the policy checkout.

- **Any failure keeps the previous policy in force.** The output is
  ` FAIL <step>: …` naming the failed step (`fetch`, `stage`, `validate`, or
  `swap`), never a term or a prompt line.
- **Short entries** are reported by line number and counted, never quoted:
  `!!  term-list line 5 rejected (under 3 characters); not used`. The count goes
  to the lane2 event log.
- **Removed entries** since the previous policy are counted (never listed) for
  health. The previous tree is kept beside the current one as the comparison
  snapshot; older trees are removed.
- It refuses inside a container and for any account other than the operator.

### Where it lives

`<state root>/gate-policy/` (default `/var/lib/lane2/gate-policy/`): the bare
clone, `trees/<commit>/`, the `current` link, and `state.json` (commit, counts,
`policy_version`). The store is owned by the operator with group `lane2-gate`,
mode 2750, so only the operator and the gate can read it. It is outside every
workspace and outside the install prefix, and is never mounted into a container
(AD-7, FR-48).

## Fault on missing policy

The gate never runs without its policy. The strict loader `gate_policy_load`
(`scripts/lib/gate.sh`), which the gate calls before either layer runs, faults
and loads neither layer when:

- the term list is missing, empty, unreadable, or holds only comments and
  rejected short entries;
- the classifier prompt is missing, empty, or unreadable;
- the caller is neither the operator nor the gate identity.

The gate then blocks every request with `fault:policy`.

`gate_floor_match` is the gate's floor. It reuses `orch_floor_match`'s matching
but never its "missing list means no hit" rule: if the policy is not loaded or
the term list has gone, it faults. `orch_floor_match` keeps the lenient
behaviour for Lane 1 and SP4 callers only. `scripts/tests/test-gate-policy.sh`
tests both side by side.

## policy_version

`policy_version` is one sha256 over, in this fixed order, each input written with
its byte length first:

1. the term list
2. the classifier prompt
3. the classifier model id
4. the classifier model file checksum
5. the runtime build tag
6. the installed gate-code digest

If any input is missing, unreadable, empty, or malformed, the function faults
(exit 4 or more); the gate (Story 2.3) blocks until it succeeds. It is computed
by one function, `gate_policy_version`, called by `lane2 policy update`,
`lane2 install`, and (from Story 2.3) gate start, and by nothing else.

**`policy_version` is itself a term-list derivative and never leaves the hub.**
It is kept in the policy store's `state.json` and the install record. It is never
written to the event log, a tracked file, CI, or a container. The event log
records only that it changed, with counts.

The model inputs come from `/etc/lane2/fleet.conf` (`FLEET_CLASSIFIER_MODEL`,
`FLEET_CLASSIFIER_SHA256`, `FLEET_RUNTIME_BUILD`) and the gate-code digest from
the installed tree. Until those exist, `lane2 policy update` still installs the
policy and says `!!  policy_version not computed: <which input>`.

## Event log

`<state root>/events/policy.jsonl`, metadata only:

| Event | Fields |
|---|---|
| `policy` | `terms`, `rejected`, `removed` (counts); written when `policy_version` changes |
| `policy_terms_rejected` | `count` |

Same content gives the same `policy_version` and no `policy` event.

## Limits

- The removal snapshot is the previous policy tree in the policy store, not the
  gate store: the gate store's only writer is the gate (AD-7), and the operator
  runs the update.
- The store is mode 2750 rather than 0700 so the gate can read what the operator
  writes; nobody else can.
