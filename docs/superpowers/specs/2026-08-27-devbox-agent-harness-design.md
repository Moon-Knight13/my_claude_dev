# Dev-box agent harness — design

**Date:** 2026-08-27
**Status:** design, awaiting review
**Scope:** make this repository's Claude harness usable for real work on a
remote dev box, and close the gaps between what the developer setup guide
requires and what the provisioning scripts actually deliver.

> **Disclosure.** This repository is public. Every site-specific value appears
> here as a placeholder — `<box-domain>`, `<box-prefix>`, `<box-account>`,
> `<git-host>`, `<git-ssh-port>`, `<project>`, `<key-comment>`. Do not
> substitute real values into this file, into code, or into commit messages.
> See `docs/PROJECT.md` § "This repository is public".

## Context

The repository has two surfaces that are easy to confuse (`docs/PROJECT.md`
§ "What this repository is"):

1. **The provisioning product** — a laptop bootstrap
   (`scripts/local/bootstrap-devbox.sh`, `.ps1`) and an on-box provisioner
   (`scripts/host/provision-remote-box.sh`) that bring a remote dev box to a
   known-good state.
2. **The devcontainer** that this repository is developed in, inherited from the
   upstream template, carrying model routing, a Kanban board, BMAD and the
   security gates.

The devcontainer ships nothing to a box. Surface 2's harness — the part that
makes Claude useful — does not currently reach surface 1 at all.

### How the work is actually done

The developer connects from one of two personal machines to an allocated dev box
over VS Code Remote-SSH, edits files on the box, and runs the infrastructure
tool from the box's terminal. The box account is shared across the fleet by
naming convention; boxes are allocated per developer through an external
allocation table. Everyone on a box has sudo.

The infrastructure tool runs Ansible inside a Docker container on the box. Work splits into four lanes, all of which
the harness must serve:

- authoring and editing Ansible content;
- running deploys and diagnosing failures;
- building and tearing down environments;
- lint, review and hygiene.

### Constraints

| Constraint | Source | Consequence |
|---|---|---|
| Work happens **on the box** | org policy | Claude runs on the box; no laptop-side agent |
| Box account is **shared**, sudo for all | `docs/PROJECT.md` | Nothing identity-shaped may be written to the shared `$HOME` unscoped |
| Boxes are **reallocated** | allocation table | Anything left behind reaches the next developer |
| Developer uses **two machines**, different keys | observed | Box-side config must not assume one machine |
| Range project is on **GitLab** | observed | `gh`-CLI pieces (`board.sh`, day-0, `/next-issue`) cannot travel |
| Restricted egress | `docs/PROJECT.md` | New outbound hosts are a deliberate change |
| Local models run on a **personal machine** | observed | Box has no local model endpoint of its own |

## Findings that motivate this work

Established by reading the scripts and by live diagnosis during design.

### F1 — Local routing is dead on a box

Every routing entry point defaults `LOCAL_MODEL_ENDPOINT` to
`http://host.docker.internal:11434` (`scripts/route-model.sh:19`,
`delegate-local.sh:41`, `local-health.sh:22`, `ask-local.sh:15`). That address
only resolves inside the devcontainer. The models run on the developer's own
machine, and nothing in the repository forwards a port to the box, so on a box
every routing decision falls through to `local_unreachable_fallback`.

This is the same class of failure `docs/PROJECT.md` § "`.env` only works because
something loads it" already documents: a value that exists on one surface and
not the other, with nothing asserting the difference.

### F2 — Provisioning declares success it never verified

`provision-remote-box.sh` writes its completion marker after installing
extensions, lint settings, the credential killswitch and the plugin set. It
never confirms the infrastructure tool works. The setup guide's own success
criterion — listing the project inventory — is not run.

`docs/PROJECT.md` § "Provisioning must not lie" forbids exactly this shape: a
step reported as reaching the golden state without evidence that it did.

### F3 — Two setup-guide steps are unimplemented

- Box-side `git config --global user.name` / `user.email`. Nothing sets it. An
  unset committer identity is independently sufficient to get a push rejected by
  a server-side push rule.
- The infrastructure tool's first-run configuration (vault initialisation) is
  interactive and correctly manual, but nothing tells the operator it is the
  next required step.

### F4 — Git SSH port default is wrong, and the two bootstraps disagree

`bootstrap-devbox.sh:180` prompts for the git server SSH port defaulting to
`22`. Sites using a non-standard port get a wrong default on every run.

`bootstrap-devbox.ps1:92` writes `IdentityFile` into the generated `Host` block;
`bootstrap-devbox.sh:112-118` does not. With several keys in an agent, ssh
offers them in agent order and can exhaust the server's `MaxAuthTries` before
reaching the right one — intermittently, and only for developers with many keys.

### F5 — The managed key has three different names

The key the laptop bootstrap creates and the key the documentation describes are
not the same key, and the two bootstraps do not agree with each other:

| Source | Path | Comment |
|---|---|---|
| `bootstrap-devbox.sh:32,71` | `~/.ssh/id_ed25519_devbox` | `devbox_<user>` |
| `bootstrap-devbox.ps1:39` | `~/.ssh/id_ed25519` | default identity |
| `README.md:41`, `scripts/host/README.md:62,81` | `~/.ssh/id_ed25519_MCD` | `MCD_<user>` |

The documented path does not exist. A developer following the README looks for a
key the scripts never create.

The PowerShell divergence is a defect rather than a naming slip: it hardcodes the
user's **default** identity with no override parameter, so on that platform the
bootstrap adopts — or generates over — the developer's general-purpose key
instead of a dedicated one. That directly undermines B′, whose value comes from
the pinned key being single-purpose.

### F6 — A reconnect silently strips the forwarded agent

Observed live on a box. The editor sets `SSH_AUTH_SOCK` to a symlink under the
user's runtime directory, targeting an agent socket in `/tmp`. When the
connection drops, that agent dies. The reconnect creates a new agent under a
different `/tmp` directory, but shells opened before the reconnect keep the old
path, leaving a dangling symlink and:

```
Error connecting to agent: No such file or directory
```

Everything depending on the forwarded key then fails: git over SSH, and the
infrastructure tool, which mounts `SSH_AUTH_SOCK` into its container. Nothing in
the repository detects or explains this, so it presents as an unrelated
authentication fault — which is how it was first reported.

The obvious repair — attach to the newest socket under `/tmp/ssh-*/` — is
**unsafe on a shared account**: every connected developer's forwarded agent
lives there owned by the same user, so "newest" means "whoever reconnected last"
and attaching authenticates you as them.

### F7 — Agent key ordering decides identity, and forwarding over-shares

Confirmed against the actual git server. A developer agent held **seven** keys.
From the developer's own machine, where an `ssh_config` entry pinned the correct
key, the server greeted the intended account. From the box, with the identical
forwarded agent and no pin, the same command authenticated as a **different
account belonging to a different team and a different year's cohort** — because
an older key sits earlier in agent order and is still registered there.

The push failure is therefore not a credentials problem and not a forwarding
problem. Both accounts authenticate successfully; the server simply accepts
whichever key it recognises first, and the developer's identity is decided by
agent ordering rather than by intent.

Two consequences worth stating separately. A key registered to a disused account
keeps winning on every unpinned host, so the fault follows the developer to each
newly allocated box. And because it *succeeds*, nothing surfaces as an error
until a later operation is refused for the wrong identity.

The repository assumes one forwarded key (`scripts/host/README.md:61-64`).

Separately: agent forwarding exposes **every** key in the agent to the box for
the life of the session, including infrastructure and service keys unrelated to
the work. On a shared-sudo box this is a larger exposure than the credentials
the killswitch was built to shred. The killswitch removes exactly three files
(`setup-killswitch.sh:77`) — the assistant token, the GitHub CLI hosts file, and
a plaintext git credential store. **SSH key material is not covered.**

### F8 — Two SSH consumers need different identities

| Consumer | Needs an identity known to | Currently uses |
|---|---|---|
| `git push` | the git server | forwarded agent |
| the infrastructure tool | the target hosts it configures | forwarded agent |

Conflating them is why "just put a key on the box and drop agent forwarding"
looks like a fix and is not: the repository's own README and the tool's
container startup both depend on the forwarded agent reaching the target hosts.
The git-server identity can be pinned without touching that.

### F9 — The agent sits outside the container it must drive

Claude runs on the box and can read and edit the project tree directly. The
tool's commands exist only inside its Docker container, whose name is derived
from the compose project name and `${USER}` — identical for every developer on a
shared account.

Three facts make a bridge tractable:

- the vault password is cached inside the container after the first interactive
  unlock, so later non-interactive invocations inherit it and this repository
  never handles the secret;
- the container's shell profile activates a virtualenv, so invocation must go
  through a login shell, not a bare `exec`;
- Ansible retry files are enabled, so "re-run only what failed" already exists.

Ansible runs with a free strategy and a high fork count, so multi-host output
interleaves; failure analysis must be per-host, never positional.

## Design

Four components, built in dependency order. Each is independently useful and
independently revertible.

### A — Reach a local model from the box

**Problem:** F1.

**Approach.** The developer already connects over SSH with a generated `Host`
block. A reverse tunnel in that block carries the model endpoint from the
machine that has it to the box that does not, and costs the developer nothing at
connect time because VS Code Remote-SSH reads the same `~/.ssh/config`.

- Both bootstraps add `RemoteForward <port> 127.0.0.1:<port>` to the `Host`
  block they already write, port taken from a variable, defaulting to the
  upstream default.
- On the box, `.env` sets the endpoint to the loopback address the tunnel
  terminates on.
- `check-day0.sh` learns a surface-aware assertion: on a box, "local routing
  enabled" must mean the endpoint answers, not that a file exists. This is the
  same correction `docs/PROJECT.md` records for the `.env` loader.

**Interface.** Nothing outside the `Host` block and `.env` changes. Every
routing script keeps reading `LOCAL_MODEL_ENDPOINT`.

**Risks.** A bind on a shared box collides if two sessions forward the same port,
and a colleague on that box could reach the tunnelled endpoint while it is open.
Bind to loopback only, document the exposure, and make the port overridable.

### B — Setup-guide parity and honest completion

**Problem:** F2, F3, F4, F5, F6.

- Add a **verification step** to `provision-remote-box.sh` that runs the tool's
  inventory-listing command. Record it with `host_fail`, not `host_warn`, so a
  box that cannot list its inventory does not get a completion marker.
- Set box-side git identity, prompted, idempotent, never overwriting an existing
  value.
- Take the git SSH port from a variable with no misleading default; require an
  answer rather than guessing `22`.
- Make `bootstrap-devbox.sh` write `IdentityFile` into the box's own `Host`
  block so it matches the PowerShell bootstrap. This is the box login identity
  and is laptop-side only — distinct from the git-server alias in B′.
- Ship `scripts/host/diagnose-git-auth.sh` (already written) as a **diagnostic**,
  invoked on demand and on verification failure — never as a gate. It detects
  the dangling-socket case in F6 by name rather than reporting a generic
  authentication failure.
- Ship `scripts/host/fix-agent-sock.sh` (already written) to repair F6. It
  resolves the session's agent by walking the shell's own process ancestry to
  the owning `sshd` and reading that process's environment — never by choosing
  the newest socket in `/tmp`, which on a shared account would attach the
  developer to a colleague's agent. It refuses and explains when no agent
  belonging to the current session can be found.
- Reconcile the managed key's name across both bootstraps and all documentation
  (F5), and give the PowerShell bootstrap a dedicated key path plus an override
  parameter matching the shell script's `SSH_KEY`.
- Bump `PROVISION_VERSION` so already-marked boxes re-provision.

**Interface.** `provision-remote-box.sh` grows a sixth step and a hard failure
mode. Its contract — idempotent, confirm-gated, honest — is unchanged.

### B‴ — A single per-machine identity string

**Problem:** B′ and B″ both need to name "this machine" — in a key comment, in a
public key filename on the box, and in an `ssh_config` line. Deriving each
independently invites them to drift apart, and the current key comment
(`devbox_<user>`, `bootstrap-devbox.sh:71`) identifies neither the machine nor
the account the key belongs to. A developer with two machines gets two keys with
identical comments, indistinguishable in the git server's key list.

**Approach.** Build one identity string at bootstrap and derive everything from
it:

```
IDENTITY = <range-user>_<machine>
```

- `<range-user>` is already prompted; its prompt already states it is "for the
  key comment / git identity".
- `<machine>` defaults to the short hostname, prompted so it can be overridden.
- Both are sanitised to `[A-Za-z0-9._-]`, because the value becomes a filename.

`IDENTITY` is then used as:

| Use | Value |
|---|---|
| SSH key comment | `IDENTITY` |
| Public key filename copied to the box | `~/.ssh/<IDENTITY>.pub` |
| `IdentityFile` line in the box's alias | that path |

**Why this matters beyond tidiness.** It makes B′'s accumulation
self-documenting and idempotent by construction: the box's alias ends up with
one `IdentityFile` per registered machine, each named for that machine, so the
set of registered machines is readable from the config alone. Re-running from an
already-registered machine produces the identical filename and line, so there is
nothing to deduplicate. It also makes a key identifiable in the git server's key
list, where a developer with several machines otherwise sees several
indistinguishable entries and cannot safely revoke one.

**Constraint.** The template is generic; the account naming convention is
supplied by the operator at the prompt and must never be committed. `KEY_COMMENT`
remains honoured as an override for developers who already have a convention.

### B′ — Identity pinning, driven from the laptop bootstrap

**Problem:** F7, F8.

Pin the git-server identity **without** removing agent forwarding and **without**
placing private key material on a shared box.

**Prefer removing the competing registration.** Where the conflicting key belongs
to an account the developer still controls, or is a key they can stop loading,
removing it is the root-cause fix and beats pinning: it corrects the identity on
every host at once rather than one configuration per box, and it needs nothing
added to a shared account home. In the case that motivated this section the
conflicting key was the developer's default identity, held by a keyring that
refused `ssh-add -d`; renaming the key file so the keyring could not reload it
resolved it, and the server then accepted the intended key first.

Two cautions that cost real time when skipped. Identify the key by
**fingerprint**, never by filename — the first attempt deleted a same-named key
of a different type. And take a copy of the key directory first: a default
identity may be trusted by hosts the developer has forgotten, and cannot be
regenerated. Renaming rather than deleting gives the same effect with a rollback.

**Conditional, not default.** The documented developer setup already produces a
working git identity for a developer whose agent carries one key, and its own
verification step confirms it. That path stays the default and the reference.
Pinning applies only when that verification fails or reports the wrong identity,
and removing the competing registration is not available — which happens when an
agent carries several keys the git server recognises and the developer no longer
controls the account one of them belongs to.
Applying a pin to a developer who does not need one adds configuration to a
shared account for no benefit, and the bootstrap must therefore verify first and
pin only on failure, never unconditionally.

**Where this belongs.** The laptop bootstrap, not a manual step and not the
on-box provisioner. Only the machine the developer is sitting at knows which key
that machine holds, and the developer uses more than one machine. Making it a
bootstrap step means each machine contributes its own identity on first run, and
a third machine later is handled by running the same script there.

**What the bootstrap does, in addition to what it does today** — after the
documented verification has failed:

- pins the key the script already manages and already instructs the developer to
  register at the git server. That key is generated per machine, so a developer
  using two machines registers two keys — which the accumulating alias below
  handles directly. Pinning it also makes the git-server identity
  single-purpose: no unrelated key in the agent is ever offered. An override is
  offered for developers who arrive with a key that predates this repository and
  is already registered;
- copies that key's **public** half to the box as `~/.ssh/<IDENTITY>.pub`,
  the per-machine identity defined in B‴;
- appends an `ssh_config` alias on the box for the git server, setting
  `IdentitiesOnly yes` and one `IdentityFile` per registered machine, each
  pointing at a public key file — the private half never leaves the machine and
  is reached through the forwarded agent;
- is idempotent and accumulative: re-running from the same machine changes
  nothing, running from a new machine adds one `IdentityFile` line;
- prints the remote URL rewrite rather than performing it, because the
  project clone may not exist yet at bootstrap time;
- states plainly that the pin is inert until the public key is registered at the
  git server — the bootstrap writes the pin before the developer has pasted the
  key in, so a failing verification at this point means "not registered yet",
  not "pin is wrong". Without saying so the script manufactures a confusing
  failure.

**Guards the bootstrap must implement.** The bootstrap currently *causes* this
class of fault rather than preventing it. Each guard below exists because the
absence of it was observed:

1. **Never add a competing key.** The script generates a key under its own name
   and adds it to the agent. A developer who already holds a key registered at
   the git server gains an additional, unregistered identity competing for
   position in agent order — the precise fault this section exists to fix. The
   script must detect an existing usable key, offer to reuse it, and generate
   only when there is nothing to reuse.
2. **Verify identity, do not assume it.** After setup, run the documented
   verification and compare the returned account against what the developer
   expects. A wrong identity authenticates *successfully*, so nothing surfaces
   until a later push is refused. Detecting it here costs one command.
3. **Report agent population.** When the agent holds more than one key, say so
   and say what it means: identity is decided by agent order. Silence here reads
   as "correctly configured".
4. **Never write a default `Host` entry for the git server on a shared box.**
   Only an alias. See the constraint above.
5. **Pin the box login key.** Write `IdentityFile` into the box's own `Host`
   block so box login does not depend on agent order either (F4).
6. **Prefer scoping the forwarded agent** over forwarding everything (B″), so a
   shared box is never offered keys it has no business seeing.

Guards 1-3 are the difference between a bootstrap that prevents this fault and
one that manufactures it. They are not optional polish.

**Why writing to the box is acceptable here.** An alias block is additive: it
applies only when the alias is used, so other developers resolving the git host
directly are unaffected. Only public key material is copied. The script already
authenticates to the box at this point in its run (`ssh-copy-id`), so this
introduces no new trust relationship — but it is the first time the laptop
bootstrap writes to the box, and that change of scope must be stated in the
script's header.

**Constraint.** Never modify or add a default `Host` entry for the git server on
the box, and never write private key material there. Both would change behaviour
for every other user of a shared account: a default entry combined with
`IdentitiesOnly` would force every developer on that box through one identity
and refuse their own. The alias form is what makes the change additive. The same
block is safe in a developer's own `~/.ssh/config` on a personal machine, and
unsafe in a shared account home — the distinction is the account, not the
syntax.

The per-repository equivalent (`core.sshCommand`) stays documented for
developers who prefer to touch no shared file, and as the fallback when a box
denies the write.

**Explicitly rejected:** generating a private key on the box and dropping agent
forwarding. It breaks the infrastructure tool's path to its target hosts (F8),
and it leaves personal key material in a shared home that survives reallocation
and that the killswitch does not clear (F7).

**Follow-on, out of scope here:** extend the killswitch to cover SSH key
material. Filed rather than built.

### B″ — Scope the forwarded agent

**Problem:** F7, second half.

Pinning which key is *offered* to the git server does not reduce what is
*reachable* from the box. `ForwardAgent yes` exposes every identity in the
developer's agent to the remote host, and OpenSSH documents the consequence
directly: anyone able to bypass file permissions on that host can use those
identities for the life of the session. On a shared account where everyone has
sudo, that is every colleague, and the agent in practice carries infrastructure
and service keys unrelated to this work.

**Approach.** Forward a second agent that holds only what the box needs.
`ForwardAgent` accepts an explicit socket path, so this is a change of argument
in the `Host` block the bootstrap already writes — not new machinery on the box:

- the bootstrap creates a box-scoped agent socket and loads only the key it
  manages;
- the generated `Host` block sets `ForwardAgent <scoped-socket>` instead of
  `yes`;
- the developer's primary agent is left untouched, so normal use of their other
  keys is unaffected.

This is a containment fix and strictly stronger than B′'s selection fix: keys
that never cross the boundary cannot be misused on the far side, whether or not
ssh would have offered them.

**Determined empirically, not assumed.** The repository asserts that the
infrastructure tool authenticates with the forwarded key but does not record
*which* identity the target hosts accept. The scoped agent therefore starts with
the managed key alone, and any additional identity is added only after an
observed failure demonstrates it is required. Preloading keys defensively
reinstates the exposure being removed.

**Known gap.** The socket-path form has no direct equivalent on Windows, whose
OpenSSH uses named pipes. The PowerShell bootstrap cannot implement B″ as
written; it must either fall back to `ForwardAgent yes` with the limitation
stated in its output, or the design needs a Windows-specific mechanism. This is
unresolved and should not be papered over — a bootstrap that silently forwards
everything on one platform while claiming to scope it on another is the
reported-success-without-evidence failure this repository already guards against.

**Persistence.** A socket-bound agent survives shell exit but not a reboot. The
bootstrap must either install a user-level service or state plainly that the
agent needs recreating, rather than leaving a developer with a Host block
pointing at a socket that no longer exists.

### C — The tool bridge

**Problem:** F9.

Three layers, each doing one job:

1. **Wrapper script** — resolves the container, refuses when the container is
   absent or busy, invokes through a login shell, streams output, returns the
   real exit status. Safety lives in code, not in pattern matching.
2. **Command classification** — read-only and single-host verbs run freely;
   destructive verbs (removal, rebuild, from-scratch redeploy) require explicit
   confirmation through the existing `confirm()` gate and are never
   auto-confirmed by an agent.
3. **Skill layer** — gives Claude the deployment model so a failure is read
   correctly: which stage failed, what that stage owns, and whether a retry file
   makes a targeted re-run possible. Without this an agent guesses.

A `PreToolUse` hook rejects attempts to reach the container directly, so the
wrapper cannot be bypassed.

**Explicitly rejected:** enforcing destructive-command safety through permission
patterns alone. Matching freeform command strings is defeated by quoting and
environment prefixes; it looks enforced and is not — the failure shape
`docs/PROJECT.md` already warns about.

**Interface.** One script, one skill, one hook. No change to the upstream tool,
no image modification, nothing that a tool upgrade can silently undo.

**Open question for review.** Whether structured Ansible run records (available
behind an opt-in flag in the tool) should back failure analysis instead of
parsing interleaved stdout. Better data, extra moving part. Deferred.

### D — Harness contract for the range project

**Problem:** the harness contract does not exist where the work happens.

A portable subset installed into the project repository:

- a project-level contract covering routing, escalation triggers and quality
  gates, written for infrastructure-as-code work;
- routing scripts and `.env` handling;
- lint and pre-commit configuration matching the tooling already provisioned.

**Excluded by construction:** everything `gh`-dependent — the board CLI, the
board slash-commands, day-0 provisioning. The project is not on GitHub.

**Excluded by policy:** the contract must not carry site-specific values, and
must state that transcripts on a shared box are readable by the next occupant.

## Build order

`A → B (+B‴, B′, B″) → C → D`

A is smallest and everything routed depends on it. B makes provisioning honest
and carries the hotfixes already diagnosed; B‴ lands first within that group
because B′ and B″ both consume the identity string it defines, and B″ ships
alongside because both change the same generated `Host` block and splitting them
would rewrite it twice. C is the leverage and the largest
risk surface, and wants A and B settled underneath it. D is inert until C exists.

## Implementation status

Updated as work lands. Deviations from the design above are recorded here rather
than by silently editing the section they contradict.

| Item | State | Where |
|---|---|---|
| B‴ identity string | done | `bootstrap-devbox.sh`, `.ps1` |
| B′ guards 1-5 | done | both bootstraps |
| B′ conditional pin | done | both bootstraps |
| F4 git SSH port, `IdentityFile` in the box `Host` block | done | both bootstraps |
| F5 one key name | done | scripts + `README.md` + `scripts/host/README.md` |
| F6 stale socket | done | `scripts/host/fix-agent-sock.sh`, documented |
| B″ scoped agent | opt-in, off by default | `SCOPE_AGENT=true` |
| A reverse tunnel | done | both bootstraps, `.env.example`, `scripts/host/README.md` |
| A surface-aware day-0 check | done | `scripts/lib/surface.sh`, `check-day0.sh` |
| Local model serving end to end | done | verified against the real endpoint |
| Graceful degradation when it is not serving | done | `LOCAL_MODEL_REQUIRED`, default WARN |
| B provisioning honesty | done | `provision-remote-box.sh`, `test-provision.sh` |
| C, D | not started | — |

### Deviations

**B″ ships opt-in, not on by default.** The design has the scoped agent carry the
managed key alone and additional identities added only after an observed failure.
Applied as the default that breaks deploys on the first run: the build tooling
reaches the hosts it configures through the same forwarded agent, and which
identities those hosts accept is recorded nowhere in this repository. Making the
containment fix the default would trade a working deploy path for a security
improvement the developer did not ask for at that moment. It is therefore
`SCOPE_AGENT=true`, with `SCOPE_AGENT_KEYS` for the extra identities, and the
default `ForwardAgent yes` states its exposure in the script's output. The
design's intent — determine the needed identities empirically, never preload
defensively — is preserved; only the direction of the default changed.

**The `.sh` version-gates `ForwardAgent <path>`.** The socket-path form needs
OpenSSH >= 8.9. Older clients fall back to `ForwardAgent yes` and say so, rather
than writing a `Host` block the client silently rejects.

**Windows keeps the known gap, stated in-script.** The `.ps1` cannot implement
B″ (named pipes, not socket paths). It forwards the whole agent and prints that
it is doing so, in both the file header and the run output. It implements every
other guard, including the F5 fix that stopped it hardcoding the developer's
default identity.

**A's day-0 check WARNs on a box; FAIL is opt-in.** First implemented as a hard
FAIL on the reasoning below. Corrected on the requirement that the harness keep
working when the local model is not serving: routing already falls back to Claude
and the task still completes, so an unreachable endpoint is a lost optimisation,
not a blocker, and must not produce a red day-0.  `LOCAL_MODEL_REQUIRED=true`
restores the FAIL for a developer who wants it. The honesty requirement is met by
the message rather than the severity — it always states that everything is
routing to Claude. The original reasoning, which still holds for what the check
must *say*:

**Why it is surface-aware at all.** The existing check was a
WARN on principle: the model cannot be installed from inside the container and
day-0 must go green with two logins. On a box that reasoning does not hold —
enabled-but-unreachable means every routing decision silently falls back while
the file and the check both report local routing on, which is precisely the
failure `docs/PROJECT.md` records for the `.env` loader. The check therefore
asks which surface it is on (`scripts/lib/surface.sh`) and FAILs only on a box.
`check-day0.sh` also now sources the `.env` loader itself: check 11 read
`LOCAL_MODEL_ENDPOINT` straight from the environment, so it reported on defaults
rather than on the developer's configuration — the same bug, inside the checker
built to catch it.

**The tunnel is not written to a dead endpoint.** If nothing answers on the
laptop's model port, the bootstrap says so and writes no `RemoteForward` line,
rather than leaving config that looks configured and forwards nothing. It also
probes the box for a port already bound and refuses it: on a shared box that
port belongs to another developer's tunnel, and silently reusing it would send
this developer's prompts to that developer's machine.

**Key selection asks the git server.** Guard 1 says "detect an existing usable
key". Implemented as: probe every `~/.ssh/*.pub` against the git server with
`IdentitiesOnly=yes`, print the greeting each returns, and offer to reuse a key
the server already accepts. Filename heuristics were rejected — the incident
that motivated this section began with a key identified by name and deleted in
error, and a key's name says nothing about which account it authenticates as.

**B's verification command is supplied, not baked in.** The design says to add a
step that runs the tool's inventory-listing command. The command names the
tooling, and this repository is public, so it arrives as `--verify-cmd` (or
`DEVBOX_TOOL_VERIFY_CMD`) at run time. When it is absent the step states that
this run could not confirm the tooling works and the marker records
`tool_verified=unconfigured` — the alternative, skipping silently, is the
failure the step exists to fix.

**B's git identity step is repo-local, not global.** The design says "set
box-side git identity, prompted, idempotent, never overwriting". Implemented
without `--global` by default: on a shared account the first developer to set a
global identity becomes the committer identity for every colleague who has no
repo-local override. That is the SSH identity failure of F7 in a different
place — it works perfectly until someone reads the attribution.
`--git-identity-global` opts in, and still refuses to overwrite.

**The failure gate had a hole.** It sat before the last two steps, so a failure
in either could not have stopped the completion marker. Moved to after every
step; `scripts/tests/test-provision.sh` asserts it.

### Found while wiring the local model up

Three defects, none of which failed loudly. Recorded in `docs/PROJECT.md` so they
do not have to be rediscovered.

- **Tagged model names were truncated** by `delegate-local.sh`'s left-to-right
  parse of `provider:model:reason`. Every real Ollama name has a colon in it, so
  the health preflight probed a different model than routing had selected.
  Regression test added; it fails against the old parse.
- **The shipped fast model was a base model** (`qwen2.5-coder:1.5b-base`), which
  continues a prompt rather than following it. Its output is fluent enough to
  pass the empty and degenerate checks, so every fast-path delegation returned
  plausible nonsense as a success.
- **`test-day0.sh` was 0/7 before any of this work**: its sandbox copied two
  hand-listed library files, so a `source` line added to `check-day0.sh` at some
  point broke all seven cases with a missing-file error. A suite that fails
  entirely tests nothing. It now copies the whole `lib/` directory and the
  routing script the fixture asserts against, and covers the three
  local-model severity paths.

## Verification

Per `docs/PROJECT.md` § Verification, plus:

- `bash scripts/check-day0.sh` — must distinguish "configured" from "reachable"
  on both surfaces.
- `bash scripts/validate-template.sh` — template invariants; runs in CI.
- `pre-commit run --all-files` — gitleaks and semgrep.
- `bash scripts/tests/test-delegation.sh` — extended to cover a tunnelled
  endpoint against the existing mock.
- The wrapper's classification needs a test asserting that destructive verbs are
  refused without confirmation, including when wrapped in quoting or prefixed
  with environment assignments.

## Out of scope

- Modifying the upstream infrastructure tool or its image.
- Per-developer accounts on the boxes — organisational, not repository.
- Automating vault initialisation, or handling the vault password anywhere.
- Automating box allocation.
- Extending the killswitch to SSH key material (filed as follow-on).
- Anything that would place range material outside the box.
