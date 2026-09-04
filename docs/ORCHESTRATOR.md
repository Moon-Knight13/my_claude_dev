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
   1. mode?   LOCAL-ONLY / CLAUDE-ONLY / AUTO         (owner switch; overrides 2)
   2. classify (AUTO only): local-LLM judge -> sensitive | nonsensitive
                            (fail-closed: error/timeout/garbled -> sensitive)
   3. eligible tiers:  sensitive -> {host-local, network-local}   (NO cloud)
                       else      -> {frontier, host-local, network-local}
   4. pick highest-rank model in an eligible tier
   5. dispatch:  frontier -> claude -p   (A/B gates + caveman still apply)
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
| `scripts/orchestrator/classifier-prompt.default.md` | The shipped, **generic** judgement prompt. Seed for the owner's private on-box copy. |
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

## Security properties & honest limits

- **Structural invariant** (above) — the core guarantee.
- **Fail-closed** everywhere; **never-egress** for the classifier.
- **Metadata-only log** — `.ai/orchestrator-log.jsonl` records
  `mode/sensitive/tier/model`, never the prompt text.
- **Handoff keeps the gates** — a cloud handoff goes through `claude -p`, so the
  box's PreToolUse hook (destructive-action gate, secret/PII read-deny) and commit
  guard still front it.
- **Residual risk (accepted):** no deterministic hard-floor (owner decision), so a
  confident LLM misclassification of a sensitive prompt as safe can still egress.
  Mitigated by `LOCAL-ONLY` mode + fail-closed, and bounded by the eval. This is
  defense-in-depth, not a guarantee — same framing as the box's other controls.

## Dependencies

`bash`, `jq`, `curl`, and a local OpenAI/Ollama-compatible endpoint. Reuses
`scripts/lib/load-env.sh` (config), and — for the future local executor —
`scripts/lib/safety-guard.sh` (enforcement point #2). No network egress of its
own beyond the model calls it routes.

## Porting to the template repo

The component is intentionally decoupled. To lift it upstream:

- **Take:** `scripts/orchestrator/`, `scripts/lib/orchestrator-route.sh`,
  `scripts/tests/test-orchestrator.sh`, `scripts/tests/test-classifier.sh`,
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

- **Sanitiser** — rephrase a non-sensitive prompt to strip incidental identifiers
  before a cloud handoff (LLM-rephrase; control **C2**).
- **Model-serving pool** — LiteLLM fronting the heterogeneous fleet with
  retry/fallback = bidirectional failover.
- **Local executor** — run tool/shell work locally for sensitive tasks that need
  it, routed through `safety-guard.sh` (enforcement point #2).

See `_bmad-output/planning-artifacts/architecture-g3-local-orchestrator.md` for
the full architecture and owner decisions.
