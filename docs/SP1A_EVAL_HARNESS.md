# SP1a eval harness — run the eval, read the report, publish a record

The eval harness scores the sensitivity check against your eval set
([SP1A_EVAL_SET.md](SP1A_EVAL_SET.md)) and tells you its real miss rate and
false-block rate. It reports what the numbers can support and no more:

- Every rate comes with its case count and a 95% upper bound.
- A case the check could not score is shown as an error. It is never counted as
  caught or missed.
- Every run writes a complete record, so you can repeat it. The record stays on
  the hub. You can publish a scrubbed copy.

The tool is `scripts/hub/eval-harness.sh`. It runs on the hub only.

## Commands

```bash
scripts/hub/eval-harness.sh run --split tuning     # score the tuning split
scripts/hub/eval-harness.sh run --split heldout    # score the held-out split
scripts/hub/eval-harness.sh publish <record>       # print a scrubbed copy of a record
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
| The classifier call faulted: `fleet_call` exited with any non-zero code (endpoint unhealthy, context does not fit, malformed reply, timeout). | `classifier-only`, `combined` |
| The term list is missing, empty, unreadable, or has no usable term (3 characters or more). | `floor-only`, `combined` |
| The case has no text. | all three |

A missing term list is an error, never "no hit". The Lane 1 floor treats a
missing list as "floor off". The eval and the gate do not (AD-1). When the term
list is unusable, the report also prints `  !!  term list missing, empty, or
unreadable`.

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
| `model_sha256` | The classifier model file checksum (`FLEET_CLASSIFIER_SHA256`). |
| `prompt_sha256` | Checksum of the classifier system prompt used. |
| `settings_sha256` | Checksum of the production classifier settings file. |
| `effective_settings_sha256` | Checksum of the settings actually sent (see cache mode below). |
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
something else (AD-10). The harness uses `fleet_call` with the production
settings file, `scripts/hub/fleet/classifier.settings.json`. It changes one
thing, chosen by `LANE2_EVAL_CACHE_MODE`:

| Mode | What the harness does |
|---|---|
| `cache_prompt_false` (default) | Calls fleet member `classifier` with the production settings and `cache_prompt` forced to `false`. No other field changes. |
| `np1` | Calls fleet member `evalnp1`, a `llama-server` instance you started with `-np 1` (one slot), with the production settings unchanged. Its alias must equal `FLEET_CLASSIFIER_MODEL`. |

The record says which mode was used. A test proves that the request body is
the same as the production classifier's body, field for field, apart from that
one setting. The production file currently sets `cache_prompt: false` already,
so in the default mode the bodies are identical today. The forced setting
keeps the eval uncached if production turns prompt caching on later.

## Publishing a record

```bash
scripts/hub/eval-harness.sh publish /var/lib/lane2/eval/record-<...>.json > published.json
```

`publish` prints JSON you can share. It copies only an allowlist of fields and
checks each against its format:

- **Kept:** checksums, the runtime build tag, versions (numbers only; a kernel
  suffix such as `-generic` is dropped), the GPU model class and PCI id, the
  driver name, the cache mode, the split, the time, and every aggregate.
- **Dropped:** per-case rows, case ids, host fields, paths, and any field it
  does not know.
- **Scrubbed from the GPU model name**, the only free text kept: the hostname,
  user name, and home directory (from the record and from the host running
  `publish`), home paths, IPv4, IPv6, and MAC addresses, and serial-like tokens
  (8 or more letters and digits mixed). A value that does not match its
  expected format is replaced with `redacted`.

A test plants each identifier type in a synthetic record, in kept and dropped
fields, and checks that none survives.

## Configuration

`run` reads `<config dir>/lane2.conf` and `<config dir>/fleet.conf`. Both are
parsed, never sourced, and the last assignment of a key wins. Nothing is read
from the environment: an `ORCH_TERM_LIST` in your shell is ignored.

| Key (in `lane2.conf`) | Default | Meaning |
|---|---|---|
| `LANE2_STATE_ROOT` | `/var/lib/lane2` | Hub state root; the eval store is its `eval/` subdirectory. |
| `LANE2_EVAL_TERM_LIST` | — | Path to the term list the floor uses. Missing or unusable: every floor result is an error. |
| `LANE2_EVAL_CLASSIFIER_PROMPT` | — (required) | Path to the classifier system prompt. Missing: the run stops with exit 4. |
| `LANE2_EVAL_FALSE_BLOCK_CEILING` | not set | Your false-block ceiling in percent, shown beside each false-block rate. |
| `LANE2_EVAL_MISS_BOUND` | `10` | The target for the combined upper bound (shared with `eval-set.sh`). |
| `LANE2_EVAL_CACHE_MODE` | `cache_prompt_false` | `cache_prompt_false` or `np1`. |

| Key (in `fleet.conf`) | Meaning |
|---|---|
| `FLEET_CLASSIFIER_ENDPOINT`, `FLEET_CLASSIFIER_MODEL` | The classifier member ([SP1A_FLEET.md](SP1A_FLEET.md)). |
| `FLEET_CLASSIFIER_SHA256` | The classifier model file sha256. Required for the record. |
| `FLEET_RUNTIME_BUILD` | The `llama-server` build tag: `vX.Y.Z` or `bNNNN`. Required for the record. |
| `FLEET_RUNTIME_BINARY` | Absolute path to the `llama-server` binary; the harness records its sha256. Required for the record. |
| `FLEET_EVALNP1_ENDPOINT`, `FLEET_EVALNP1_MODEL` | The `-np 1` instance, for `np1` mode only. |

The GPU model, driver, Mesa version, and kernel version come from the same
probes as the hardware check ([SP1A_HARDWARE_CHECK.md](SP1A_HARDWARE_CHECK.md)).
A run on a host without a RADV device stops with exit 4, because the record
would be incomplete.

## How it reaches the floor and the classifier

In Epic 1, the harness calls the floor (`orch_floor_match`) and the classifier
(`fleet_call`) directly, on the hub. It copies the term list and the prompt
into a private temporary directory first, so a file that changes during a run
cannot change half of it.

Epic 2 adds the gate. Story 2.6 then routes the harness through the hub-socket
gate `eval` op (AD-1, AD-20), so the eval measures the same decision core that
production uses. The report and the record format do not change. Until then,
the harness and the gate share the floor function, the settings file, and
`fleet_call`, but not the rest of the gate's code path.

The harness never reads or writes a verdict cache (AD-19). It writes only to
the eval store.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Run completed and the record was written, or `publish` printed the scrubbed record. |
| 2 | Usage error. |
| 3 | Refused: no freeze record, or the held-out split changed since it was frozen. Nothing reported. |
| ≥ 4 | Fault: inside a container, store missing or loose, bad config, incomplete record, unreadable record. |

## Tests

`scripts/tests/test-eval-harness.sh` (tier `ci`) runs the harness against the
`llama-server` mock with a synthetic eval set, term list, and hardware tree. It
checks the Clopper-Pearson bound at known points (0/29 at or below 10%, 0/59 at
or below 5%) and against the sizing table in `eval-set.sh`, the three rows and
per-category counts, the errors bucket, held-out digest refusal and the run
log, record completeness and mode, the request body against production, the
publish scrub, refusal inside a container, and that nothing outside the eval
store is written.

## Limits

- **Epic 1 does not go through the gate.** Until Story 2.6, a difference
  between the gate's code path and the harness's direct calls would not show
  in the eval. The shared floor function, settings file, and `fleet_call`
  narrow this, but do not close it.
- **The record has no `policy_version` yet.** AD-19 adds it to eval records
  when the gate computes it (Epic 2).
- **The `-np 1` instance is trusted as configured.** In `np1` mode, the harness
  checks the alias but does not ask the server how many slots it has.
- **The scrub handles known identifier types.** It cannot recognise every
  possible identifier in free text, so only one free-text field (the GPU model
  name) is kept, and everything else is an allowlist of checked formats. Read a
  published record before you share it.
- **Rates describe your eval set.** A low upper bound says the check catches
  cases like yours. It says nothing about kinds of content your set does not
  contain.
