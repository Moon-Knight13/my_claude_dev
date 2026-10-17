# SP1a gate

The gate is the hub's one sensitivity decision core (AD-1). Every sensitivity
check asks it, over a fixed protocol, and it answers **allow** or **block** —
never edited content. Landed so far: the gate's **policy** (Story 2.2) and the
**gate service on the hub socket** (Story 2.3), and its **`health` op and bulk
`eval`** (Story 2.6). The per-session container sockets, the cache, and the
operator log follow in later stories.

## The gate service

`gate-hub.socket` listens on `/run/lane2/gate/hub.sock` with `Accept=yes`:
systemd starts one `gate-handler` per connection (`gate-hub@.service`) as
`lane2-gate`, with `PrivateTmp`, a 0700 runtime directory, `NoNewPrivileges`,
`ProtectSystem=strict`, `ProtectHome`, and core dumps off. Both units are
installed by `lane2 install`; the socket starts at boot.

**Peers.** The handler reads the connecting process's uid from the socket
(`SO_PEERCRED`). Only the operator and the hub service identities are served;
anyone else gets `block` (`fault:peer`). The socket file is world-connectable on
purpose — the uid check is the control.

### Protocol v1

One request per connection:

1. one header line, at most 4096 bytes: `{"v":1,"op":"eval","layers":["floor","classifier"]}`
2. the payload: raw bytes until the client half-closes, at most `GATE_MAX_REQUEST`
3. one answer line, then the connection closes:
   - `{"v":1,"verdict":"allow"}`
   - `{"v":1,"verdict":"block","ref":"gr-<32 hex>"}`

On this hub socket the answer also carries `detail`: the reason and per-layer
results. Container sockets (later) never carry `detail`.

| Op on the hub socket | Now |
|---|---|
| `eval` | Implemented: runs each requested layer, reports each; no cache, no log. With a `manifest`, a bulk eval (below) |
| `health` | Implemented: runs the operator's two probes (below); no cache, no retained payload, no log |
| `mount_scan` | Implemented (Story 3.2): the floor over every item of a hub-produced workspace manifest; a hit is a block with the hit detail retained ([SP1A_WORKSPACE_SEPARATION.md](SP1A_WORKSPACE_SEPARATION.md#the-mount-scan)) |
| `push`, `git_text`, `rescan` | `block` (`fault:protocol`) until their stories add them |
| `prompt`, `expansion`, `tool_input`, `tool_result` | `block` (`fault:protocol`): container ops, never on the hub socket |

A malformed header, a missing or unknown `v`, an unknown op, an extra header
field, a header without a newline or over 4096 bytes: `block` (`fault:protocol`).
A payload over `GATE_MAX_REQUEST` is `fault:oversize` and is never truncated. A
payload that is not valid UTF-8 or contains a NUL byte is `fault:non-text`,
decided by the gate and never transcoded.

### Floor OR classifier

1. **Floor:** the policy's term list, matched case-insensitively at word
   boundaries (`gate_floor_match`). A hit blocks with `hit:floor`; the
   classifier is not called. The answer never says which term matched.
   The floor also catches a term that is disguised (Story 2.7):
   - **case, whitespace, separators:** up to three whitespace or separator
     characters (`. _ - / | : * + ~ , ;` and the like) between a term's letters
     still match — `Z z-A.l p h a` is `zzalpha`; the term's own separators are
     optional the same way (`acme corp`, `ACME_CORP`, `acmecorp` all match
     `acme-corp`); a term broken across lines matches too;
   - **encodings:** base64 (standard and URL-safe), URL percent-encoding (and `+`
     as space), and hex (`7a7a…`, `0x7a7a…`, `\x7a\x7a…`) are decoded, two
     levels deep (so base64 of URL-encoded text is caught), and the decoded text
     is checked as well.

   The original text is always checked: a decode error never becomes an allow.
   Matching stays word-bounded, so `zzalphabet` is not `zzalpha`. One known
   trade-off: spaced letters hide word boundaries, so `z z a l p h a b e t`
   blocks — a false block, never a leak. Decoding is bounded to four times the
   request plus 64 KiB of decoded text.
2. **Classifier:** only on a clear floor. The call goes only through
   `fleet_call` to the classifier member's loopback endpoint with the pinned
   settings file, and its request body is the production one
   (`classify-sensitivity.sh`). `sensitive` blocks with `hit:classifier`. The
   classifier input carries nothing from the floor result, and a clear floor
   never turns a `sensitive` into allow.

### Chunked classification

Content too long for the classifier's context is classified in pieces, by the
decision core only (callers never split): chunks of `GATE_CHUNK_CHARS`
characters (default 24000, about 6k tokens), each overlapping the next by
`GATE_CHUNK_OVERLAP` (default 400) so a phrase on a boundary is seen whole. Every
chunk goes through `fleet_call`; any `sensitive` chunk blocks with
`hit:classifier`, any faulted chunk blocks with that fault (a chunk that still
does not fit is `fault:oversize`). The floor always runs on the whole text.

More chunks than `GATE_CHUNK_BUDGET` (default 8, about 190k characters) blocks
with `fault:timeout` before any classifier call, so the caller's deadline is
never spent waiting. Content over `GATE_MAX_REQUEST` is still `fault:oversize`
and never chunked. Invalid chunk settings stop the gate. `eval`, bulk `eval`,
and `health` chunk exactly as production does.

`scripts/tests/test-gate-chunking-hub.sh` (tier `hub`) checks that p95 for a
~20k-token request stays inside `GATE_DEADLINE` on the real classifier.

To record the obfuscated and buried-in-long-context categories on the hub, run
the eval set through the gate as usual (`scripts/hub/eval-harness.sh run --split
tuning`, [SP1A_EVAL_HARNESS.md](SP1A_EVAL_HARNESS.md)); the floor-only row now
counts obfuscated cases caught by normalisation.

### The `health` op

Header `{"v":1,"op":"health"}` and no payload (any other field, or a payload, is
`fault:protocol`). The gate loads its policy strictly and computes
`policy_version` as for any request, then runs two probes from the policy
checkout, `health-probe-sensitive.txt` and `health-probe-negative.txt`, through
the same floor and classifier:

- the sensitive probe must be blocked **by the classifier**; the negative probe
  must be allowed;
- a probe that hits the floor is a failure (`hits-floor`), so the floor alone
  can never pass health;
- the answer is `allow` when both pass, else `block` with `detail.probes`
  (`ok`, `hits-floor`, `missing`, `non-text`, `classifier-fault`, `oversize`, or
  `wrong-verdict` for each) and reason `fault:classifier` or `fault:policy`.

Nothing in the answer names a term or quotes a probe. `lane2 health` asks this op
([SP1A_HUB_SETUP.md](SP1A_HUB_SETUP.md#health)).

### Bulk `eval` with a manifest

The eval harness sends its cases as one bulk request (AD-20):
`{"v":1,"op":"eval","layers":["floor","classifier"],"manifest":"<dir>","policy_version":"<hex>"}`
with no payload. The caller states the `policy_version` it expects (the one
`lane2 policy update` / `lane2 install` recorded); a different or missing one is
a block (`fault:policy` or `fault:protocol`). The gate never sends its own back. The manifest directory must be directly under
`<state root>/manifests/` (store `manifests`, operator-owned, group
`lane2-gate`, 2750), a real directory, and hold only regular files named
`000001`, `000002`, … with no gap, at most 1500. A symlink, a gap, a foreign
file, a path elsewhere, or a payload is `fault:protocol`. The gate reads the
files under its own identity and never reads a workspace.

Each case gets every requested layer, reported on its own, as two characters in
`detail.cases` (floor, then classifier: `h` hit, `c` clear, `e` could not run,
`-` not requested). A case that is empty, over `GATE_MAX_REQUEST`, or not text
is `e`. `detail.inputs` names only the public settings file's checksum and
whether it caches prompts. A bulk eval is bounded by `GATE_EVAL_BUDGET`, not
`GATE_DEADLINE`; it writes no cache entry and no operator log line.

### Verdict cache

The decision core reuses an allow under the policy it was made under (AD-19):

- **Key:** `sha256(normalised content) ‖ policy_version ‖ layer set`. Normalised:
  line endings as LF, trailing newlines removed; nothing else.
- **What is cached:** only `allow` under the `full` layer set. A block is never
  cached. A floor-only session neither reads nor writes the cache, so a floor-only
  allow can never serve a full request. A hit returns allow without a classifier
  call; the floor still runs first.
- **Never cached:** `eval` and `health` set the one bypass flag
  (`GATE_CACHE_BYPASS`); the classifier is called for every item.
- **Invalidation:** a new `policy_version` (new term list, prompt, model, runtime,
  or gate code) is a new key; on the next lookup every entry under an earlier one
  is purged.
- **Faults:** a corrupt or unreadable cache, or a lock wait over 2 s, is
  `fault:store` — never a miss that could turn into an allow. The cache
  (`gate-store/cache.jsonl`, 0600) holds hashes only and is written only by the
  gate, under `flock`.

The service ops that use the cache (`prompt`, `tool_input`, …) arrive with the
per-session sockets in Epic 4; on the hub socket today only `eval` and `health`
are served, and both bypass it.

### Rate limit and probe budget

Per hub-socket peer (by peer uid), per window (`/etc/lane2/gate.conf`):

```bash
GATE_RATE_LIMIT=600     # requests per window
GATE_RATE_WINDOW=60     # seconds
GATE_PROBE_BUDGET=100   # blocks per window
```

A peer over either limit gets `block` with category `probe` for every request
until its window ends; each is an operator log line, and the notifier raises a
critical (coalesced) alert. Counters live in `gate-store/counters/<uid>` under
`flock`; corrupt or unreadable counters count as over the limit. Invalid values
stop the gate. Per-session counting and ending a session on a probe come with
Epics 3 and 4, on these counters.

### Query log

`gate-store/query.jsonl` (0600): one metadata line per hub-socket request —
`{time, op, peer_uid, verdict, ref}` (`ref` only on a block). Never content. It
is trimmed to its newest 100000 lines past 8 MiB.

No op or header field looks up a ref, returns the policy, `policy_version`, the
term list, or a listing; every such request blocks (`fault:protocol`).

**Residual (FR-28):** the gate is still an allow/block oracle. A caller allowed
to ask can learn, one request at a time, whether a text is blocked. The rate
limit and probe budget bound how fast; they do not remove it.

### Faults — every one is a block

| Case | Reason |
|---|---|
| Classifier error, loading (503), unavailable, malformed, unparseable, partial, or truncated answer, non-local endpoint | `fault:classifier` |
| Input over `GATE_MAX_REQUEST` or over the classifier context | `fault:oversize` |
| Gate deadline exceeded | `fault:timeout` |
| Gate policy missing, empty, unreadable; a `policy_version` input missing | `fault:policy` |
| Not valid UTF-8, or a NUL byte | `fault:non-text` |
| Bad framing, unknown or unavailable op | `fault:protocol` |
| Peer not the operator or a hub service | `fault:peer` |
| Invalid `GATE_` config | `fault:config` |
| Handler work crashed without an answer | `fault:internal` |
| Retained-payload store full, over the origin's quota, corrupt, unwritable, or locked too long | `fault:store` |
| Handler died or socket missing | no answer — the client blocks |

### Deadlines

`/etc/lane2/gate.conf`:

```bash
GATE_HUB_SOCKET=/run/lane2/gate/hub.sock
GATE_MAX_REQUEST=1048576
GATE_DEADLINE=25        # the gate answers fault:timeout by then
GATE_SHIM_TIMEOUT=28    # callers give up after this
GATE_HOOK_TIMEOUT=30    # Claude Code's hook timeout; must be 30
GATE_EVAL_BUDGET=600    # a bulk eval's budget, seconds (GATE_DEADLINE..9000)
```

`GATE_DEADLINE < GATE_SHIM_TIMEOUT < GATE_HOOK_TIMEOUT = 30`, each margin at
least 2 s, and `GATE_DEADLINE <= GATE_EVAL_BUDGET <= 9000`. The handler runs
every request inside the larger bound and enforces `GATE_DEADLINE` itself on
everything but a bulk eval. `gate-hub.socket` runs `gate-handler --check-config` before it
starts: invalid deadlines stop the gate. A handler that finds them invalid
answers `fault:config`.

### The client rule

Every hub caller uses `gate_client` (`scripts/lib/gate-client.sh`). Only a
well-formed `{"v":1,"verdict":"allow"}` within the caller's deadline is an allow.
Anything else — empty, malformed, oversized, trailing data, timeout, socket
missing, unknown `v` — is a block (exit 3; exit 4 for a local fault, also a
block). A block is never retried into an allow. The input is streamed whole:
never truncated, sampled, or split.

### `lane2 check`

```bash
printf '%s' "text to check" | scripts/hub/lane2 check [--layers floor,classifier]
```

Asks the gate's `eval` op. Prints `OK allow`, or `FAIL block: <reason> (ref gr-…)`,
and each layer's result (`hit`, `clear`, or a fault). Never prints a term. Exit 0
allow, 3 block, 4 local fault. Refuses inside a container. Writes no cache entry
and no log line.

### Tests

- `scripts/tests/test-gate-protocol.sh` and `test-gate-faults.sh` (tier `ci`):
  the real handler behind a real unix socket, the llama-server mock as the
  classifier, synthetic terms — every framing case, every fault above, the
  floor-never-clears test, the body-equality test, the no-sanitiser lint, and
  the client's fail-closed cases.
- `scripts/tests/test-gate-hub.sh` (tier `hub`): real socket activation, the real
  peer check, and the real classifier. `sudo LANE2_HUB_TEST=1 bash scripts/tests/test-gate-hub.sh`.
- `scripts/tests/test-lane2-health.sh` (tier `ci`): the `health` op and
  `lane2 health`. `scripts/tests/test-eval-via-gate.sh` (tier `ci`): the bulk
  eval, its manifest checks, and its budget.

## What a block leaves behind

The caller learns only that it was blocked; the operator learns why
(Story 2.4).

### Opaque verdicts and refs

Every block carries a ref: `gr-` and 32 lowercase hex from 128 random bits,
never derived from content, time, or a counter, and never reused. A container
caller (Epic 4) receives only `v`, `verdict`, and `ref`; inside Claude the
shims show the fixed text from the public pattern file
`scripts/lib/gate-patterns.conf`:

    blocked by gate · ref <ref> · see hub notification

On the hub socket, a block on any op except `eval` and `health` carries
`detail: {"reason_category": …}` and nothing else. `eval` and `health` keep their
per-layer detail and are neither retained nor logged.

### Retained payloads

The blocked payload is kept as a 0600 file named by its ref in
`<state>/gate-store/payloads/` (0700, the gate's only). Nothing writes a payload
anywhere else: not a log, not the journal.

`/etc/lane2/gate.conf`:

```bash
GATE_RETAIN_DAYS=7                 # whole days, 1..30; anything else stops the gate
GATE_STORE_MAX_BYTES=268435456     # total
GATE_QUOTA_OPERATOR_BYTES=67108864 # operator- and hub-origin payloads
GATE_QUOTA_CONTAINER_BYTES=201326592
```

- **Expiry:** the gate purges expired payloads on every connection; an expired
  ref is remembered so review can say "expired".
- **Quotas:** a payload over the total or its origin's quota blocks with
  `fault:store` and writes a log line. Nothing unexpired is evicted to make room,
  and container-origin payloads can never use the operator quota.
- **Atomic:** the bound check and insert happen under one lock; a lock wait over
  2 s, an unreadable or corrupt index, or an unwritable store counts as full.

### Operator log

`<state>/operator-log/gate.jsonl`, one line per block, written only by the gate:

```json
{"time":"…","op":"push","origin":"container","session":null,"reason_category":"fault:protocol","ref":"gr-…"}
```

Every value is the gate's own: an op the gate does not know is logged as
`unknown`, and nothing from the payload or a header field reaches the log.
`session` is filled in when Epic 4 adds sessions.

### Notifications

`lane2-notify` (a user unit for the operator, installed by `lane2 install`)
follows the operator log and the lane2 event log and calls `notify-send` with
fixed text, the category, and the ref, markup-escaped:

- a `hit:*` on a container-origin op is **critical**, sent at once, never coalesced;
- everything else is coalesced per session per `LANE2_NOTIFY_COALESCE` seconds
  (`lane2.conf`, default 60), with a count of what was held;
- a malformed log line is counted and skipped, never shown.

The gate blocks whether or not the notifier runs.

### `lane2 review show <ref>`

```bash
sudo scripts/hub/lane2 review show gr-…
```

Shows the operator log metadata and the retained payload. An unknown ref says
`not found`; an expired one says `expired`. It runs as root (payloads are
readable only by the gate and review), refuses inside a container, and offers no
decisions yet (Epic 4). See the runbook: [Read a block](SP1A_RUNBOOK.md#read-a-block).

## Policy repository

The gate's policy is two files kept in **your private repository**, never in
this public one:

| File | What it is |
|---|---|
| `term-list.txt` | The term floor: one term per line. Matched by code, case-insensitive, on word boundaries. `#` lines and blank lines are ignored. Entries shorter than 3 characters are rejected, not used. |
| `classifier-prompt.md` | The classifier's instructions. Must not be empty. |
| `fixtures/*.gpg`, `fixtures/*.age` | Optional eval fixtures, **encrypted only**. A plaintext fixture (or any `.jsonl`, `.json`, or `.csv`) fails validation. |
| `health-probe-sensitive.txt`, `health-probe-negative.txt` | The health probes (Story 2.6): a text the classifier must block with no term-list hit, and a text the gate must allow. |
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
