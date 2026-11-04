# Troubleshooting

Operational troubleshooting guide for the devcontainer. Not needed in Claude's
context during normal operations — reference this file when debugging
connectivity or API issues.

## Host DNS prerequisite for range connectivity

The devcontainer reaches range services (Tuoni, Providentia, Outline, GitLab)
through hostnames configured in `.env`. Docker's embedded DNS resolver does not
honour the host's per-link split-DNS routing — it reads only the default-route
DNS server from `/run/systemd/resolve/resolv.conf`, which on a dual-VPN setup
is the privacy VPN's resolver, not the range resolver.

The fix is two parts, both required:

1. **systemd-resolved stub on the Docker bridge** (one-time host config):
   ```bash
   sudo mkdir -p /etc/systemd/resolved.conf.d
   printf '[Resolve]\nDNSStubListenerExtra=172.17.0.1\n' \
     | sudo tee /etc/systemd/resolved.conf.d/docker-dns.conf
   sudo systemctl restart systemd-resolved
   ```
   This makes the host's split-DNS-aware resolver available on the Docker
   bridge IP. It survives reboots (drop-in is persistent). It must be done
   once per host, not per container.

2. **`--dns 172.17.0.1`** in `devcontainer.json` `runArgs` (already configured).
   Tells Docker to forward container DNS queries to the host's resolver
   instead of the default-route DNS.

`scripts/check-host-prereqs.sh` validates both at `initializeCommand` time and
fails the container start with remediation steps if either is missing. It only
runs the checks when `.env` has spoke hosts configured — without spokes, range
DNS is not expected and the script is a no-op.

**Restart caveat:** `systemctl restart systemd-resolved` wipes per-link DNS
config set by vpn-chain. If you restart resolved while the VPN is connected,
re-run `vpn-chain` (or re-apply `resolvectl dns`/`domain` on the VPN
interface) to restore split-DNS routing.

## Network changes are deliberate

Adding an outbound host to the devcontainer firewall goes through
`/firewall-allow`. Per `CLAUDE.md` this is a hard escalation trigger.

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

## Reading the debug log: expected noise vs a real failure

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

## If you see `ECONNRESET`

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

## Pinning third-party installers

Installers fetched from upstream are pinned to a specific tag, and the commit
that tag resolves to is recorded alongside it. Before installing, the script
confirms the tag still points at that commit and refuses to install on drift,
rather than executing code nobody reviewed. Pinning a wrapper that then fetches
an unpinned default branch is not a pin — pin the code that actually executes.

## Local-model routing subsystem (removed)

The routing subsystem (`SUBSYSTEM_ROUTING`) and its scripts (`route-model.sh`,
`delegate-local.sh`, `local-health.sh`, `ask-local.sh`, `suggest-route.sh`) have
been disabled and removed. The code is preserved on the `archive/sp1a-gate`
branch. Architecture pivot: Opus 4.6 is the primary session with no local model
routing layer; MCP servers provide data and execution surfaces directly.
