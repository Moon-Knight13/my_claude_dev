# The Safety Harness in Active Use

This is what the repository *does* when Claude is working on a remote dev box:
a set of controls that sit between the agent and the box and turn the risky
actions into a human decision — or refuse them outright — **while you watch**.
This page explains each control in active usage and gives you a copy-paste way
to **demonstrate** every one of them firing.

> Source of truth for the rules is [`PROJECT.md`](PROJECT.md); this page is the
> operator/demonstrator view. The audience-facing visual version is the
> [explainer](explainer/index.html).

## What the harness is — and is not

A **proportionate, defense-in-depth, human-in-the-loop** wrapper around an agent
on a shared box. It is deliberately **not** a sandbox and **not** OS containment.
The boxes are a shared account where everyone has sudo, so the OS offers no
isolation between the agent and the operator — that is an **accepted risk**
(see *Operating environment* in `PROJECT.md`). The harness stops the
**accidental** and the **misread-instruction** cases and puts a human in the
loop for the dangerous ones; a determined, adversarial model could still
obfuscate around string-based classification. We say so plainly rather than
overclaim a boundary we do not have.

## The threat model — four "what if" worries

The harness is built backwards from the things a developer is actually worried an
agent might do:

| # | Worry | Control | Status |
|---|-------|---------|--------|
| 1 | Claude **leaks Org PII/IP** into the transcript | **C1** PII/IP path read-deny + **C2** content redaction | C1 shipped · C2 → G3 |
| 2 | Claude **commits PII/secrets** to a repo | **B** warn-only commit guard | shipped |
| 3 | Claude runs a **destructive command** (deletes a database, tears down infra) | **A** destructive-action gate | shipped |
| 4 | Claude makes an **unauthorized web connection** | **D** egress guard | covered by the org network on the box; hook-level D deferred |

Two controls predate this threat-model pass and back all four: the **build-tooling
bridge** (the agent cannot drive the deploy wrapper directly) and the
**secret-read deny** (the agent cannot read credential files). The **killswitch**
handles credential reuse between sessions on the shared account.

## How it works at runtime

Everything hangs off three interception points that are always on once a box is
provisioned:

```
        agent tool call (Read / Write / Edit / Bash)
                          │
                          ▼
        ┌─────────────────────────────────────────────┐
        │  PreToolUse hook  ~/.claude/hooks/            │
        │  pretooluse-ctp.sh   (fires BEFORE the tool)  │
        │                                               │
        │   • guarded path?      → deny  (secret / PII) │
        │   • bare ctp / docker? → deny  (use bridge)   │
        │   • ctp bridge call?   → ask   (human confirm)│
        │   • destructive cmd?   → ask   (fail closed)  │
        │   • otherwise          → no opinion (allow)   │
        └─────────────────────────────────────────────┘
                          │
              allow / ask / deny  →  the tool runs, prompts, or is refused

        git commit  ──▶  global core.hooksPath pre-commit  ──▶  commit guard
                         (scans staged content; WARNS, never blocks)

        last SSH session ends  ──▶  PAM hook + systemd timer  ──▶  killswitch
                                    (shreds credentials left on the box)
```

The PreToolUse hook runs **outside** the agent's own command, so the agent cannot
edit or disable it. Its boundary values come from a gitignored on-box config file
(`~/.ctp-bridge.conf`), never from the agent's environment — an agent that could
set an env var in the same call could otherwise rewrite its own limits.

## The controls

| Control | Gates | Verdict | Config |
|---------|-------|---------|--------|
| **Build-tooling bridge** | any attempt to drive `ctp`/`docker exec` into the container directly | `deny` bare access; `ask` for a permitted wrapper verb; `deny` a refused verb | `CTP_ALLOWED_TARGET`, `CTP_ALLOWED_TEAM`, `CTP_ALLOWED_VERBS` |
| **Secret-read deny** | Read/Write/Edit/Bash touching a credential path | `deny` | `CTP_SECRET_PATHS` |
| **A · Destructive-action gate** | `rm -rf`, `shred`, `mkfs`, `dd of=`, `dropdb`, `DROP`/`TRUNCATE`, `terraform destroy`, `kubectl delete`, `docker prune`/`rm -f` | `ask` (→ `deny` with no human) | `~/.config/safety-guard.conf` (`SAFETY_ALLOWLIST`) |
| **C1 · PII/IP path guard** | Read/Write/Edit/Bash touching an Org-data path | `deny` | `CTP_PII_PATHS` |
| **B · Commit guard** | staged secrets/PII on every commit | **warn + log** (never blocks) | global `core.hooksPath` |
| **Killswitch** | credentials left on the box after the last session | shred | PAM + systemd timer |

Not built yet: **C2** (intelligent, content-level PII redaction — belongs in the
local-model orchestrator **G3**, which can redact *tool output* that hooks
cannot), **hook-level D** (egress visibility on top of the org network),
**2b** (warn on destructive git ops — `force-push`, `reset --hard`).

## Demonstrating it on a box

There are two ways to show a control firing. The **deterministic** one needs no
Claude session and is repeatable — best for a demo or a screen-share. The
**natural** one shows what a developer actually experiences in Claude Code.

### Prerequisites

The box has been provisioned (`scripts/host/provision-remote-box.sh`) and
`~/.ctp-bridge.conf` has real values. For the PII demo, add a path first:

```bash
# one-time, so the PII demo has something to catch
echo 'CTP_PII_PATHS=~/org-data/**' >> ~/.ctp-bridge.conf
mkdir -p ~/org-data && echo 'name,email' > ~/org-data/clients.csv
```

Verify the harness is present and honest about itself:

```bash
bash scripts/check-day0.sh    # or, in a Claude session: /day0-check
```

### Deterministic — feed the hook a tool call and read its verdict

The PreToolUse hook takes a tool-call JSON on stdin and prints its decision. This
is exactly how the agent path is gated, so it is a faithful demonstration.

```bash
HOOK=~/.claude/hooks/pretooluse-ctp.sh

# 1. Destructive command  →  ask  (a live session would prompt; no human ⇒ deny)
echo '{"tool_name":"Bash","tool_input":{"command":"rm -rf /srv/data"}}' | "$HOOK"
#   → …"permissionDecision":"ask","permissionDecisionReason":"recursive force delete (rm) — irreversible removal of a directory tree"

echo '{"tool_name":"Bash","tool_input":{"command":"dropdb prod"}}' | "$HOOK"
#   → …"ask"… "dropdb — drops an entire database"

# 2. Reading Org PII/IP  →  deny  (contents never reach the transcript)
echo '{"tool_name":"Read","tool_input":{"file_path":"'"$HOME"'/org-data/clients.csv"}}' | "$HOOK"
#   → …"deny"… "a guarded Org-sensitive (PII/IP) path is off-limits to tools: …/org-data/clients.csv"

echo '{"tool_name":"Bash","tool_input":{"command":"cat ~/org-data/clients.csv"}}' | "$HOOK"
#   → …"deny"… "command would touch a guarded Org-sensitive (PII/IP) path: …"

# 3. Reading a credential  →  deny
echo '{"tool_name":"Read","tool_input":{"file_path":"'"$HOME"'/.ssh/id_ed25519"}}' | "$HOOK"
#   → …"deny"… "a guarded path (secret or approval token) is off-limits to tools: …"

# 4. Bypassing the build-tooling bridge  →  deny
echo '{"tool_name":"Bash","tool_input":{"command":"ctp host deploy trainbox_t02"}}' | "$HOOK"
#   → …"deny"… "reach ctp through scripts/ctp-bridge.sh, not a bare ctp invocation"

# 5. A permitted wrapper verb  →  ask  (the human confirms this exact call)
echo '{"tool_name":"Bash","tool_input":{"command":"ctp-bridge host deploy trainbox_t02"}}' | "$HOOK"
#   → …"ask"… "confirm build-tooling run: ctp host deploy trainbox_t02"

# 6. A benign read  →  no opinion (no output, exit 0): other permissions decide
echo '{"tool_name":"Read","tool_input":{"file_path":"README.md"}}' | "$HOOK"; echo "exit=$?"
#   → (no line)  exit=0
```

A one-shot script that runs all of the above and prints a pass/label line per
control makes the cleanest demo; the cases above are the same ones asserted in
`scripts/tests/test-ctp-bridge.sh` and `scripts/tests/test-safety-guard.sh`, so
they will not drift from the code.

### Natural — in a live Claude Code session on the box

Ask Claude to do the risky thing and watch the harness respond:

- *"Delete the `/srv/data` directory"* → Claude's `rm -rf` raises a **confirmation
  prompt**; decline it and the command never runs. With no human to answer, it
  fails closed to a deny.
- *"Show me `~/org-data/clients.csv`"* → the Read is **denied**; Claude sees the
  refusal, not the contents, so nothing sensitive enters the transcript.
- *"Deploy to trainbox_t02"* → the wrapper call surfaces a **confirm build-tooling
  run** prompt bound to that exact argv; a bare `ctp …` is refused with a pointer
  to the bridge.

### Commit guard — warn, don't block

```bash
cd ~/some-repo
printf 'aws_key = "AKIA%s"\n' 'IOSFODNN7EXAMPLE' > leak.txt   # a fake credential
git add leak.txt && git commit -m "demo"
#   → prints a warning naming the rule/file/line, appends the same to
#     ~/.local/state/commit-guard/findings.jsonl (never the value),
#     and the commit STILL succeeds — warn-only by design.
```

The point of warn-only: an intentional commit is never blocked, but a real leak
is surfaced loudly and logged so it can be rotated/cleaned per
[`SECURITY.md`](../SECURITY.md). It is bypassable (`--no-verify`) — defense-in-
depth, not a boundary.

## Honest limits (the accepted risks, in one place)

- **No OS containment.** Shared account, everyone sudo. A hostile process on the
  box is not contained by any of this; the harness reduces incidental and
  instructed harm, not a determined actor. The durable fix is org-level
  (per-dev accounts/keys).
- **String classification can be obfuscated.** The gates read the real command
  word after env prefixes and substitutions, but an adversarial model can still
  find an encoding they do not match. That is why the destructive gate asks a
  **human** rather than trying to be exhaustive.
- **The path guards are path-based.** PII in a file outside `CTP_PII_PATHS` is not
  caught, and hooks cannot redact PII *inside* an otherwise-readable file's output
  — that is C2/G3's job (the local model reads and rephrases before Claude sees
  it). List the directories where Org data actually lives.
- **Warn-only means fast reaction, not prevention.** The commit guard does not
  stop a push; it makes the leak impossible to miss so you can rotate quickly.
- **The transcript is readable by the next account user.** The win is keeping
  sensitive content out of the prompt/model in the first place, not wiping
  transcripts.

`check-day0.sh` reports each on-box control honestly (present / warn-only /
bypassable / box-only), so a demo can start by showing the harness declaring its
own posture.

## References

- Rules and rationale: [`PROJECT.md`](PROJECT.md) — *Build-tooling commands*,
  *Secrets and transcripts*, *the destructive-action gate*, *Keeping Org PII/IP
  out of Claude*, *Accidental commits*.
- Visual briefing: [`explainer/index.html`](explainer/index.html).
- Tests that pin the demonstrated behaviour: `scripts/tests/test-ctp-bridge.sh`,
  `scripts/tests/test-safety-guard.sh`, `scripts/tests/test-commit-guard.sh`.
- Roadmap for the unbuilt controls: `_bmad-output/implementation-artifacts/deferred-work.md`.
