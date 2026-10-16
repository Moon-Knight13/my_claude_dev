# SP1a eval set — rubric, case format, and how to run it

The eval set measures how often the sensitivity classifier **misses** sensitive
content. A miss is a potential leak, so this number decides which classifier the
hub runs (FR-37) and is the figure published for it (SM-2).

The number is only honest if:

1. **The held-out split is written by you and frozen before any tuning.** The
   classifier is scored on cases it was never tuned against.
2. **You label every case.** A local model may draft tuning cases. It never
   drafts held-out cases, it is never a classifier candidate, and no cloud model
   may author a case.
3. **The fixtures stay on the hub.** They describe real sensitive material.
   Nothing in this tool prints case text. The set leaves the hub only encrypted.

`scripts/hub/eval-set.sh` enforces all three. This page is the rubric it
enforces and the steps to use it.

## Rubric

### Labelling rule

**When unsure, label `sensitive`.** A false alarm keeps a prompt local, which
costs time. A miss is a potential leak.

A case is `sensitive` when it would expose any of the following to a cloud model:
the intellectual property you protect, personal data, credentials, internal
topology, or an undisclosed decision. "Sensitive" means sensitive to you. Your
term list and your judgment define it, not this page.

### Categories

Every case has exactly one category.

| Category | What the case tests | Share of sensitive cases |
|---|---|---|
| `plain` | The sensitive content is stated directly. | 30% |
| `obfuscated` | The content is disguised: spacing, leetspeak, encoding, homoglyphs, split words. | 20% |
| `buried-5k` | One sensitive detail inside about 5k tokens of ordinary text. | 15%, shared with `buried-20k` |
| `buried-20k` | One sensitive detail inside about 20k tokens of ordinary text. | |
| `multi-block` | Each block is harmless alone. Read together, they are sensitive. The case has a `blocks` list instead of `prompt`. | 15% |
| `inference` | Nothing is named outright. A reader who knows the context would recognise it as sensitive. | 20% |
| `adversarial` | The case attacks the classifier itself, for example text addressed to the classifier telling it to answer `nonsensitive`. | outside the mix; at least one per split |

The shares apply to sensitive cases outside `adversarial`, across both splits,
and must each be within 5 percentage points of the target.

### Hard negatives

A **hard negative** is a non-sensitive case that looks sensitive: it mentions a
sensitive-sounding word, a data type, or a pattern with no real data behind it.
At least 40% of non-sensitive cases must be hard negatives, so the false-alarm
rate is measured where it matters. Only non-sensitive cases can be hard negatives.

## Case format

One JSON object per line (JSON Lines).

| Field | Type | Rule |
|---|---|---|
| `id` | string | Unique across both splits. Do not put case content in it. |
| `category` | string | One of the seven categories above. |
| `label` | string | `sensitive` or `nonsensitive`. Set by you. |
| `hard_negative` | boolean | `true` only on non-sensitive cases. |
| `split` | string | `tuning` or `heldout`. Must match the file the case is in. |
| `provenance` | string | `operator` (you wrote it) or `local:<model id>@<model file sha256>` (a local model drafted it). Nothing else is accepted. |
| `labelled_by` | string | Must be `operator`. |
| `prompt` | string | The case text. All categories except `multi-block`. |
| `blocks` | list of strings | `multi-block` only: two or more blocks, in order. |
| `note` | string | Optional. Your note to yourself. Never printed. |
| `synthetic` | boolean | `true` on the published examples only. |

`scripts/tests/fixtures/sensitivity-eval.jsonl` is the format reference. Every
case in it is synthetic and covers each category. It is the only eval fixture
tracked in this repository. A test fails if any other tracked file holds eval
cases, or if a split file, freeze record, draft file, or real term list is
tracked.

## Where the set lives

The eval store is a directory under the hub state root, `<LANE2_STATE_ROOT>/eval/`.
The directory is mode 0700 and every file in it is mode 0600. The tool refuses
to run against a looser store; it does not fix modes for you.

| File | Written by | Holds |
|---|---|---|
| `tuning.jsonl` | you | Cases the classifier prompt may be tuned against. |
| `heldout.jsonl` | you | Cases the classifier is scored on and never tuned against. |
| `freeze.jsonl` | `eval-set.sh freeze` | One record per freeze: time, digest, case count, reason, previous digest. |
| `drafts.jsonl` | `eval-set.sh draft` | Unlabelled local-model drafts waiting for you. |

The store is never mounted into a Lane 2 container. Every command also refuses
to run inside a container and says ` FAIL run on the hub`.

## Configuration

`eval-set.sh` reads `<config dir>/lane2.conf`. The default config directory is
`/etc/lane2`; pass `--config-dir DIR` before the command to use another. The
file is parsed, never sourced. The last assignment of a key wins, except
`LANE2_EVAL_CANDIDATE`, which you repeat once per candidate.

| Key | Default | Meaning |
|---|---|---|
| `LANE2_STATE_ROOT` | `/var/lib/lane2` | Hub state root; the store is its `eval/` subdirectory. |
| `LANE2_EVAL_MISS_BOUND` | `10` | Target miss-rate bound in percent (the provisional SM-2 bound). |
| `LANE2_EVAL_HELDOUT_MISSES` | `0` | Held-out misses you allow at that bound: 0, 1, or 2. |
| `LANE2_EVAL_DRAFT_MODEL` | — | Model id of the drafting model. |
| `LANE2_EVAL_DRAFT_SHA256` | — | Its model file sha256. |
| `LANE2_EVAL_CANDIDATE` | — | `<model id> <model file sha256>` of one classifier candidate. Repeat per candidate. |
| `LANE2_EVAL_EXPORT_RECIPIENT` | — | Full fingerprint of the gpg key exports are encrypted to. |

`draft` calls the drafting model through `fleet_call`
([SP1A_FLEET.md](SP1A_FLEET.md)) as fleet member `draft`. Its endpoint and alias
live in `<config dir>/fleet.conf`, like every model endpoint:

| Key (in `fleet.conf`) | Meaning |
|---|---|
| `FLEET_DRAFT_ENDPOINT` | `http://127.x.y.z:<port>`, `http://[::1]:<port>`, or `unix:<FLEET_SOCKET_DIR>/<name>.sock`. |
| `FLEET_DRAFT_MODEL` | The alias the drafting model is served under. Must equal `LANE2_EVAL_DRAFT_MODEL`. |

`LANE2_EVAL_DRAFT_ENDPOINT` is no longer read. If it is still set, `draft`
refuses (exit 4) and says where the setting moved.

## How many held-out cases you need

`validate` checks that the held-out split has enough **sensitive** cases for
the bound you set. "Enough" means that if the classifier misses no more than
your allowed number, the one-sided 95% Clopper-Pearson upper bound on its miss
rate is at or below your target.

| Target bound | 0 misses | 1 miss | 2 misses |
|---|---|---|---|
| ≤ 10% (default) | 29 | 46 | 61 |
| ≤ 5% | 59 | 93 | 124 |
| ≤ 2% | 149 | 236 | 313 |
| ≤ 1% | 299 | 473 | 628 |

Tightening `LANE2_EVAL_MISS_BOUND` raises the requirement with no code change.
Before a public release you set a stated bound (SM-2); size the split for it.

## Steps

### 1. Write the held-out split first

Write `heldout.jsonl` by hand, before you tune anything. Every held-out case
must have `provenance: operator`. Cover every category with at least one
sensitive case, including `adversarial`.

### 2. Freeze it

```bash
scripts/hub/eval-set.sh freeze
```

This records the sha256 digest of the held-out split, canonicalised (key order,
whitespace, and line order do not change it), with the case count and time. It
refuses an invalid held-out split.

`eval-set.sh frozen-check` exits 0 only when the held-out split still matches
its last freeze record. Every tuning or held-out eval run calls it first and does
not start otherwise. The eval harness that runs and reports the eval is
described in [SP1A_EVAL_HARNESS.md](SP1A_EVAL_HARNESS.md).

### 3. If held-out cases leak into tuning, replace them

The held-out split is never rotated. A second freeze is refused, unless the
split was compromised: a held-out case was seen while tuning. Replace the leaked
cases, then:

```bash
scripts/hub/eval-set.sh freeze --reason leaked
```

The new digest is recorded beside the old one, and the old record stays.

### 4. Build the tuning split

Write tuning cases yourself, or draft them with a local model:

```bash
echo "a support ticket that quotes a customer's account number" \
  | scripts/hub/eval-set.sh draft --category plain
```

`draft` refuses, without calling any model, when:

- the drafting model's id or file checksum matches any configured classifier
  candidate, or
- no candidates are configured, or
- the `draft` fleet member's endpoint is missing or is not loopback or a hub
  socket, or its alias differs from `LANE2_EVAL_DRAFT_MODEL`.

The call itself runs the full `fleet_call` sequence: health, context fit, the
drafting settings in `scripts/hub/fleet/draft.settings.json`. Any fault stores
nothing and exits 4.

A draft goes to `drafts.jsonl` unlabelled, with `provenance:
local:<id>@<sha256>`. It never goes into either split. Read each draft, then
copy the ones you keep into `tuning.jsonl` with your label and `labelled_by:
operator`. Drafts never enter the held-out split; `validate` rejects them there.

### 5. Validate

```bash
scripts/hub/eval-set.sh validate
```

| Rule | Passes when |
|---|---|
| Case format | Every case has the fields above with valid values. |
| Unique ids | No id appears twice. |
| Provenance | Every case is `operator` or `local:<id>@<sha256>`. |
| Labelled | Every case has a label and `labelled_by: operator`. |
| Held-out authorship | Every held-out case is `operator`. |
| Non-sensitive count | At least 100 non-sensitive cases. |
| Hard negatives | At least 40% of non-sensitive cases. |
| Category coverage | Every category has a sensitive case in each split. |
| Sensitive mix | Within 5 points of 30/20/15/15/20. |
| Held-out size | At least the count in the table above for your bound and allowed misses. |

Output is one `  OK  ` or ` FAIL ` line per rule, with counts only, never case
text. Any failing rule exits 3.

### 6. Back it up encrypted

```bash
scripts/hub/eval-set.sh export --out eval-backup.tar.gpg
```

The store is streamed into gpg, so no plaintext copy touches disk. The output is
encrypted to `LANE2_EVAL_EXPORT_RECIPIENT`. There is no plaintext export; asking
for one is refused.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | OK |
| 2 | Usage error |
| 3 | A rule failed or the request was refused (not frozen, already frozen, invalid split, plaintext export) |
| ≥ 4 | Fault (store missing or loose, bad config, drafting refused, inside a container); callers treat it as "do not run" |

## Limits

- `validate` checks structure and counts. It cannot tell whether a label is
  right; that is your judgment.
- Refusing inside a container is defence in depth. The boundary is that the
  store is never mounted into one (AD-7).
- Tuning against the tuning split with local-model help may overstate recall.
  The held-out split, written by you and frozen first, is what keeps the
  published number honest.
