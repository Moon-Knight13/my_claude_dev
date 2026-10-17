# SP1a eval harness — run the eval, read the report, publish a record

The eval harness scores the sensitivity check against your eval set
([SP1A_EVAL_SET.md](SP1A_EVAL_SET.md)) and tells you its real miss rate and
false-block rate. It reports what the numbers can support and no more:

- Every rate comes with its case count and a 95% upper bound.
- A case the check could not score is shown as an error. It is never counted as
  caught or missed.
- Every run writes a complete record, so you can repeat it. The record stays on
  the hub. You can publish a scrubbed copy.

The tool is `scripts/hub/eval-harness.sh`. It runs on the hub only, as the
operator, and scores **through the gate**: it asks the gate's `eval` op, the
same decision core production uses, and never calls the floor or the model
itself (AD-1).

## Commands

```bash
scripts/hub/eval-harness.sh run --split tuning     # score the tuning split
scripts/hub/eval-harness.sh run --split heldout    # score the held-out split
scripts/hub/eval-harness.sh publish <record>       # print a scrubbed copy of a record
scripts/hub/eval-harness.sh compare <direct> <gate> # per-case differences, direct path vs gate
scripts/hub/eval-harness.sh latency [--runs N] [--cold]  # gate latency at 1k, 5k, 20k tokens
```

Pass `--config-dir DIR` before the command to use a config directory other
than `/etc/lane2`.

Before it scores anything, `run` checks that the held-out split matches its
freeze record (`eval-set.sh frozen-check`). It checks this for both splits. If
there is no freeze record, or the held-out split changed after it was frozen,
the run stops with exit 3 and reports nothing.

## The report

A run prints aggregates only. Case text, case ids, and verdicts for single
cases never go to the terminal. They are only in the record on the hub.

The report has three rows. Each row scores the same cases a different way:

| Row | A sensitive case counts as caught when |
|---|---|
| `floor-only` | The term-list floor matches a term in it. |
| `classifier-only` | The local classifier answers `sensitive`. |
| `combined` | The floor matches **or** the classifier answers `sensitive`. This is how the gate decides. |

For each row, there is one line per category and an `all` line:

| Column | Meaning |
|---|---|
| `n` | Sensitive cases in the category that this row could score. Errors are not included. |
| `misses` | Scored sensitive cases this row let through. |
| `miss rate` | `misses / n`. `n/a` when `n` is 0. |
| `95% upper` | The one-sided 95% Clopper-Pearson upper bound on the miss rate. |
| `errors` | Cases this row could not score. |

The report header names the bound method. The bound is the honest number.
With few cases, a miss rate of 0% says little. With 0 misses out of 29 cases,
the upper bound is 9.82%. With 0 misses out of 59, it is 4.96%. The harness
rounds the bound **up** to two decimals, so it never looks better than it is.
[SP1A_EVAL_SET.md](SP1A_EVAL_SET.md#how-many-held-out-cases-you-need) shows
how many held-out cases a target bound needs.

Each row also has a false-block line for **hard negatives**: non-sensitive cases
that look sensitive. It shows the number of hard negatives scored (`n`), how
many the row blocked, the false-block rate, its 95% upper bound, the errors,
and your ceiling from `LANE2_EVAL_FALSE_BLOCK_CEILING` beside it. A check that
blocks everything has a perfect miss rate and is useless. This line is how you
see that (SM-C1).

The report ends with status lines:

- `  !!  N case(s) in the errors bucket`: some cases could not be scored.
  Selection (FR-37) needs a run with zero errors.
- `  OK  ` or `  !!  ` for the combined `all` upper bound against your target
  (`LANE2_EVAL_MISS_BOUND`, the SM-2 bound).
- `  OK  ` or `  !!  ` for the combined false-block rate against your ceiling.

The run exits 0 when it completes, whatever the numbers. Read the status lines.

### The errors bucket

A case goes into `errors` for a row when that row could not score it:

| Cause | Rows with an error |
|---|---|
| The gate's classifier layer faulted on the case (endpoint unhealthy, context does not fit, malformed reply, timeout). | `classifier-only`, `combined` |
| The gate did not answer a batch, or answered it malformed. | all three, for every case in the batch |
| The case has no text, is over `GATE_MAX_REQUEST`, or is not UTF-8 text. | all three |

If the gate cannot load its policy (missing or empty term list or prompt) or
does not answer at all before the first case, the run stops with exit 4 and
writes no record: the record would have no `policy_version`.

A missing term list is never "no hit". The Lane 1 floor treats a missing list
as "floor off". The gate does not (AD-1).

`combined` is an error when either layer is an error, even when the other layer
blocked. Errors are never counted as a catch or a miss, so they never make a
bound look better or worse than the scored cases support.

## Held-out runs are logged

Every held-out run that passes the freeze check adds one line to
`heldout-runs.jsonl` in the eval store: the time, the held-out digest, and the
run id. It is written before any case is scored. Each run shows the classifier
the held-out split, so the log tells you how often that happened. A refused run
is not logged, because it showed nothing.

## Records

Each completed run writes `record-<time>-<random>.json` to the eval store,
mode 0600. The eval store is hub-only and never mounted into a container
(AD-7). A record holds:

| Field | What it is |
|---|---|
| `path` | `gate: hub-socket eval op, …`, or `direct (Epic 1): …` for an `eval-direct.sh` record. |
| `policy_version` | The policy store's recorded `policy_version`, confirmed by the gate on every batch (a mismatch stops the run) (AD-19). Hub only: `publish` drops it. |
| `model_sha256` | The classifier model file checksum (`FLEET_CLASSIFIER_SHA256`). |
| `prompt_sha256` | Checksum of the classifier prompt the gate used (the policy checkout's), reported by the gate. |
| `settings_sha256` | Checksum of the production classifier settings file, reported by the gate. |
| `effective_settings_sha256` | Checksum of the settings actually sent. Through the gate, the production file. |
| `fixture_digest` | Digest of the scored split, computed the way `eval-set.sh freeze` computes it. For the held-out split, it equals the freeze digest. |
| `runtime.build`, `runtime.binary_sha256` | The `llama-server` build tag and the checksum of its binary. |
| `gpu.model`, `gpu.pci_id` | The RADV device name and PCI id. |
| `driver.name`, `driver.version` | The kernel GPU driver. An in-tree driver is recorded as `in-tree <kernel version>`. |
| `mesa_version`, `kernel_version` | Mesa from the RADV driver info, and the kernel release. |
| `cache_mode` | `cache_prompt_false` or `np1` (see below). |
| `host` | Hostname, user, and home directory. These are kept so `publish` can scrub them by value. |
| `aggregates` | Everything the report shows, as numbers. |
| `cases` | One row per case: id, category, label, hard-negative flag, and the result of each row. No case text. |

The harness collects every field before it scores a case. If any field is
missing or empty, the run stops with exit 4, names the field, writes no record,
and reports nothing (SM-8). It checks the finished record again before writing
it.

### Cache mode

The eval must call the classifier the way production does, or it measures
something else (AD-10). Through the gate it does: the gate calls `fleet_call`
with the production settings file, `scripts/hub/fleet/classifier.settings.json`,
which sets `cache_prompt: false`. The record's `cache_mode` is
`cache_prompt_false`. If production ever turns prompt caching on, a gate run
stops with exit 4 rather than record a cached run as uncached.

`LANE2_EVAL_CACHE_MODE=np1` (a `-np 1` instance) belongs to the Epic 1 direct
path only; a gate run refuses it with exit 4.

## Publishing a record## Publishing a record

```bash
scripts/hub/eval-harness.sh publish /var/lib/lane2/eval/record-<...>.json > published.json
```

`publish` prints JSON you can share. It copies only an allowlist of fields and
checks each against its format:

- **Kept:** checksums, the runtime build tag, versions (numbers only; a kernel
  suffix such as `-generic` is dropped), the GPU model class and PCI id, the
  driver name, the cache mode, the split, the time, and every aggregate.
- **Dropped:** per-case rows, case ids, host fields, paths, `policy_version`
  (a term-list derivative that never leaves the hub), and any field it does
  not know.
- **Scrubbed from the GPU model name**, the only free text kept: the hostname,
  user name, and home directory (from the record and from the host running
  `publish`), home paths, IPv4, IPv6, and MAC addresses, and serial-like tokens
  (8 or more letters and digits mixed). A value that does not match its
  expected format is replaced with `redacted`.

A test plants each identifier type in a synthetic record, in kept and dropped
fields, and checks that none survives.

## Configuration

`run` reads `<config dir>/lane2.conf`, `fleet.conf`, and `gate.conf`. All are
parsed, never sourced, and the last assignment of a key wins. Nothing is read
from the environment.

| Key (in `lane2.conf`) | Default | Meaning |
|---|---|---|
| `LANE2_STATE_ROOT` | `/var/lib/lane2` | Hub state root; the eval store is its `eval/` subdirectory and manifests go to `manifests/`. |
| `LANE2_EVAL_FALSE_BLOCK_CEILING` | not set | Your false-block ceiling in percent, shown beside each false-block rate. |
| `LANE2_EVAL_MISS_BOUND` | `10` | The target for the combined upper bound (shared with `eval-set.sh`). |
| `LANE2_EVAL_CACHE_MODE` | `cache_prompt_false` | Through the gate, only `cache_prompt_false`. |
| `LANE2_EVAL_COLD_UNITS` | `fleet-classifier.service` | Units `latency --cold` restarts before each cold run. |
| `LANE2_EVAL_TERM_LIST`, `LANE2_EVAL_CLASSIFIER_PROMPT` | — | The direct path (`eval-direct.sh`) only. |

| Key (in `gate.conf`) | Default | Meaning |
|---|---|---|
| `GATE_HUB_SOCKET` | `/run/lane2/gate/hub.sock` | The gate's hub socket. |
| `GATE_EVAL_BUDGET` | `600` | Seconds one bulk eval request may take, at most 9000 ([SP1A_GATE.md](SP1A_GATE.md)). |
| `GATE_DEADLINE`, `GATE_SHIM_TIMEOUT` | `25`, `28` | Used by `latency`: the deadline it reports against, and the client timeout. |

| Key (in `fleet.conf`) | Meaning |
|---|---|
| `FLEET_CLASSIFIER_MODEL` | The classifier alias, for the record ([SP1A_FLEET.md](SP1A_FLEET.md)). |
| `FLEET_CLASSIFIER_SHA256` | The classifier model file sha256. Required for the record. |
| `FLEET_RUNTIME_BUILD` | The `llama-server` build tag: `vX.Y.Z` or `bNNNN`. Required for the record. |
| `FLEET_RUNTIME_BINARY` | Absolute path to the `llama-server` binary; the harness records its sha256. Required for the record. |

The GPU model, driver, Mesa version, and kernel version come from the same
probes as the hardware check ([SP1A_HARDWARE_CHECK.md](SP1A_HARDWARE_CHECK.md)).
A run on a host without a RADV device stops with exit 4, because the record
would be incomplete.

## How it reaches the floor and the classifier

Only through the gate (AD-1, AD-20). For each batch of up to 1000 cases, the
harness writes the case texts into a fresh manifest directory under
`<state root>/manifests/` (group-readable by the gate), sends one bulk `eval`
request with layers `floor` and `classifier` on the hub socket through
`gate_client`, and builds the three rows from the per-layer result of each case.
The request is bounded by `GATE_EVAL_BUDGET`. Manifest directories are removed
when the batch is done. The run's `policy_version` and prompt checksum come from
the policy store's record (`gate-policy/state.json`, written by `lane2 policy
update` and `lane2 install`); every bulk request states that `policy_version`
and the gate refuses a mismatch (`fault:policy`), so the record names the policy
the gate really used without the gate ever returning it (Story 2.5). Before any
case, an empty manifest checks it and reads the public settings checksum.

The harness never loads the term list or the classifier prompt, and never calls
a model. `scripts/tests/test-eval-via-gate.sh` lints it: a direct floor or model
call, a reference to the sensitivity libs, or the term list or prompt path
fails the test. It never reads or writes a verdict cache (AD-19); it writes
only the eval store and its own manifests.

### Switching from the direct path

The Epic 1 direct path is kept, as `scripts/hub/eval-direct.sh`, only until the
switch is proven on the hub (FR-18, NFR-3):

1. Point `LANE2_EVAL_TERM_LIST` and `LANE2_EVAL_CLASSIFIER_PROMPT` at the policy
   checkout's `term-list.txt` and `classifier-prompt.md`.
2. Score the same frozen tuning split both ways:

   ```bash
   scripts/hub/eval-direct.sh run --split tuning
   scripts/hub/eval-harness.sh run --split tuning
   scripts/hub/eval-harness.sh compare <direct record> <gate record>
   ```

`compare` refuses records that differ in split, fixture digest, model, prompt,
settings, runtime, cache mode, or `policy_version`. The direct record takes
the `policy_version` that `lane2 policy update` recorded, and only when its term
list and prompt are byte-identical to the policy checkout's (else null). Equal
values with the gate's therefore prove the same term list, prompt, model,
runtime, and gate code. It then counts per-case differences for every row,
writes `compare-<time>.json` (0600, hub only), and exits 0 when there are none.
Any difference is reported as a count, exits 3, and blocks the switch.
`eval-direct.sh` is deleted in the PR that cites a compare record with zero
differences.

### Latency through the gate

```bash
scripts/hub/eval-harness.sh latency --runs 20 --cold
```

Re-runs the bake-off latency step end to end through the hub socket: synthetic
plain text of about 1k, 5k, and 20k tokens (three words per four tokens), each
sent `--runs` times as an `eval` request with both layers. Warm runs follow one
uncounted request; with `--cold`, each run follows a restart of
`LANE2_EVAL_COLD_UNITS` and waits for the classifier's `/health`. It writes
`latency-<time>.json` (0600, hub only) with p50, p95, and max per size and mode
(nearest rank), the fault count, and three checks: NFR-1 p50 under 5 s at 1k,
NFR-1 p95 under 30 s at 20k, and p95 at 20k within `GATE_DEADLINE`. A check that
fails, or any fault in its runs, is ` FAIL ` in the record and on stdout. Cold
runs need permission to restart the units (root, or a sudo or polkit rule).

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Run completed and the record was written, or `publish` printed the scrubbed record. |
| 2 | Usage error. |
| 3 | Refused: no freeze record, or the held-out split changed since it was frozen. Nothing reported. Or `compare` found a difference. |
| ≥ 4 | Fault: inside a container, store missing or loose, bad config, incomplete record, unreadable record. |

## Tests

`scripts/tests/test-eval-via-gate.sh` (tier `ci`) runs the harness against the
real gate handler behind a real unix socket, with the `llama-server` mock as the
classifier: the three rows from the gate's per-layer results, the record format
(unchanged apart from `policy_version`, which must be the gate's), the
`publish` scrub of `policy_version`, batches, the bulk budget, the gate's
manifest checks, a gate that does not answer reaching no layer, the lint,
`compare` (identical, a difference count, not comparable), and the latency
record with its ` FAIL ` on a 20k p95 over the gate deadline.

`scripts/tests/test-eval-harness.sh` (tier `ci`) covers what both paths share,
through `eval-direct.sh`: the Clopper-Pearson bound at known points and against
the sizing table, per-category counts, the errors bucket, held-out digest
refusal and the run log, record completeness, the request body against
production, the publish scrub, and refusal inside a container.

`scripts/tests/test-lane2-health-hub.sh` (tier `hub`) runs the latency step on
the real hub.

## Limits

- **The direct path still exists.** Until a hub compare record shows zero
  differences, `eval-direct.sh` remains and reaches the floor and the model
  directly. Nothing else uses it.
- **Token sizes are approximate.** The latency inputs are sized by words, not by
  the model's tokenizer.
- **The `-np 1` instance is trusted as configured.** In `np1` mode (direct path
  only), the harness checks the alias but does not ask the server how many
  slots it has.
- **The scrub handles known identifier types.** It cannot recognise every
  possible identifier in free text, so only one free-text field (the GPU model
  name) is kept, and everything else is an allowlist of checked formats. Read a
  published record before you share it.
- **Rates describe your eval set.** A low upper bound says the check catches
  cases like yours. It says nothing about kinds of content your set does not
  contain.
