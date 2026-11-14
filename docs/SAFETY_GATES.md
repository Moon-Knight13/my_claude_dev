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
it happens in the range checkout (e.g. `~/catapult/inventories/range`), and a hook
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

---

## Hook architecture — complete reference

This section documents every Claude Code hook registered in
`.claude/settings.json`, the guard libraries they compose, their interaction
with modes, and known edge cases. The hook configuration is the single source
of truth; this section explains what each hook does and why.

### Hook registration overview

Hooks are registered in `.claude/settings.json` under four lifecycle events.
Execution order within an event is top-to-bottom as listed in the JSON array.
A hook with an empty `matcher` fires for every tool call; a non-empty matcher
fires only when the tool name matches (pipe-delimited for multi-tool matchers).

| Event | Matcher | Hook file | Purpose |
|---|---|---|---|
| `UserPromptSubmit` | `""` | `scripts/hooks/secret-scan.sh` | Block prompts containing secrets |
| `UserPromptSubmit` | `""` | `scripts/hooks/mode-inject.sh` | Inject mode system prompt + skill filter |
| `PreToolUse` | `""` | `scripts/hooks/audit-trail.sh` | Log every tool call (never blocks) |
| `PreToolUse` | `""` | `.claude/hooks/mode-tool-gate.sh` | Deny MCP tools by mode policy |
| `PreToolUse` | `""` | `.claude/hooks/research-dispatch-guard.sh` | Force research MCPs to T3 threads |
| `PreToolUse` | `Bash\|Read\|Write\|Edit` | `.claude/hooks/pretooluse-ctp.sh` | Guard stack: ctp, secrets, PII, destructive ops, git |
| `PreToolUse` | `Bash` | `.claude/hooks/tuoni-secret-guard.sh` | Block Bash access to Tuoni secret paths |
| `PostToolUse` | `""` | `scripts/hooks/response-scanner.sh` | Warn on secrets in tool output |
| `PostToolUse` | `mcp__tuoni-mcp__tuoni_command_get` | `.claude/hooks/auto-log-finding.sh` | Prompt `/log-finding` on actionable results |
| `Stop` | `""` | `.claude/hooks/session-end-audit.sh` | Audit engagement YAML for gaps |

**Note:** `scripts/hooks/pretooluse-source-priority.sh` exists on disk but is
**not registered** in `settings.json`. It was an experimental source-priority
warning for red-team mode (warn when Tier 3 reference MCPs are queried before
Tier 1 authoritative sources). It reads `CLAUDE_TOOL_NAME` from the
environment, which is not how PreToolUse hooks receive the tool name (they read
JSON from stdin) — so it would not function if registered. Treat it as dormant.

### Exit protocol

All hooks follow the Claude Code hook protocol:

- **Exit 0 + JSON `permissionDecision: "deny"`** — hard block, tool call
  refused with a reason shown to the operator.
- **Exit 0 + JSON `permissionDecision: "ask"`** — the operator is prompted to
  confirm before the tool call proceeds. With no human present, `ask` resolves
  to `deny` (fail closed).
- **Exit 0 + no output** — no opinion; other hooks and permissions decide.
- **Exit 2** — blocking error; Claude Code treats this as a hard block.
- **Exit 0 + `notification`** (PostToolUse only) — informational message shown
  to the operator; cannot block.

### UserPromptSubmit hooks

#### `secret-scan.sh` — prompt secret scanner

**Trigger:** Every prompt submission (empty matcher).

**Logic:** Two detection layers run on the prompt text:
1. Custom regex: key-value patterns (`password:`, `token:`, `api_key:`, etc.)
   with non-empty, non-templated values; private key blocks; Vault tokens
   (`hvs.*`, `s.*`); common API token formats (GitHub PAT variants, Anthropic,
   OpenAI, AWS, Slack, Stripe, generic Bearer tokens); Ansible output with
   embedded passwords.
2. `gitleaks` stdin scan: runs the repo's `.gitleaks.toml` rules if `gitleaks`
   is installed. Catches the 100+ default secret patterns plus custom rules.

**Verdict:** BLOCK (exit 2) on any match. The blocked message names the
pattern, never echoes the value.

**Bypass:** Prefix the prompt with `NOSECRET:` to skip scanning. The prefix is
stripped before forwarding. Use only for confirmed false positives.

**False positives:** Template placeholders (`{{ }}`, `<% %>`, `<redacted>`,
`***`, `null`, `None`, `changeme`, `your_*`, `example*`, `placeholder*`,
`xxx*`, `TODO*`) are exempt. Regex-matched values with these patterns are
skipped.

**Edge case — gitleaks absent:** When `gitleaks` is not installed, only layer 1
runs. The scan is not silently a no-op — layer 1 still catches common patterns —
but the 100+ gitleaks rules are missing. `check-day0.sh` warns if gitleaks is
absent.

#### `mode-inject.sh` — mode system prompt injection

**Trigger:** Every prompt submission (empty matcher).

**Logic:** Reads `.claude/.active-mode` to determine the current mode. Supports
per-thread mode overrides via `.claude/.mode-overrides/$SESSION_ID`. Loads the
mode's system prompt from `.claude/modes/<mode>/system-prompt.md` and injects
it as `additionalContext`. Also scans `.claude/skills/*/SKILL.md` for `modes:`
frontmatter matching the active mode and emits a filtered skill list.

**Mode interaction:** This is how mode rules reach the model. No mode file =
no injection (silent pass). Mode switching via `/mode` writes
`.active-mode`; the hook picks it up on the next prompt with no restart.

**Edge case — MCP servers:** Mode-specific MCP server changes require a
restart; they are configured in `.mcp-<mode>.json` at launch by
`start-mode.sh`, not by this hook.

### PreToolUse hooks

Hooks fire in registration order. For the empty-matcher group:
`audit-trail.sh` → `mode-tool-gate.sh` → `research-dispatch-guard.sh`.
Then, if the tool matches `Bash|Read|Write|Edit`: `pretooluse-ctp.sh`.
Then, if the tool is `Bash`: `tuoni-secret-guard.sh`.

A `deny` from any hook stops the chain — later hooks do not fire.

#### `audit-trail.sh` — structured tool call logging

**Trigger:** Every tool call (empty matcher, runs first).

**Logic:** Appends one JSON line to `.claude/audit/tool-calls.jsonl` with:
timestamp, active mode, tool name, parameter keys (never values — values may
contain secrets), and MCP server name (if applicable).

**Verdict:** Always exit 0, no output. Never blocks. Pure logging.

**Edge case:** If the audit directory cannot be created or the log file cannot
be written, the hook silently continues (errors suppressed with `|| true`).
Audit logging is best-effort.

#### `mode-tool-gate.sh` — mode-based MCP tool deny

**Trigger:** Every tool call (empty matcher).

**Logic:**
1. Read active mode from `.claude/.active-mode`.
2. Check for per-thread mode override in `.claude/.mode-overrides/$SESSION_ID`
   (T3 child threads).
3. Load the mode's `tool-policy.yaml` from `.claude/modes/<mode>/tool-policy.yaml`.
4. Parse the `deny:` list of glob patterns (fnmatch-style).
5. Match the tool name against each deny pattern. Prefix globs (`mcp__tuoni*`)
   and exact matches are supported.

**Scope:** Only gates MCP tools (`mcp__*`). Built-in tools (Bash/Read/Edit/Write)
pass through — they are handled by `pretooluse-ctp.sh` and `tuoni-secret-guard.sh`.

**Mode interaction:** This is the enforcement layer for mode tool policies.
Each mode's `tool-policy.yaml` defines which MCP tools are denied. No mode
file or no policy file = no denials (silent pass).

**Edge case — YAML parsing:** Uses lightweight Python parsing, not a YAML
library. Handles `deny:` followed by `- "pattern"` lines. Non-standard YAML
formatting may not parse correctly.

#### `research-dispatch-guard.sh` — research thread enforcement

**Trigger:** Every tool call (empty matcher).

**Logic:**
1. Check if `.claude/.research-gate-active` exists. Absent = gate inactive.
2. Check if session has a mode override file (T3 child threads get one).
   Override present = this IS a dispatched thread, allow everything.
3. Parse tool name from stdin JSON.
4. Only gate MCP tools (`mcp__*`).
5. Match against research MCP prefixes.

**Research MCP prefixes (denied in master session when gate active):**
- `mcp__ghidra-mcp__`
- `mcp__gtfobins-mcp__`
- `mcp__hacktricks-mcp__`
- `mcp__mitre-mcp__`
- `mcp__range-intel-mcp__providentia_`
- `mcp__range-intel-mcp__readme_`
- `mcp__velociraptor-mcp__`
- `mcp__wazuh-mcp__`

**Bypass conditions (any one skips the gate):**
1. Flag file `.claude/.research-gate-active` absent.
2. Tool is not a research MCP.
3. Session has a mode-override file (T3 child threads).

**Activation:** The flag file is created by the operator or the
`engagement-orchestration` skill. Presence alone is the trigger — the file's
content is never read.

**Override:** Delete `.claude/.research-gate-active`.

**Edge case — non-research range-intel tools:** The guard blocks
`mcp__range-intel-mcp__providentia_*` and `mcp__range-intel-mcp__readme_*` but
passes other range-intel tools (if any exist) through. The prefix list is
intentionally specific.

**Edge case — mode-override detection:** The guard treats ANY session with a
mode-override file as a dispatched thread. A manually created override file
would bypass the gate.

#### `pretooluse-ctp.sh` — the guard stack entry point

**Trigger:** `Bash|Read|Write|Edit` tools only.

**Logic:** This is enforcement point #1 for the guard stack. It parses the tool
call JSON, delegates to `scripts/lib/guard-stack.sh` for classification, and
renders the verdict in the hook protocol.

**Fail-closed design (issue #87):** If the guard stack cannot be found or its
required layers fail to load, every call is DENIED with a diagnostic reason.
The ERR trap exits 2 (blocking error), so unexpected failures also block rather
than fail open.

**Guard stack resolution:** Searches in order:
1. `$GUARD_STACK_LIB` environment override
2. `~/.local/lib/ctp-bridge/guard-stack.sh` (installed user-scope)
3. Next to the hook file itself
4. `../../scripts/lib/guard-stack.sh` (repo layout)

**For Read/Write/Edit tools:** Extracts `file_path` from tool input, classifies
via `guard_stack_classify_path()`. Denies secret paths, PII paths, and the
approval token file.

**For Bash tool:** Extracts `command` from tool input, classifies via
`guard_stack_classify_command()`. If the verdict is `ask` for a ctp-bridge
invocation, writes a single-use, argv-bound, 180-second TTL approval token so
the wrapper can run without a second (impossible, no-TTY) confirmation prompt.

**Edge case — .env loading:** Sources `load-env.sh` before the guard stack,
making `GUARD_*` environment variables from `.env` available. This extends
secret and PII path lists (additive only — can only make content guarded,
never remove protection) and replaces safety/git allowlists when set.

#### `tuoni-secret-guard.sh` — Tuoni credential path guard

**Trigger:** `Bash` tool only.

**Logic:** Regex-matches the Bash command against Tuoni secret paths:
- `tuoni-live/(config|ssl)/` and `/srv/tuoni/(config|ssl)/`
- Files matching `*.pem`, `*.keystore`, `*.jks` under either path
- `tuoni-db.sqlite3`

**Verdict:** DENY if any pattern matches. The deny message directs to the tuoni
MCP for read access and the operator's terminal for config edits.

**Edge case — string matching limitation:** This hook uses `grep -Eiq` on the
raw command string, not the segmented command word. Unlike `pretooluse-ctp.sh`
(which uses `cmd-segment.sh` for proper segmentation), this hook can be
bypassed by obfuscation (variable expansion, indirect paths). It is
defense-in-depth, not a sandbox — consistent with the accepted-risk framing
throughout.

**Edge case — overlap with pretooluse-ctp.sh:** The `CTP_SECRET_PATHS` config
can also guard these paths via the guard stack. Both hooks fire independently
for Bash commands. The tuoni guard is a targeted, self-contained backup that
works even if the guard stack is not installed.

### PostToolUse hooks

#### `response-scanner.sh` — tool output secret scanner

**Trigger:** Every tool call (empty matcher).

**Logic:** Scans tool output for the same secret patterns as `secret-scan.sh`:
private keys, API tokens (GitHub, Anthropic, OpenAI, AWS, Slack, Stripe, Vault),
key-value secret patterns. Scans only the first 200 lines for performance.

**Verdict:** Always exit 0. PostToolUse CANNOT block — the tool output has
already been returned and entered the model's context. Emits a notification
warning the operator and logs to `.claude/audit/secret-detections.jsonl`.

**Important limitation:** By the time this hook fires, the secret is already in
the model's context. The hook exists for operator awareness and audit trail,
not prevention. Prevention is the PreToolUse hooks' job (blocking reads of
secret paths before they happen).

#### `auto-log-finding.sh` — engagement finding detector

**Trigger:** `mcp__tuoni-mcp__tuoni_command_get` only.

**Mode guard:** Only fires in `red-team` or `purple` mode. All other modes
exit immediately.

**Logic:** Scans Tuoni command output for actionable findings across six
categories: credentials/hashes, host discovery, access gained, service
enumeration, sensitive file access, lateral movement indicators. On match,
emits a notification prompting the operator to invoke `/log-finding`.

**False positive tolerance:** Patterns are intentionally broad. False positives
are cheap (just a suggestion to log); false negatives lose knowledge.

### Stop hooks

#### `session-end-audit.sh` — engagement documentation gap check

**Trigger:** Session end (Stop event, empty matcher).

**Logic:** Finds the most recent engagement YAML in `engagements/`. Checks for:
- Techniques tried with 0 findings recorded.
- Technique count exceeding finding count (gap).
- Credential techniques logged with 0 credential refs in Tuoni store.
- Missing `plugin_inventory` field.

**Verdict:** Informational only (stdout warnings). Not a hard gate.

### The guard stack (`scripts/lib/guard-stack.sh`)

The guard stack is the composed classification policy shared between two
enforcement points: the PreToolUse hook (enforcement point #1, fronts Claude's
tools) and the local-model executor (enforcement point #2, does not go through
Claude). Sharing the policy prevents drift.

**Layer composition order (per command segment):**

1. **`cmd-segment.sh`** — Quote/heredoc/subshell-aware segmentation. Splits
   commands on `;`, `|`, `||`, `&&`, newlines. Descends into `$(…)`, backticks,
   `<(…)`/`>(…)` process substitutions, and `( subshells )`. Single-quoted
   strings are left alone (no expansion). Heredoc bodies are skipped.
2. **`ctp-guard.sh`** — Build tooling classification. Denies bare `ctp`,
   `docker exec` into the catapult container, `make start/restart/stop`,
   `secrets` verb. Classifies wrapper calls as `ask` with argv binding.
3. **Guarded paths** — Secret paths (`CTP_SECRET_BUILTIN` + configured
   `CTP_SECRET_PATHS`) and the approval token file. Denied in ALL modes.
4. **PII paths** — Org PII/IP paths (`CTP_PII_BUILTIN` + configured
   `CTP_PII_PATHS`). **Mode-dependent:** denied in `hook` mode (keeps PII out
   of Claude's transcript), allowed in `executor` mode (the local executor's
   purpose is reading that material without egress).
5. **`safety-guard.sh`** — Destructive filesystem/infra/database commands.
   Optional layer (absent = skipped). Verdict is `ask`.
6. **`git-guard.sh`** — Destructive git operations. Optional layer (absent =
   skipped). Verdict is `ask`.

**First verdict wins.** Once any layer returns a non-empty verdict for a
segment, no further layers are checked for that segment.

**GUARD_STACK_VERDICT** is set as a global (not captured via `$(…)`) to
preserve the approval argv side-effect. A subshell capture would discard the
approval token binding silently.

### The `.env` guard — `CTP_SECRET_BUILTIN`

The built-in secret path floor is hardcoded and **never overridable** from
config or environment:

```
CTP_SECRET_BUILTIN='**/.env ~/.ssh/id_* ~/.gnupg/**'
```

- `**/.env` — matches `.env` files at any depth. API tokens, passwords,
  database credentials live here.
- `~/.ssh/id_*` — SSH private keys.
- `~/.gnupg/**` — GPG keyrings and signing material.

These are always denied for both Read/Write/Edit (path classification) and
Bash (token-level scan of command arguments). The built-in list is NOT a
default for `CTP_SECRET_PATHS` — it is checked separately, so configuring
`CTP_SECRET_PATHS` never replaces the built-in floor.

Similarly, `CTP_PII_BUILTIN` always guards `~/.config/orchestrator/*`
(classifier prompt, sanitiser prompt, term list) regardless of what
`CTP_PII_PATHS` is configured to.

### `.env` integration via `load-env.sh`

The hook loads `.env` via `scripts/lib/load-env.sh` before the guard stack.
`GUARD_*` variables from `.env` modify guard behavior:

| Variable | Effect |
|---|---|
| `GUARD_SECRET_PATHS` | **Extends** (appends to) `CTP_SECRET_PATHS`. Additive only. |
| `GUARD_PII_PATHS` | **Extends** (appends to) `CTP_PII_PATHS`. Additive only. |
| `GUARD_SAFETY_ALLOWLIST` | **Replaces** `_SAFETY_ALLOWLIST`. Authoritative when set. |
| `GUARD_GIT_ALLOWLIST` | **Replaces** `_GITGUARD_ALLOWLIST`. Authoritative when set. |

Path lists extend (more protection). Allowlists replace (the `.env` list is
authoritative). The asymmetry is intentional: extending paths can only make
content guarded; replacing allowlists lets the operator tune exemptions per
environment.

### Mode interaction summary

| Hook | Checks mode? | How |
|---|---|---|
| `mode-inject.sh` | Yes | Reads `.active-mode`, injects mode system prompt |
| `mode-tool-gate.sh` | Yes | Reads `.active-mode` + overrides, enforces `tool-policy.yaml` deny list |
| `research-dispatch-guard.sh` | Indirect | Checks mode-override file presence (not mode name) |
| `auto-log-finding.sh` | Yes | Only fires in `red-team` or `purple` mode |
| `pretooluse-ctp.sh` | No | Guard stack is mode-agnostic at the hook level |
| `tuoni-secret-guard.sh` | No | Always active regardless of mode |
| `secret-scan.sh` | No | Always active regardless of mode |
| `response-scanner.sh` | Yes | Logs active mode to audit trail |
| `audit-trail.sh` | Yes | Logs active mode to audit trail |
| `session-end-audit.sh` | No | Checks engagement YAML, not mode |

### Known edge cases and gaps

1. **String-matching limitations.** `tuoni-secret-guard.sh` uses raw `grep` on
   the command string. Variable expansion, indirect paths, or encoded
   references can bypass it. The guard stack (`pretooluse-ctp.sh`) uses proper
   command segmentation, but segmentation is still best-effort — it is hygiene,
   not a sandbox.

2. **Heredoc in nested context.** `cmd-segment.sh` tracks heredocs only at the
   top level. A heredoc opened inside a command substitution —
   `x=$(cat <<EOF ... EOF)` — is not registered, so its body is parsed as
   commands. This fails CLOSED (may false-deny a body line starting with a
   guarded word), never open.

3. **PostToolUse cannot block.** `response-scanner.sh` detects secrets in tool
   output but cannot prevent them from entering the model's context. The tool
   result is already returned when PostToolUse fires. Prevention relies
   entirely on PreToolUse hooks blocking the read.

4. **`pretooluse-source-priority.sh` is dormant.** Exists on disk but not
   registered in `settings.json`. Uses `CLAUDE_TOOL_NAME` env var instead of
   stdin JSON — would not function correctly if registered. Also reads mode
   from the wrong location (`settings.json._mode` instead of `.active-mode`).

5. **Mode-override file as bypass.** `research-dispatch-guard.sh` treats any
   session with a `.claude/.mode-overrides/$SESSION_ID` file as a dispatched
   thread. A manually created override file bypasses the research gate.

6. **200-line scan limit.** `response-scanner.sh` scans only the first 200
   lines of tool output. A secret appearing after line 200 is not detected.

7. **gitleaks dependency.** `secret-scan.sh` layer 2 requires `gitleaks` to be
   installed. When absent, only regex-based detection (layer 1) runs.
   `check-day0.sh` warns about this.

8. **Approval token TTL.** The ctp-bridge approval token has a 180-second TTL.
   If the Bash tool execution is delayed beyond 3 minutes after the hook's
   `ask` prompt is confirmed, the wrapper rejects the stale token. The
   operator must re-invoke.

9. **PII path mode-dependence.** PII paths are denied only in `hook` mode
   (Claude's transcript), not `executor` mode (local model). If a tool call
   is routed through the executor path, PII paths are accessible. This is by
   design (decision E5) — the executor's purpose is reading that material
   without egress.

10. **`NOSECRET:` bypass is logged but not gated.** Anyone who can type a
    prompt can bypass `secret-scan.sh` by prefixing `NOSECRET:`. The bypass is
    logged to stderr. This is intentional — the scan catches accidental
    inclusion, not determined actors.
