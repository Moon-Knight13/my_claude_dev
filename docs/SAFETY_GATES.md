# Safety Gates — Deep Dive

This document details the safety gate implementations referenced by
[`PROJECT.md`](PROJECT.md). Read this when editing hooks, guards, or the
ctp-bridge — not on every session start.

Source of truth for rules is `PROJECT.md`. Operator view is
[`SAFETY_HARNESS.md`](SAFETY_HARNESS.md).

## The tool bridge (`scripts/ctp-bridge.sh`)

That wrapper is the **only** supported path to run `ctp`. A `PreToolUse` hook
(`.claude/hooks/pretooluse-ctp.sh`) denies the two ways around it — `docker exec`
into the container, and a bare `ctp` — so the gates cannot be skipped.

**Installed at user scope, not per-repo.** The work does not happen in this repo —
it happens in the range checkout (e.g. `~/catapult/inventories/dcm`), and a hook
registered only in this repo's `.claude/` would not load for a session started
there. So `scripts/install-ctp-bridge.sh` (run by provisioning, step 8, or
standalone) installs the wrapper to `~/.local/bin/ctp-bridge`, the guard to
`~/.local/lib/ctp-bridge/`, the hook into `~/.claude/`, and seeds
`~/.ctp-bridge.conf` — so the gate is present in **every** session on the account,
whatever the CWD, and **nothing** is written into the range checkout (a tree you
push). Run it as `ctp-bridge host deploy <box>` from the range checkout. The gate
is inert until `CTP_ALLOWED_TARGET` is set — a provisioned box refuses every deploy
until configured, which is the safe direction.

The gates that matter, all in code on the parsed argv (never string-matched), and
shared between wrapper and hook via `scripts/lib/ctp-guard.sh` so the two cannot
drift:

- **Two gates on a mutating target, both mandatory.** A **team gate** —
  `CTP_ALLOWED_TEAM`, e.g. `t02` — requires the target to end with the authorised
  team suffix, so a deploy cannot land on a live team by mistake; it holds even if
  the box list is widened, and fails closed when unset. A **box allow-list** —
  `CTP_ALLOWED_TARGET`, one named box — on top of it. A glob metacharacter in a
  target is refused outright.
- **Reachable verbs.** Mutating: `host deploy`, `host deploy-role` (team + box
  gated). Read: `host list <box>` (verify a target) and `project update-inventory`
  (required after making a Providentia box). `host vars`/`redeploy`/`remove` are
  not reachable (`vars` would stream box detail into the transcript); `secrets` and
  `make` are refused outright (credentials). Every reachable verb is still
  confirmed per the owner policy above.
- **The boundary is the config file, never caller env.** An agent that can set an
  environment variable in the same call it makes must not be able to widen its own
  limits. Both wrapper and hook read `.ctp-bridge.conf`; neither trusts env for a
  boundary value.
- **The agent's confirmation is the hook's prompt, handed to the wrapper by a
  token.** The Bash tool's stdin is non-interactive, so the wrapper cannot prompt
  on the agent path. The human confirms at the hook's `ask` prompt; the hook then
  writes a single-use, argv-bound, short-TTL token, and the wrapper consumes it in
  place of prompting. Without a token and without a TTY the wrapper refuses (no
  auto-yes) — so an unattended/scripted run with no human is still blocked, while
  the hook-approved agent path runs. The token path is itself guarded: the hook
  denies any Read/Write/Edit/Bash access to it (and to the secret paths), and its
  matcher is `Bash|Read|Write|Edit` for that reason. This is hygiene + human-in-
  the-loop to the same strength as the rest of the hook, not a cryptographic
  boundary — consistent with the accepted-risk note below.

`.ctp-bridge.conf` is gitignored and holds a box name and paths — never secrets.
The invocation count log lives under `.ai/` (also gitignored) and records verbs
and outcomes only, never a target or output.

## Secrets and transcripts

The tool gate does nothing about a secret Claude might *read*. On this shared box
the next occupant can read the session transcript, and anything read also leaves
the box to reach the model. So the same hook **denies reads of configured secret
paths** — the vault password file, `~/.ssh/id_*`, `**/.env`, shell history —
whether via the Read tool or a Bash command naming them. Least privilege makes
that free: the deploy loop needs none of those, and the wrapper checks the vault
by existence, never by reading it.

Be honest about the limit. A hook matching command strings is hygiene and
defense-in-depth, not a sandbox — an adversarial model could obfuscate a read. The
real containment is OS-level: an agent user without read access to those files.
The shared single-account box does not offer that (see *Operating environment* —
one account, everyone sudo), so this is an **accepted risk**, the same class as
the killswitch: it reduces incidental and instructed capture, it does not contain
a hostile model. `PII-Shield` (referenced in `.claude/settings.json`) is
complementary, not a substitute.

## Accidental commits: the warn-only commit guard

Provisioning installs a commit guard at user scope
(`scripts/install-commit-guard.sh`, step 9) that scans staged content for secrets
and PII on every commit. It is **warn-only by owner decision, for both PII and
secrets** — intentional commits must never be blocked. On a finding it prints a
warning and appends `{rule, file, line}` to
`~/.local/state/commit-guard/findings.jsonl`; it **never** stores the matched
value, because a log full of real secrets would only relocate the leak — the same
reasoning as the ctp log recording verbs/outcomes but never targets.

Two properties matter if you change it:

- **It covers every repo, not just this one.** The installer sets the user's
  global `core.hooksPath`, so the hook fires in the range checkout too, with the
  gitleaks config carried alongside the runner — nothing is written into that
  pushed tree. It chains to a repo-local `pre-commit` hook if one exists, so a
  repo using the pre-commit framework still runs (and can still block on) its own
  hooks; only this guard is warn-only.
- **Warn-only shifts the mitigation, and it is bypassable.** Nothing stops the
  push, so a secret finding must be acted on — rotate/clean per `SECURITY.md`.
  `--no-verify` and direct index writes bypass any git hook. This cuts accidental
  leaks; it does not contain a determined actor — the same accepted-risk framing
  as the secret-read hook. `check-day0.sh` reports it honestly on a box (present,
  warn-only, bypassable), and warns if `gitleaks` is absent so the scan is not
  silently a no-op.

## The destructive-action gate

The same user-scope PreToolUse hook that fronts the tool bridge now also gates
**destructive shell commands** — the first control of a proportionate agent safety
harness. `scripts/lib/safety-guard.sh` classifies a command and returns
`ask` (the human confirms in Claude Code) or, with no human present, the harness
resolves that to a **deny** — it fails closed, and there is no `--yes`/`ASSUME_YES`
path to it. Empty allow-list is the supported default: everything the classifier
flags is confirmed. An owner exempts a verb per-verb in `~/.config/safety-guard.conf`
(parsed, never sourced, never read from caller env), only after weighing **both**
blast radius and cost — the same two-axis rule as the tool bridge.

Scope is generic **filesystem / infra / database** commands (`rm -rf`, `shred`,
`mkfs`, `dd of=`, `dropdb`, `DROP`/`TRUNCATE` SQL, `terraform destroy`,
`kubectl delete`, `docker system prune`/`rm -f`). It deliberately does **not**
cover git or commit actions — those are the commit guard's domain — and it does
**not** re-gate `ctp`, which keeps its dedicated gate above (double-gating it would
just add noise).

Two properties matter if you change it:

- **It classifies segmented command words, never a raw string.** The
  quote/heredoc/subshell segmentation from #40-42 was factored into
  `scripts/lib/cmd-segment.sh` so the ctp path and this classifier share one
  hardened implementation instead of drifting. That is why `git commit -m "drop
  the users table"` and a `DROP` inside a heredoc body are **not** flagged, while
  `FOO=1 dropdb prod` and `$(rm -rf x)` are — the classifier sees the real command
  word after env prefixes are stripped and substitutions are descended.
- **It is model-agnostic and honest about its reach.** The classifier is a lib —
  the single choke point any executor routes through. It stops the accidental
  and the misread-instruction cases; an
  adversarial model can still obfuscate around string classification, so like the
  secret-read hook it is defense-in-depth, not a sandbox — the real containment is
  OS-level, which the shared-sudo box does not provide (accepted risk).
  `check-day0.sh` reports it honestly on a box.

## Destructive git operations (2b)

The destructive-action gate above deliberately leaves git alone — by owner
decision, **all git/commit actions are the commit guard's (B's) domain**. But the
commit guard is a *pre-commit* hook, and the dangerous git ops are not commits and
fire no git hook: `git push --force`, `reset --hard`, `clean -f`, `branch -D`,
`checkout/switch --force`. So `scripts/lib/git-guard.sh` gates those at the **same
PreToolUse choke point** as A — `gitguard_classify` returns `ask` (human confirms;
no human ⇒ deny, fail closed). It classifies the segmented command word (shared
`cmd-segment.sh`), so a commit message that merely says "reset --hard" is not
flagged, and env prefixes / `git -C <dir>` are seen through. An owner exempts an op
per-op in `~/.config/git-guard.conf` (`GITGUARD_ALLOWLIST`, parsed never sourced);
empty is the default (confirm everything). Same honest limit as A: string
classification can be obfuscated — defense-in-depth, not a sandbox. `check-day0.sh`
asserts it on a box.

## Keeping Org PII/IP out of Claude: the path guard

The worry is Org PII or intellectual property leaking to the model — and the
primary channel is a tool *reading* a sensitive file into the transcript. A hook
**cannot redact tool output**: `PreToolUse` runs before the tool and can only
allow/ask/deny (it may rewrite tool *input*, but not the result), and
`PostToolUse` runs after the tool has already produced its output. So for a
file's *contents* the only reliable in-harness protection is to **deny the read**
— which is what the secret-read hook already does, now extended to a second,
separately-configured list.

`CTP_PII_PATHS` (in the gitignored `~/.ctp-bridge.conf`) lists Org PII/IP path
globs, same syntax as `CTP_SECRET_PATHS` (tilde expands to the target home; a
`**/` prefix matches anywhere by basename). The hook denies any Read/Write/Edit
or Bash command that names a listed path, with its own reason string so a denial
says *which* policy fired. Both matchers share one hardened glob helper
(`_ctp_path_in`), so they cannot drift.

Two properties matter if you change it:

- **It is a separate list from secrets, on purpose.** Secrets are credentials
  (never touch, for anyone); PII paths are a data-governance boundary the owner
  tunes independently. Keeping them apart preserves that. **Empty is the
  default (opt-in):** nothing is denied until the owner lists the directories
  where Org data lives. The deny is **symmetric** (read *and* write) because a
  PII/IP directory is a boundary the agent should not touch at all.
- **It is path-based, and honest about that.** PII sitting inside a file *outside*
  the listed globs is not caught, and the guard does not redact PII embedded in an
  otherwise-readable file's output — hooks cannot rewrite output regardless. This
  is the same defense-in-depth, accepted-risk framing as the secret-read hook —
  the real containment is OS-level, which the shared-sudo box does not provide.
  `check-day0.sh` asserts the capability is present on a box (a stale install
  predating it FAILs).

## Classification design notes

Classification needs **two** axes, not one. Destructive-versus-read-only is
insufficient: a whole-range deployment may destroy nothing and still be something
no one wants triggered by a misread instruction, because it consumes real time
and real infrastructure. A verb is a candidate for exemption only when it is low
on both **blast radius** (what it changes, and whether that is reversible) and
**cost** (what running it consumes, and who pays).

Pattern-matching command strings is not a protection — quoting and environment
prefixes defeat it, and it looks enforced while not being.
