# Spoke Connectivity Redesign — Direct IP Allow + Tuoni Self-Agent

**Date:** 2026-11-01 (updated 2026-11-02)
**Status:** Draft — awaiting operator approval
**PRD refs:** FR-K1, FR-K2, FR-P2, NFR-O5, NFR-D2

## Intent

Redesign spoke connectivity so red-team engagements survive deploybox
reclamation. Replace SSH tunnel approach with specific-IP firewall allow —
add spoke IPs to container's ipset for direct TCP connectivity through
Docker bridge NAT. Tuoni MCP becomes primary Kali spoke for both C2 and
tool execution.

## Why Now

Deployboxes are allocated per exercise and can be reclaimed during live
engagements. Current design routes critical red-team operations through
deploybox (SSH keys, catapult access). If deploybox goes away mid-engagement,
C2 visibility and Kali tool execution break simultaneously.

## Why Option C (Specific-IP Allow) Over SSH Tunnels

Previous design used SSH port-forwarding through `host.docker.internal` to
carry HTTPS API traffic to range services. Analysis showed:

- SSH tunnels provide marginal security benefit: Tuoni self-agent already has
  full range access from Kali, so tunnel encryption adds defense-in-depth
  only for the container-to-host hop (same physical machine)
- Operational cost was high: tunnel lifecycle management, port mapping,
  reconnection logic, PID files, health monitoring, SSH permission rules
- Docker bridge NAT already routes container traffic to non-local IPs
  through host — firewall was blocking range IPs, not missing routes

Option C: add only `.env` spoke IPs to existing `allowed-domains` ipset.
Same per-host security granularity. ~30 lines of bash instead of ~200.

| Factor | SSH Tunnels | Specific-IP Allow |
|--------|------------|-------------------|
| Lines of code | ~200 (spoke-tunnel.sh) | ~30 (spoke-firewall.sh) |
| Port mapping | Required per service | None — native ports |
| Tunnel lifecycle | PID files, health checks, reconnection | None |
| SSH permission rule | Required in Claude Code | Not needed |
| MCP config changes | localhost:port per service | Direct URLs (env vars) |
| Security granularity | Per-port, per-host | Per-host (ipset) |
| Defense-in-depth | Encrypted container→host hop | Host VPN encrypts host→range |
| Failure modes | Tunnel death, port conflicts | VPN down (same either way) |

## Goals

1. Red-team mode operates without any deploybox dependency
2. Tuoni self-agent on Kali handles both C2 and tool execution
3. Pre-engagement cache makes critical intel available offline
4. Green-dev mode continues through deploybox (acceptable dependency)
5. SSH to spokes exists for shell access (not API tunneling)

## Non-Goals

- Eliminating deploybox from green-dev workflow
- Building a VPN client inside the container
- Automating Kali provisioning (catapult handles this)
- Allowing whole VPN subnet (only specific spoke IPs)

## Anti-Goals (would make this a failure even if it works)

- Any design that requires deploybox during red-team engagement
- Storing range credentials in repo or committed config
- Breaking deny-by-default firewall isolation
- Opening firewall broader than specific spoke IPs

## Constraints

- Container firewall allows egress only to host:22, host:11434, and ipset members
- MCP servers are STDIO transport (NFR-S4)
- Tuoni is authoritative for live C2 state, never cached (NFR-D2)
- Docker bridge NAT handles routing — no manual route setup needed

---

## Design

### Connectivity Model

```
ALL MODES (when spoke IPs configured)
┌─────────────┐   Docker bridge   ┌─────────────┐         ┌──────────┐
│  Container   │ ── NAT ────────► │    Host      │ ──VPN─► │  Spoke   │
│  (hub)       │  direct TCP      │  (VPN)       │         │  system  │
└─────────────┘                   └─────────────┘         └──────────┘
      │                                                        │
      │  ipset allowed-domains                                 │
      │  contains: GitHub, npm,                                │
      │  Anthropic, + spoke IPs                                │
      ▼                                                        ▼
  iptables OUTPUT                                     Range service
  ACCEPT if dst in ipset                              (native port)
  REJECT otherwise
```

```
GREEN-DEV (deploybox dependency acceptable)
Container ─► host VPN ─► deploybox (gt@db) ─► GitLab, Providentia, catapult
                    └──► range-git (direct if IP in ipset)

RED-TEAM (zero deploybox dependency)
Container ─► host VPN ─► Kali (Tuoni API :8443, SSH :22)
      │
      └── tuoni-mcp ─► https://SPOKE_KALI_HOST:8443 (direct)
      └── obsidian-mcp (local, always available)
```

### How `spoke-firewall.sh` Works

Reads spoke IPs from `.env` and adds each to `allowed-domains` ipset:

```bash
#!/bin/bash
# spoke-firewall.sh — add spoke IPs to container firewall allow-list
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/load-env.sh"

added=0
for var in SPOKE_DEPLOYBOX_HOST SPOKE_KALI_HOST RANGE_GIT_HOST PROVIDENTIA_HOST OUTLINE_HOST; do
    ip="${!var:-}"
    [[ -z "$ip" ]] && continue
    # Validate IP format
    if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        echo "WARNING: $var='$ip' is not an IP — resolve DNS first"
        resolved=$(dig +short A "$ip" | head -1)
        [[ -z "$resolved" ]] && { echo "ERROR: Cannot resolve $var=$ip"; continue; }
        ip="$resolved"
    fi
    ipset add -exist allowed-domains "$ip"
    echo "Allowed spoke: $var=$ip"
    ((added++))
done

echo "spoke-firewall: $added spoke IPs added to allowed-domains"
```

Called from:
- `project-setup.sh` (container init)
- `/mode` skill (mode switch)
- Manually: `bash scripts/spoke-firewall.sh`

No PID files. No tunnel lifecycle. No port mapping. Idempotent
(`ipset add -exist` is a no-op for existing entries).

### MCP Configuration — Direct URLs

MCP servers connect to spoke services at their native addresses. No
localhost port mapping needed.

**Red-team mode** — tuoni-mcp uses direct Kali address:

```json
{
  "mcpServers": {
    "tuoni-mcp": {
      "command": "npx",
      "args": ["-y", "@anthropic-ai/tuoni-mcp"],
      "env": {
        "TUONI_URL": "${TUONI_URL}",
        "TUONI_TOKEN": "${TUONI_TOKEN}"
      }
    }
  }
}
```

Where `TUONI_URL=https://<SPOKE_KALI_HOST>:8443` — set in `.env` or
derived at container startup. No port rewriting needed.

**Green-dev mode** — range-intel uses direct Providentia/GitLab addresses:

```json
{
  "mcpServers": {
    "range-intel": {
      "command": "node",
      "args": ["${RANGE_INTEL_PATH}/index.js"],
      "env": {
        "PROVIDENTIA_URL": "${PROVIDENTIA_URL}",
        "GITLAB_URL": "${GITLAB_URL}"
      }
    }
  }
}
```

Where `PROVIDENTIA_URL` and `GITLAB_URL` resolve to range IPs that are
in the ipset. Same env var pattern as current config — no settings.json
changes needed for green-dev or red-dev modes.

### Tuoni Self-Agent on Kali

(Unchanged from previous design — this is about execution model, not
connectivity.)

Tuoni server runs on Kali (deployed via catapult). A Tuoni agent deployed
ON Kali itself connects back to localhost Tuoni server. This self-agent
enables:

- Command execution on Kali through tuoni-mcp (same as any target agent)
- File operations (upload/download plugins, retrieve scan output)
- Plugin execution (TSE modules run through agent, output returns via API)
- Tool execution (nmap, proxychains, etc. — via shell commands through agent)

**Execution model — short vs long-running commands:**

| Command Type | Method | Example |
|---|---|---|
| Short + small output | `sh` / `run` direct | `whoami`, `ip addr`, `cat /etc/passwd` |
| Long-running | `sh` with output redirect, poll, `download` result | `nmap -sV 10.0.0.0/24 > /tmp/scan.txt` |
| Native equivalent exists | Use Tuoni native command | `portscan` instead of nmap for quick scans |
| Large file transfer | `upload` / `download` commands | Plugin deployment, scan result retrieval |
| Interactive / TTY-required | SSH to Kali (direct, IP in ipset) | Manual operator intervention only |

Long-running pattern:
1. `sh` command: `nohup nmap -sV -oA /tmp/scan_target 10.0.0.0/24 &`
2. Poll: `sh` command: `test -f /tmp/scan_target.nmap && echo DONE`
3. Retrieve: `download /tmp/scan_target.nmap`

SSH fallback for interactive sessions uses direct SSH to Kali IP (allowed
by ipset) — no port forwarding needed.

**Bootstrap checklist** (run before engagement, during green-dev phase):

1. Verify Tuoni server running on Kali (`GET /api/v1/status`)
2. Check for self-agent — if missing, deploy one (listener on localhost)
3. Upload tuoni-plugins to Kali via Tuoni file operations
4. Verify plugins loaded and operational
5. Test self-agent command execution (e.g. `whoami`, `ip addr`)
6. Record Kali agent ID in engagement YAML

### Pre-Engagement Cache Workflow

Before transitioning from green-dev to red-team, cache critical intel into
Obsidian. Makes red-team mode self-sufficient even if range-intel MCP is
not connected.

**What to cache:**

| Source | Cache Target | Staleness Risk |
|--------|-------------|----------------|
| Providentia target data | `raw/providentia/` per target | Low — range rarely reconfigured mid-exercise |
| GitLab READMEs for targets | `raw/gitlab/` per target | Low — deploy configs stable |
| Wiki vulns-docs | `wiki/vulnerabilities/` | Medium — updated during exercise |
| Outline doctrine | `wiki/doctrine/` | Low — reference material |
| Tuoni listener config | engagement YAML | Low — set during setup |

**Cache step** (skill or startup hook):

1. Query Providentia for all targets in engagement scope
2. Pull GitLab READMEs for target boxes
3. Pull relevant wiki vulns-docs pages
4. Write structured Obsidian notes with timestamps
5. Log cache timestamp in engagement YAML
6. Warn operator if cache older than 24h at engagement start

### Graceful Degradation (NFR-O5)

| Failure | Impact | Fallback |
|---------|--------|----------|
| Host VPN drops | Lose all range access | Obsidian cache for intel; wait for VPN reconnect |
| Tuoni server crashes | Lose all C2 | SSH to Kali (IP in ipset), restart Tuoni |
| Deploybox reclaimed | Lose green-dev tools | Red-team unaffected; green-dev waits for reallocation |
| Kali unreachable | Lose C2 + Kali tools | Obsidian for intel; escalate to range ops |
| Obsidian MCP fails | Lose notes | Local filesystem fallback; Obsidian is just files |
| Spoke IP changes | ipset stale | Re-run `spoke-firewall.sh` after updating `.env` |

---

## Changes Required

### New Files
- `scripts/spoke-firewall.sh` — read .env spoke IPs, add to ipset (~30 lines)
- `scripts/tests/test-spoke-firewall.sh` — unit tests
- `.claude/skills/kali-bootstrap/SKILL.md` — Tuoni self-agent + plugin verification
- `.claude/skills/pre-engagement-cache/SKILL.md` — cache workflow skill

### Modified Files
- `.devcontainer/init-firewall.sh` — add call to `spoke-firewall.sh` at end (if .env exists)
- `.env.example` — add `PROVIDENTIA_HOST`, `OUTLINE_HOST`; document spoke IP requirements for firewall
- `scripts/check-health.sh` — spoke section checks direct connectivity (curl/ping)
- `scripts/validate-engagement.sh` — add `kali_agent_id`, `cache_timestamp` fields
- `docs/planning/prd-v2.md` — amend FR-K2, add FR-K5, amend NFR-O5
- `docs/planning/prd-v2-addendum.md` — update spoke connectivity decision record

### NOT Modified (no changes needed)
- `.claude/modes/*/settings.json` — env vars already use `${TUONI_URL}` etc.
  which resolve to direct spoke addresses. No port rewriting.
- `.claude/modes/base/settings.json` — hooks unchanged
- `scripts/setup-container-ssh.sh` — SSH config still needed for shell access
  to spokes (operations, not API tunneling)

### PRD Amendments

**FR-K1 (amend):** Add: "Deploy box IP added to container firewall
allow-list for direct TCP access. SSH ProxyJump retained for shell
operations."

**FR-K2 (amend):** Add: "Tuoni self-agent on Kali enables tool execution
through tuoni-mcp. Container reaches Tuoni API directly via firewall
allow-list (spoke IP in ipset). No SSH tunnel required. SSH to Kali
retained for interactive shell access."

**FR-K5 (new):** Engagement resilience — red-team mode has zero dependency on
deploybox. Critical intel pre-cached in Obsidian before engagement start.
Tuoni + Obsidian are the only hard dependencies during live engagement.

**NFR-O5 (amend):** Specify degradation mechanisms: VPN reconnect for range
access, SSH to Kali for Tuoni restart, Obsidian cache for offline intel,
`spoke-firewall.sh` re-run for IP changes.

**Addendum update:** Update "Spoke Connectivity" section to document pivot
from SSH tunnels to specific-IP allow, with rationale.

---

## Resolved Questions

1. **Host → Kali direct via VPN** — confirmed. Host reaches Kali when VPN
   connected. Docker bridge NAT carries container traffic through host.

2. **Tuoni API port** — 8443 (HTTPS). Already in `.env.example` as
   `SPOKE_KALI_C2_WEB_PORT=8443`. Mode configs use `TUONI_URL` +
   `TUONI_TOKEN` env vars.

3. **Docker bridge NAT** — confirmed. Container traffic to non-local IPs
   routes through host automatically. Firewall was blocking, not routing.

4. **Multiple Kali** — single Kali per engagement for now. Additional spoke
   IPs added to ipset for future multi-Kali support (just more `.env` vars).

5. **SSH tunnel vs direct IP** — direct IP chosen. SSH tunnels provided
   marginal security for same-machine hop. Operational cost not justified.
   Host VPN encrypts host→range traffic. Per-host ipset granularity
   prevents subnet-wide exposure.

## Security Analysis

**What stays the same:**
- Deny-by-default firewall (unchanged)
- Internet egress limited to GitHub/npm/Anthropic (unchanged)
- No credentials in repo (unchanged)
- MCP STDIO transport (unchanged)
- Guard stack active in all modes (unchanged)

**What changes:**
- Container can reach specific range IPs directly (was: only via SSH tunnel to host)
- Host:22 egress rule still needed for SSH shell access (not for API tunneling)
- Spoke IPs visible in `.env` (already were — no new exposure)

**Risk assessment:**
- Rogue MCP reaching a spoke IP: same risk as with tunnels (MCP had tunnel
  endpoint too). Mitigation: MCP servers audited, pinned versions (NFR-S4).
- Spoke IP added by mistake: ipset is per-IP, not per-subnet. Blast radius
  is one wrong host, not entire range.
- Container breakout: container can reach allowed IPs. With tunnels, container
  could reach tunneled services. Equivalent exposure.
