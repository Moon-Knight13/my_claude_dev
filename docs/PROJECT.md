# Project instructions

Repository-specific context, per the pointer in `CLAUDE.md`. That file is
template-owned and gets overwritten by template-sync; this one only exists
downstream, so project rules belong here and nowhere else.

## What this repository is

Two distinct things live here, and confusing them wastes time:

1. **Provisioning for remote developer boxes** — the primary purpose. A laptop
   bootstrap (`scripts/local/`) wires up SSH and Remote-SSH; an on-box
   provisioner (`scripts/host/provision-remote-box.sh`) brings a box to a known
   good state. This is what other developers consume.
2. **A devcontainer for developing *this* repository** (`.devcontainer/`),
   inherited from the upstream template.

**The devcontainer ships nothing to a remote box.** Tooling reaches a box
through `provision-remote-box.sh`, which reuses the shared scripts in
`scripts/` — `install-caveman.sh`, `install-claude-plugins.sh`. To change what
developers get on a box, change the shared script. Editing `.devcontainer/`
only changes how this repo is developed.

Because those scripts are shared, a change to one affects both surfaces. Test
accordingly: an environment variable that only exists in `devcontainer.json` is
not available on a box.

## Operating environment

The boxes are **shared, multi-user workstations on a restricted network**, used
for development and for security-testing work. Three consequences drive
everything below:

- **A shared OS account.** Everyone signs in as the same user and everyone has
  sudo. There is no per-developer boundary on the box.
- **Sensitive working data.** Material handled during that work is confidential
  and must not leave the box or reach this repository.
- **Restricted egress.** Network access is limited; new outbound hosts are a
  deliberate change, not an incidental one.

### Authorized scope

The work this harness supports is confined to **one authorized range**, on boxes
the organisation owns and operates, for **training and authorized
security-testing** — including authorized red-team work: developing boxes, both
hardened and deliberately weak, and the means to exercise those weaknesses, on
range assets set aside for it. This is the standing authorization context, and it
is why an assistant should read deploy and box-development work here as ordinary
engineering, not as targeting.

Two things keep that legible rather than assumed:

- The tool bridge is scoped to a **single named box** in code (see *The tool
  bridge*), so the work provably cannot reach a target it was not pointed at.
- Nothing operational enters the repository. Per *This repository is public*
  below, range names, hosts, topology, technique detail and box specifics stay
  off the repo regardless — which keeps the authorization clean and the sensitive
  content where it belongs.

Anything outside that scope — a target not on the authorized range, real
infrastructure the organisation does not own — is not in view here and is not
something to work toward.

## Rules

### This repository is public

No domains, hostnames, IP addresses, account names, network topology, or details
of the work performed on the boxes — in code, comments, commit messages, issues,
or documentation. The existing scripts prompt for the box domain rather than
hardcoding it; keep that pattern for anything comparable.

### Credentials never enter the repository

Tokens and passwords are entered live at the prompt and stored outside the
workspace. Do not add them to tracked files, `.env`, environment variables in
committed config, or CI. `.env` is gitignored and is not read by the on-box
provisioner — do not rely on it to configure a box.

Because the account is shared, credentials must not outlive a session. The
killswitch (`scripts/host/setup-killswitch.sh`) shreds the Claude token, the
`gh` token, and any plaintext git credential store once the user has no live SSH
session. Anything new that authenticates a *person* rather than the machine
belongs in that list.

Session transcripts under `~/.claude/projects/` are deliberately **not** wiped:
Claude Code stores them locally and nowhere else, so deleting them destroys the
developer's own history without protecting anything. They are plaintext and
readable by the next person on the account — so keep sensitive specifics out of
prompts on a shared box.

Treat the killswitch as **hygiene, not a security boundary**: a peer with sudo
can disable it. The durable fix is per-developer accounts, which is an
organisational change rather than a repository one.

### Provisioning must not lie

A step that fails must not be reported as success. `host_fail` records a failed
golden-state step; the provisioner then prints a summary, skips the completion
marker, and exits non-zero, so a re-run retries instead of short-circuiting on
"Already provisioned". Never downgrade a real failure to a bare warning to get a
clean run — a silent `|| host_warn` is what previously hid a tool that had never
installed on any box.

Bump `PROVISION_VERSION` whenever the provisioning steps change, so boxes that
already carry a marker re-provision.

### `.env` only works because something loads it

`.env.example` is copied to `.env` by `setup-day0.sh`, but for a long time
nothing read the result. Every consumer took its values straight from the
environment — `route-model.sh` still opens with
`LOCAL_MODEL_ENABLED="${LOCAL_MODEL_ENABLED:-false}"` — so the file was
decoration. `scripts/lib/load-env.sh` closes that gap and the routing entry
points (`route-model.sh`, `delegate-local.sh`, `local-health.sh`,
`ask-local.sh`) source it.

The failure was surface-specific, which is why it survived so long. In the
devcontainer, `devcontainer.json` sets `LOCAL_MODEL_ENABLED` and
`LOCAL_MODEL_ENDPOINT` through `containerEnv`, so local routing worked and
looked configured. On a remote box there is no `containerEnv` — `.env` is all
there is — so `route-model.sh` fell through to its default and returned
`local_disabled` for every task. This is the exact trap the "What this
repository is" section warns about: an environment variable that only exists in
`devcontainer.json` is not available on a box.

Every variable `containerEnv` does *not* set was inert on **both** surfaces:
`LOCAL_MODEL_MODEL`, the timeouts, `LOCAL_MODEL_MIN_TPS`, `LOCAL_HEALTH_TTL`,
`CLAUDE_MODEL`, and the `FORCE_*` overrides. Setting `FORCE_LOCAL=true` in
`.env` did nothing at all.

Two properties of the loader matter if you change it:

- **The environment wins over the file.** A variable already set is left alone,
  so `FORCE_CLAUDE=true bash scripts/route-model.sh …`, CI, and `containerEnv`
  keep overriding `.env` rather than being overwritten by it.
- **The file is parsed, not sourced.** `.env` is developer-authored, so sourcing
  it would execute its contents on every routing decision. Only `KEY=VALUE`
  lines are honoured. `scripts/lib/subsystems.sh` refuses to source
  `template.conf` for the same reason.

`check-day0.sh` asserts the plumbing rather than the file. Checking that `.env`
exists reported OK for a subsystem that had never worked — the same shape as the
provisioning failure in "Provisioning must not lie". It now fails when
`route-model.sh` does not source the loader, and warns when local routing is
switched off, so the reported state matches the routed state.

Note that these are template-owned scripts. If a template sync reverts the
loader, `check-day0.sh` fails on "`.env` values reach the routing scripts"
rather than going quiet — but the fix belongs upstream in the template, since
the template ships both the `.env.example` and the scripts that ignored it.

### sudo is for one step, not for the whole run

`provision-remote-box.sh` is invoked with `sudo` because the killswitch needs
root. Everything else it does is user-level — VSCode server extensions, the
Machine `settings.json`, caveman, the Claude plugin set, git config, the docker
group — and under `sudo`, `$HOME` is `/root`.

Using it provisioned root instead of the developer, on every box, silently:
extensions reported "not found" because the search looked in
`/root/.vscode-server`; ansible settings were merged into
`/root/.config/Code/User/settings.json`, a file no VSCode session reads; plugins
would have installed into `/root/.claude`; and the docker-group step offered to
add *root* to the docker group, which is meaningless.

`scripts/host/lib/host-common.sh` resolves `CLAUDE_TARGET_USER` and
`CLAUDE_TARGET_HOME` — who the work is *for*, whether or not the script was
elevated — and `run_as_target` runs a command as them with the right `HOME`.
Any user-level step added to a host script must go through it. The run announces
the target user, and warns when that target is root.

Two related traps in the same family: `code` is not on `PATH` on a Remote-SSH
box (the shim lives under the VSCode server directory in the developer's home,
so `command -v code` alone reports no CLI on boxes that have one), and `sudo`
strips `SSH_AUTH_SOCK`, so an agent check run as root says nothing about whether
forwarding works.

### Two traps in the local-model config

Both were live for the whole life of the routing subsystem and neither failed
loudly, which is why they survived.

**Model names contain colons.** `route-model.sh` prints `provider:model:reason`,
and every real Ollama tag — `qwen2.5-coder:7b` — has a colon in the middle field.
`delegate-local.sh` split that string left to right, so the model was truncated at
its first colon: the health preflight probed a model called `qwen2.5-coder` while
routing had selected `qwen2.5-coder:7b`. Ollama resolves an untagged name by
prefix, so `model_present` still passed and the only symptom was an occasional
unexplained `health:probe_timeout` served from a health cache keyed to the wrong
name. Provider and reason never contain a colon; the model may — so parse from
both ends and treat the remainder as the model. `scripts/tests/test-delegation.sh`
asserts the full tagged name reaches both the route log and the health cache.

**A base model is not an instruct model.** The template shipped
`LOCAL_MODEL_FAST_MODEL=qwen2.5-coder:1.5b-base`. Base models have had no
instruction tuning: given "Reply with the single word OK" they *continue* the
text rather than obeying it. The output is fluent English, so it passes the empty
and degenerate output checks in `delegate-local.sh` and is returned as a
successful delegation. Every fast-path task got plausible nonsense. Never put a
`:*-base` tag in either model variable.

### Local routing is an optimisation, not a dependency

When the endpoint is unreachable, `route-model.sh` returns
`claude:…:local_unreachable_fallback` and `delegate-local.sh` exits 3. Work still
gets done — by Claude. Nothing in the harness may treat an absent local model as
a blocker.

`check-day0.sh` reports that state honestly without failing on it: on a box,
enabled-but-unreachable is a WARN whose text says everything is routing to
Claude. `LOCAL_MODEL_REQUIRED=true` turns it into a FAIL, for a developer who has
decided the local model is load-bearing for them. That is the compromise between
this rule and "Provisioning must not lie" — the report always states what is
actually happening; only its severity is the developer's choice.

### Build-tooling commands are confirmed manually

Set by the repository owner, 2026-08-27:

> Every tool command is confirmed manually until there are protections against a
> model — Claude or local — accidentally running a destructive or high-cost
> command.

The tooling on a dev box deploys to a live range. Nothing in this repository may
invoke it without a human saying yes to that specific invocation. That applies to
Claude, to any subagent, and to the local model, which has no judgement about
consequences at all.

Practical consequences for anything built here:

- A wrapper around the tooling ships **confirming everything**. An empty
  allow-list is the supported configuration, not a placeholder to be filled in
  later by whoever implements it.
- `ASSUME_YES`, `--yes` and equivalents must not reach that gate. A
  non-interactive caller is **refused**, never auto-approved — the whole point is
  that a human is present.
- Exempting a verb is the owner's decision, made per verb, after a classifier and
  its tests exist. It is not a judgement call for whoever is writing the code.

Classification needs **two** axes, not one. Destructive-versus-read-only is
insufficient: a whole-range deployment may destroy nothing and still be something
no one wants triggered by a misread instruction, because it consumes real time
and real infrastructure. A verb is a candidate for exemption only when it is low
on both **blast radius** (what it changes, and whether that is reversible) and
**cost** (what running it consumes, and who pays).

Pattern-matching command strings is not a protection — quoting and environment
prefixes defeat it, and it looks enforced while not being. See the provisioning
rule above for the same failure shape.

#### The tool bridge (`scripts/ctp-bridge.sh`)

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

#### Secrets and transcripts

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

### Accidental commits: the warn-only commit guard

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

### The destructive-action gate

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
  the single choke point any executor routes through. Claude's hook is enforcement
  point #1; a future local-model orchestrator calls the same lib rather than a
  second copy. It stops the accidental and the misread-instruction cases; an
  adversarial model can still obfuscate around string classification, so like the
  secret-read hook it is defense-in-depth, not a sandbox — the real containment is
  OS-level, which the shared-sudo box does not provide (accepted risk).
  `check-day0.sh` reports it honestly on a box.

### Keeping Org PII/IP out of Claude: the path guard

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
  tunes independently — and one a future local-model front-door may be allowed to
  read while Claude is not. Keeping them apart preserves that. **Empty is the
  default (opt-in):** nothing is denied until the owner lists the directories
  where Org data lives. The deny is **symmetric** (read *and* write) because a
  PII/IP directory is a boundary the agent should not touch at all.
- **It is path-based, and honest about that.** PII sitting inside a file *outside*
  the listed globs is not caught, and the guard does not redact PII embedded in an
  otherwise-readable file's output — hooks cannot rewrite output regardless. That
  intelligent, content-level sanitisation is the job of the local-model
  orchestrator (G3): the local model reads/handles sensitive content and rephrases
  before Claude ever sees it, which *does* cover tool output because the local
  model is the reader. Until then this is the same defense-in-depth, accepted-risk
  framing as the secret-read hook — the real containment is OS-level, which the
  shared-sudo box does not provide. `check-day0.sh` asserts the capability is
  present on a box (a stale install predating it FAILs).

### The local-model orchestrator (G3, experimental spine)

`scripts/orchestrator/orchestrate.sh` is the front door for routing a prompt to
the right model: it decides whether a task stays on the **local fleet** or hands
off to a more capable model (e.g. Claude via `claude -p`, where the A/B gates and
caveman still apply). The decision logic is a pure, unit-tested lib
(`scripts/lib/orchestrator-route.sh`); the config is a gitignored on-box file
(`~/.config/orchestrator.conf`, parsed never sourced) holding a mode and a model
registry (name · tier · capability rank · endpoint).

The reason this control exists is one **non-negotiable, structural invariant**:

> **Sensitivity gates tier eligibility before capability ranking.** A task the
> router treats as sensitive is never eligible for the frontier (cloud) tier,
> however capable — the cloud endpoint is removed from the eligible set, so the
> picker cannot choose it. `orchestrate.sh` also re-asserts this immediately
> before dispatch and refuses (exit 4) rather than egress a sensitive task.

Three modes, owner-controlled: `AUTO` (classify, then route), `LOCAL-ONLY` (the
human seatbelt — nothing egresses), `CLAUDE-ONLY` (the human asserts cloud is
acceptable). What matters if you change it:

- **Fail closed.** The sensitivity classifier is a local-LLM judge (deferred to
  its own spec + eval); until it lands it is stubbed to return *sensitive*, and
  any classifier error/timeout resolves to *sensitive*. AUTO therefore never
  egresses on a guess. There is **no** deterministic hard-floor (owner decision):
  an LLM that mislabels a sensitive query as safe can still egress — the accepted
  residual risk, mitigated by `LOCAL-ONLY` + fail-closed. Do not "optimise" the
  stub to a permissive default.
- **The log records metadata only.** `mode/sensitive/tier/model` go to
  `.ai/orchestrator-log.jsonl` — never the prompt text, which may be the sensitive
  content the control exists to protect (same reasoning as the ctp and commit-
  guard logs).
- **Deferred slices** (see `_bmad-output/planning-artifacts/architecture-g3-local-orchestrator.md`):
  the local LLM classifier, the sanitiser (rephrase before a cloud handoff — the
  overlap with control C2), the LiteLLM multi-machine pool, and the local shell
  executor (which will route through `safety-guard.sh` as enforcement point #2).

### Network changes are deliberate

Adding an outbound host to the devcontainer firewall goes through
`/firewall-allow`. Per `CLAUDE.md` this is a hard escalation trigger and must
never be routed to a local model.

Note that the firewall pins hostnames to the IPs resolved at container start, so
a CDN-hosted host can drift and need a rebuild.

The firewall is **IPv4-only, deliberately**. IPv6 egress is denied wholesale,
and `allowed-domains` can only ever learn IPv4 addresses — it skips IPv6 CIDRs
from the GitHub meta feed and resolves A records only. To stop processes
attempting a route that is guaranteed to be refused, the image raises the glibc
precedence of IPv4-mapped addresses in `/etc/gai.conf` so `getaddrinfo` returns
A records first.

That pairing matters: without it, any host publishing AAAA records is resolved
to IPv6 first, rejected in about two milliseconds, and the Claude CLI drops
mid-session with `ECONNRESET`. Diagnose with:

```bash
getent ahosts api.anthropic.com   # IPv4 must sort first
curl -4 -sS -o /dev/null -w 'v4: %{http_code}\n' https://api.anthropic.com/v1/messages
curl -6 -sS -o /dev/null -w 'v6: %{http_code}\n' https://api.anthropic.com/v1/messages
```

Use `ahosts`, not `hosts`: `getent hosts` resolves through the NSS `hosts` map
and does not apply RFC 3484 sorting, so it can still report an IPv6 address
even when the precedence setting is working. `getent ahosts` goes through
`getaddrinfo`, which is what applications use and what `gai.conf` governs.

A working v4 alongside a v6 that fails in milliseconds is this, not a network
fault. If IPv6 egress is ever required, the ipset and the resolver precedence
must change together — changing either alone recreates the dead path.

### Reading the debug log: expected noise vs a real failure

`~/.claude/debug/<session-id>.txt` is loud in this container, and most of the
noise is the firewall doing its job. Distinguish the two classes before
investigating anything.

**Expected — telemetry the firewall deliberately blocks.** These hosts are not in
`allowed-domains` and never will be; the errors are the deny-by-default policy
working, not a symptom:

- `Failed to flush logs to Datadog: ... connect ECONNREFUSED`
- `[3P telemetry] OTEL diag error: Failed to export N events`
- `1P event logging: N events failed to export`
- `CCRClient: internal events failed` / `client events failed`
- `MCP server "ide" Connection failed: WebSocket is not open` — the VS Code
  bridge, cosmetic
- YAML frontmatter errors under `.claude/skills/bmad-*` — BMAD-installed content,
  gitignored (`.gitignore:26`), not fixable here; report upstream

**A real API failure** looks like this instead, and carries an id meant for
Anthropic support:

```bash
grep -E "API error \(attempt|turn ended in error|x-client-request-id" \
  ~/.claude/debug/<session-id>.txt
```

`x-client-request-id` is emitted specifically so the API team can find the
server-side record. When local measurement has been exhausted, that id — not
another configuration change — is the next step.

Do not allowlist the telemetry endpoints to quieten the log. Opening egress to
reduce noise is the wrong trade in a deny-by-default container.

### If you see `ECONNRESET`

The failing shape is a full retry ladder — `API error (attempt 1/11)` through
`attempt 11/11`, then `API connection_error after retries` and `[engine] turn
ended in error: API Error: Connection dropped (ECONNRESET)`. Auto-mode tool
classification fails closed in the same window, so tools start being denied with
retry guidance; that is a consequence, not a second fault.

**Check the one cause that is in this repository first.** Run the `getent
ahosts` / `curl -4` / `curl -6` triple from the section above. If IPv4 does not
sort first, or v6 fails in milliseconds while v4 works, this is the resolver
precedence pairing and it is fixable here.

If IPv4 sorts first and `curl -4` returns a response, the repository is not
involved. A full day of measurement has already ruled out everything below —
re-running it is a day nobody gets back:

| Eliminated | How |
| --- | --- |
| DNS and IPv6 | `getent ahosts` sorts v4 first; `curl -4` succeeds |
| Firewall and ipset membership | Destination resolves into the allowed ipset; rule counters increment on ACCEPT, and nothing lands on the deny rules |
| MTU / path MTU black hole | 1500-byte don't-fragment probes round-trip cleanly, so no fragmentation-needed message is being swallowed |
| Docker networking | Reproduced identically from the host, outside any container |
| Throughput and connection duration | Bulk downloads and deliberately slow-trickled long-lived transfers both sustain without a reset |
| Router IPS / ad-blocking | Router logs show zero blocks against the destination across the entire failure window |

**What that leaves is upstream transit**, and the discriminator is this: a VPN
egress path reaching the *same destination address* succeeds while the direct
path fails. Same destination, same client, same request — only the transit
differs. That isolates the fault to a hop between this network and the
destination. No devcontainer, firewall, MTU or DNS change can reach it, and
proposing one is how this loops back to the start.

The workaround is a destination-scoped policy route at the network edge, which
lives outside this repository by design — routing an egress path is not a
container concern, and the repository is public.

For the escalation path, pull `x-client-request-id` out of the debug log. Every
failed request emits one so Anthropic support can find the server-side record;
once local measurement is exhausted that id is the next step, not another
configuration change.

### Pinning third-party installers

Installers fetched from upstream are pinned to a specific tag, and the commit
that tag resolves to is recorded alongside it. Before installing, the script
confirms the tag still points at that commit and refuses to install on drift,
rather than executing code nobody reviewed. Pinning a wrapper that then fetches
an unpinned default branch is not a pin — pin the code that actually executes.

## Verification

- `bash scripts/check-day0.sh` (or `/day0-check`) — day-0 state on either surface.
- `bash scripts/validate-template.sh` — template invariants; runs in CI.
- `pre-commit run --all-files` — covers gitleaks and semgrep. Run locally before
  opening a pull request; the CI gates run the same tools but not the hook set.
