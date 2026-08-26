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
