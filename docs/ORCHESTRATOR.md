# The Local-Model Orchestrator

A privacy-routing **front door** for agent work on a dev box. It takes a prompt,
decides whether that prompt is safe to send to a cloud model, and routes it: a
**sensitive** prompt stays on the **local model fleet** and never egresses; a
**non-sensitive** one may hand off to the most capable model available (e.g.
Claude via `claude -p`, where the box's existing safety gates still apply).

This document is written to be **portable** — the component is designed to be
lifted into other repositories (see *Porting* at the end).

> Status: MVP spine + local-LLM classifier are built and smoke-tested. Sanitiser,
> multi-machine pool, and local executor are roadmapped (see end).

## Why it exists

The worry it answers: an agent leaking Org PII/IP to a cloud model. A network
firewall stops the agent reaching *unknown* hosts, but it happily allows the agent
to reach its *own* cloud model with sensitive content in the prompt — the firewall
never sees a leak. The orchestrator closes that by deciding, per prompt, what is
allowed to leave at all.

## The non-negotiable safety invariant

> **Sensitivity gates tier eligibility BEFORE capability ranking.**
> A prompt the router treats as sensitive is **never eligible** for the frontier
> (cloud) tier, however capable — the cloud endpoint is removed from the eligible
> set, so the picker cannot choose it. The front door also re-asserts this
> immediately before dispatch and refuses (exit 4) rather than egress a sensitive
> prompt.

This is a **structural property of the code**, not a prompt the model could be
talked out of. Every test and review targets one question: *can a prompt the
router treats as sensitive ever reach an egressing endpoint?*

## How it works

```
 prompt ─▶ orchestrate.sh
   1. mode?   LOCAL-ONLY / CLAUDE-ONLY / AUTO         (your switch; overrides 2)
   1b. word list: your private terms, matched by code, in EVERY mode
                            (a match -> sensitive; no AI involved; beats 1 and 2)
   2. classify (AUTO only): local-LLM judge -> sensitive | nonsensitive
                            (fail-closed: error/timeout/garbled -> sensitive)
   3. eligible tiers:  sensitive -> {host-local, network-local}   (NO cloud)
                       else      -> {frontier, host-local, network-local}
   4. pick highest-rank model in an eligible tier
   5. dispatch:  frontier -> [sanitise ->] claude -p   (A/B gates + caveman apply)
                 local    -> Ollama /api/generate (reasoning-only for now)
   (belt-and-braces: refuse if a sensitive prompt resolved to an egressing tier)
```

## Modes

| Mode | Meaning |
|------|---------|
| `AUTO` | Classify each prompt, then route. The default. |
| `LOCAL-ONLY` | Force everything to the local fleet — the human seatbelt for known-sensitive work; nothing can egress. |
| `CLAUDE-ONLY` | The human asserts the work is fine for the cloud (frontier eligible) — the human acting as classifier. |

The CLI `--mode` flag overrides the config default per call. `--dry-run` prints
the decision (`mode / sensitive / tier / model`) without dispatching — useful for
demos and the invariant test.

## Files

| File | Role |
|------|------|
| `scripts/orchestrator/orchestrate.sh` | Front door: mode switch, tier resolver, dispatch, metadata log, `--dry-run`. |
| `scripts/lib/orchestrator-route.sh` | Pure decision logic — config parse, mode resolution, `orch_classify`, eligible-tier resolver (the invariant), model pick. No I/O, so the invariant is unit-testable. |
| `scripts/orchestrator/classify-sensitivity.sh` | The sensitivity judge — a thin wrapper that calls the **local** LLM and returns `sensitive`/`nonsensitive`. Never egresses; fails closed. |
| `scripts/orchestrator/term-list.example.txt` | Starting point for your private word list (#65) — the check that runs before the AI. Ships with no words in it. |
| `scripts/orchestrator/classifier-prompt.default.md` | The shipped, **generic** judgement prompt. Seed for the owner's private on-box copy. |
| `scripts/orchestrator/sanitise.sh` | Cloud-handoff sanitiser (C2) — LOCAL LLM rephrase that strips incidental identifiers before egress. Transform-or-fail; never egresses. |
| `scripts/orchestrator/sanitiser-prompt.default.md` | The shipped, generic rewrite prompt. Seed for the owner's private copy. |
| `scripts/orchestrator/eval-sanitiser.sh` | Measures marker-survival — injected identifiers that must not appear in the rewrite. |
| `scripts/tests/test-sanitiser.sh` | Sanitiser contract tests — transform-or-fail, never-egress (mocked model). |
| `scripts/orchestrator/eval-classifier.sh` | Measures the judge against labelled fixtures; headline metric = sensitive-recall. |
| `scripts/tests/fixtures/sensitivity-eval.jsonl` | Labelled eval cases (synthetic PII/IP + adversarial near-misses). |
| `scripts/tests/test-orchestrator.sh` | Routing/invariant unit tests (22). |
| `scripts/tests/test-classifier.sh` | Classifier contract tests — strict parse, fail-closed, never-egress (mocked model, 19). |
| `.orchestrator.conf.example` | Config template: mode + model registry + classifier notes. |

## Configuration

On-box config `~/.config/orchestrator.conf` (gitignored; parsed, never sourced):

```
ORCH_MODE=AUTO
# ORCH_MODEL=<name>|<tier>|<rank>|<endpoint>
ORCH_MODEL=claude|frontier|100|
ORCH_MODEL=<model>|host-local|60|http://host.docker.internal:11434
# ORCH_MODEL=<model>|network-local|55|http://<other-machine>:11434
```

Tiers: `frontier` (cloud, egresses — eligible only for non-sensitive),
`host-local` (this machine), `network-local` (another machine on the local net).
Rank is capability; higher wins within an eligible tier.

Classifier knobs (env / `.env`): `ORCH_CLASSIFIER` (points at the judge script —
**this enables AUTO classification**; unset ⇒ fail-closed stub),
`ORCH_CLASSIFIER_ENDPOINT` (LOCAL only), `ORCH_CLASSIFIER_MODEL`,
`ORCH_CLASSIFIER_TIMEOUT`, `ORCH_CLASSIFIER_KEEP_ALIVE`,
`ORCH_CLASSIFIER_PROMPT_FILE`.

## The word list that can't be argued with

You keep a private list of words that must never leave the box — codenames, client
names, internal hostnames, project names.

Before anything else happens, the orchestrator checks your prompt against that
list. If one of your words is in it, the prompt is treated as sensitive and the
cloud is taken off the table. No AI model is involved in that decision — it is a
plain text match done by code.

### It works even when you say "send this to the cloud"

`CLAUDE-ONLY` mode means *"I've checked, this one is fine for the cloud"*, and it
normally skips all sensitivity checking.

The list still runs. If one of your words is in the prompt, it stays local anyway.

That sounds heavy-handed, and it is on purpose. `CLAUDE-ONLY` is the mode you use
when you're confident — which is exactly when a forgotten codename slips through.
You're checking from memory, and the list exists because memory fails. If you
really do want that prompt to go out, take the word off your list first. You can
override it, but you have to mean it.

The log still records the mode you asked for, plus `"floor":true` to show it was
overruled. It doesn't quietly pretend you asked for something else.

### Why the list is checked by code, not by the AI

You could instead put these words in the classifier's instructions and ask the
model to watch for them. That doesn't work, for one reason:

The model is the thing you're trying to back up. A model can skim past its own
instructions, talk itself round, or be talked round. That's the exact failure this
list exists to catch — so the model can't be the one doing the catching.

Code has no instructions to forget and no reasoning to go wrong. It either finds
your word or it doesn't.

### What it does and doesn't cover

It catches every word you thought to write down. It cannot catch anything you
didn't. For everything else, the AI classifier is still the judge, with all the
uncertainty that carries.

So it narrows the gap. It doesn't close it. (Before this existed there was no
non-AI check at all — a deliberate earlier decision, now reversed.)

### How matching works

Capitals are ignored, so `Bluefin`, `bluefin` and `BLUEFIN` all match.

It matches whole words only. `atlas` will **not** match `atlassian`, `catalyst` or
`atlases`. That matters more than it sounds: if short words matched inside longer
ones, everything would look sensitive, everything would stay local, and you'd end
up switching the list off. A safeguard you've turned off protects nothing.

Words shorter than 3 characters are ignored, and you get a warning telling you
which **line number** to fix. Change that limit with `ORCH_TERM_MIN_LEN`.

### It never tells you which word matched

When the list fires, all you're told is "sensitive". Not which word. The log gets
`"floor":true` and nothing more. Even the "this word is too short" warning gives a
line number, never the word.

That's deliberate. The list is a concentrated collection of your secrets. A
safeguard built to stop them leaking must not become the thing that prints them.

### Look after this file

It lives at `~/.config/orchestrator/term-list.txt`, and it is the single most
sensitive file on the box — a tidy index of everything you're protecting.

- Never commit it.
- Never paste it into a chat.
- Never ask Claude to read, review or improve it.

Add its path to `CTP_PII_PATHS` so Claude's tools are blocked from reading it. The
orchestrator opens the file directly rather than through a tool, so it keeps
working while Claude stays blind to it.

Once it has real words in it, that's a one-way door: from then on you edit it
yourself, or with the local model. Not with Claude.

Start from `scripts/orchestrator/term-list.example.txt`. It ships with
instructions and **no words** — a generic list would protect nobody.

### If you haven't set it up

No list, or an empty one, is fine and is not an error. The check simply doesn't
run and the AI classifier decides on its own, exactly as things worked before.

## Setting it up and checking it works

### 1. Make your list

```bash
mkdir -p ~/.config/orchestrator
cp scripts/orchestrator/term-list.example.txt ~/.config/orchestrator/term-list.txt
chmod 600 ~/.config/orchestrator/term-list.txt
```

Open it and add one word per line at the bottom.

Start with the few you'd most regret sending to a cloud model. A short accurate
list beats a long guessed one, and you can add more any time.

### 2. Tell the orchestrator where it is

The path above is the default, so if you used it you can skip this step.

If you keep the file somewhere else, set this in your environment or `.env`:

```bash
ORCH_TERM_LIST=/path/to/your/list.txt
```

### 3. Block Claude from reading it

In `~/.ctp-bridge.conf`, add the path to `CTP_PII_PATHS`, next to the other private
files:

```
CTP_PII_PATHS=~/.config/orchestrator/classifier-prompt.md ~/.config/orchestrator/sanitiser-prompt.md ~/.config/orchestrator/term-list.txt ~/org-data/**
```

### 4. Test it — with a made-up word, not a real one

**Don't test with a real term.** Commands you type end up in your shell history and
on screen, which is the one place your real words shouldn't be.

Add a nonsense word instead:

```bash
echo 'zzhippopotamus' >> ~/.config/orchestrator/term-list.txt
```

Now run both of these. `--dry-run` shows you the decision without sending anything
anywhere:

```bash
# has your test word — should stay local
scripts/orchestrator/orchestrate.sh --mode CLAUDE-ONLY --dry-run \
  'deploy zzhippopotamus to prod'

# no test word — should go to the cloud
scripts/orchestrator/orchestrate.sh --mode CLAUDE-ONLY --dry-run \
  'refactor the parser module'
```

You should see:

```
mode=CLAUDE-ONLY sensitive=sensitive    -> tier=host-local ...
mode=CLAUDE-ONLY sensitive=nonsensitive -> tier=frontier ...
```

**Check both lines.** The first proves the list works — you said cloud, it stayed
local. The second proves it isn't simply blocking everything, which would look
identical if you only ran the first.

Then take the test word out:

```bash
sed -i '/^zzhippopotamus$/d' ~/.config/orchestrator/term-list.txt
```

### 5. Check Claude really can't read the list

In a Claude session, ask it to read `~/.config/orchestrator/term-list.txt`.

It should be refused. If Claude can read it, step 3 didn't take — check for a typo,
and make sure the path is written the same way as the other entries (`~/...`).

### 6. Check nothing leaked into the log

```bash
grep floor .ai/orchestrator-log.jsonl | tail -3
```

Lines that matched show `"floor":true`. There should be no word from your list and
no prompt text anywhere in the file. A normal line looks like this:

```json
{"ts":"...","mode":"CLAUDE-ONLY","sensitive":"sensitive","floor":true,"tier":"host-local","model":"qwen-host","dry_run":true}
```

### Using it day to day

Nothing to do. The check runs on every prompt automatically.

The only thing you'll notice is a prompt occasionally staying local when you
expected it to go out. That's it working.

### If something seems wrong

| What you see | Why | What to do |
|---|---|---|
| Nothing ever matches | The file isn't where the orchestrator is looking. A missing file is intentionally not an error, so it fails quietly | `ls -l ~/.config/orchestrator/term-list.txt`, and check `ORCH_TERM_LIST` if you moved it |
| One word never matches | It's under 3 characters and is being skipped | Look for `term-list line N rejected` on screen; make the word longer |
| A word doesn't match inside a longer word | Working as intended — whole words only | Add the longer form as its own line |
| Everything stays local | One of your words is too short or too common and matches constantly | Remove half the list, test, repeat until you find it |
| You can't tell which word matched | By design — it never says | Narrow it down yourself against your own list. It's never printed, logged, or shown to Claude |

## The classifier

The judgement is the **LLM's**; the script is its socket + safety fuse. It:

- sends the prompt to the **local** model with the system prompt from the tuned
  prompt file (falling back to the shipped default), and
- enforces two things the model cannot be trusted to self-enforce:
  - **never egresses** — it reads the raw prompt (which may *be* the sensitive
    content), so it calls a local endpoint only and refuses a non-local one; and
  - **fails closed** — a timeout, error, empty/garbled output, or anything that is
    not a clean `nonsensitive` verdict resolves to `sensitive`.

**Thinking-model note.** With a reasoning model (e.g. qwen3) the verdict is parsed
from the **last non-empty line** (stripping a `\boxed{}` remnant), because such
models emit a reasoning remnant before the answer even when thinking is requested
off. Reasoning on earlier lines — including a stray "not nonsensitive" — cannot
unlock the cloud. The call is tuned for a one-word verdict: thinking off,
temperature 0, capped `num_predict`, `keep_alive` to stay warm.

**Tuning without leaking.** The owner edits a **private** on-box copy
(`~/.config/orchestrator/classifier-prompt.md`), which accumulates the very
sensitive patterns it is meant to catch. Therefore that file (a) is never
committed — the shipped default stays generic — and (b) is added to `CTP_PII_PATHS`
so the C1 path guard stops Claude's own tools from reading it. The classifier
reads it directly (not a tool call), so it still works; Claude cannot.

## The eval

`eval-classifier.sh` runs the classifier over the labelled fixtures against a live
local model and prints a confusion matrix. The headline is **sensitive-recall** —
of the truly-sensitive cases, how many were caught; a miss is a potential leak.
It lists every miss so the prompt can be tuned. It needs a live model, so it is an
**on-box manual tool, not a CI gate** (the deterministic contract is covered by
`test-classifier.sh`). Treat a 100% score on the synthetic set as a floor, not
proof; grow the fixtures from real (sanitised) misses.

## The sanitiser (control C2)

On the **cloud-handoff path only**, an opt-in (`ORCH_SANITISER`) step rewrites the
prompt to strip incidental identifiers — names, emails, IPs, tokens, internal
hostnames, codenames — into neutral placeholders (`PERSON_1`, `HOST_1`, …) before
it reaches Claude, preserving the technical task. It is **defense-in-depth on top
of the classifier, not the gate**: only a prompt already judged non-sensitive
reaches it.

- **Local-only LLM rephrase** — it reads the raw prompt, so it calls a local
  endpoint and refuses a non-local one; it never egresses.
- **Transform-or-fail** — on model error/timeout/empty rewrite it exits non-zero
  with no output, and the front door applies `ORCH_SANITISE_ON_FAIL`:
  `passthrough` (default — the classifier already cleared the prompt) or `block`.
- **Held line** — it de-identifies *data*; it must not be used to disguise a
  prohibited *action* as an allowed one (the rewrite is the same work).
- **Measured, not assumed** — `eval-sanitiser.sh` injects known markers and checks
  none survive the rewrite (marker-survival). An LLM sanitiser will miss some
  categories out of the box (e.g. internal hostnames, codenames); the owner tunes
  the private prompt (few-shot examples) and re-measures.

## Security properties & honest limits

- **Structural invariant** (above) — the core guarantee.
- **Fail-closed** everywhere; **never-egress** for the classifier.
- **Metadata-only log** — `.ai/orchestrator-log.jsonl` records
  `mode/sensitive/tier/model`, never the prompt text.
- **Handoff keeps the gates** — a cloud handoff goes through `claude -p`, so the
  box's PreToolUse hook (destructive-action gate, secret/PII read-deny) and commit
  guard still front it.
- **Your word list** (above) — a listed word forces `sensitive` in every mode, with
  no AI in the decision. It is the one check here that a model cannot be argued
  past.
- **Remaining risk (accepted, reduced):** the list only catches words you thought to
  write down. For anything else the AI classifier is still the only judge, so a
  confident wrong call on a sensitive prompt can still send it out. Reduced by
  `LOCAL-ONLY` mode and by failing closed on errors, and measured by the eval. This
  is layered defence, not a guarantee — the same honest framing as the box's other
  controls. (Before the word list there was no non-AI check at all; it narrows this
  risk, it does not remove it.)

## Dependencies

`bash`, `jq`, `curl`, and a local OpenAI/Ollama-compatible endpoint. Reuses
`scripts/lib/load-env.sh` (config), and — for the future local executor —
`scripts/lib/safety-guard.sh` (enforcement point #2). No network egress of its
own beyond the model calls it routes.

## Porting to the template repo

The component is intentionally decoupled. To lift it upstream:

- **Take:** `scripts/orchestrator/` (front door, classifier, sanitiser, evals,
  default prompts), `scripts/lib/orchestrator-route.sh`, the tests
  (`test-orchestrator.sh`, `test-classifier.sh`, `test-sanitiser.sh`),
  `scripts/tests/fixtures/sensitivity-eval.jsonl`, `.orchestrator.conf.example`,
  and this doc.
- **Generic already:** the routing lib, the invariant, the classifier contract,
  the mode switch, the eval harness. Nothing here is specific to this repo's box.
- **Genericise on the way:** the default model name in `.orchestrator.conf.example`
  and the classifier default (currently a specific host model) → a placeholder;
  the shipped `classifier-prompt.default.md` is already generic.
- **Integration points:** it expects `scripts/lib/load-env.sh` (or an equivalent
  config loader) and, for the deferred executor, `scripts/lib/safety-guard.sh`.
  The cloud handoff assumes a `claude`-CLI-shaped executor fronted by PreToolUse
  hooks; keep that assumption or adapt the frontier dispatch.
- **Gate it behind a subsystem flag** (this template uses `template.conf`
  `SUBSYSTEM_*`) so repos can opt in.

## Roadmap (deferred slices)

- **Model-serving pool** — LiteLLM fronting the heterogeneous fleet with
  retry/fallback = bidirectional failover.
- **Local executor** — run tool/shell work locally for sensitive tasks that need
  it, routed through `safety-guard.sh` (enforcement point #2).

See `_bmad-output/planning-artifacts/architecture-g3-local-orchestrator.md` for
the full architecture and owner decisions.
