# Guacamole Engagement Integration — Design Document

**Issue:** #303
**Status:** Design — not yet implemented
**Author:** MoonKnight13
**Date:** 2026-11-27

## Background

Guacamole 1.5.5 is deployed on Kali (rtt-kali-dev04) via the Ansible role at
`playbooks/roles/guacamole/`. PR #364 merged 2026-11-18, closing #302. The
stack runs three containers (guacd, guacamole-web on port 8080, postgres
16-alpine) managed by Docker Compose at `/opt/guacamole/`.

The base deployment handles static SSH/RDP connections with manual admin-panel
configuration. This design extends it for dynamic engagement use:

1. **Connection templating** — add/remove RDP/SSH targets as engagement evolves
2. **SOCKS proxy routing** — reach firewalled targets through Tuoni footholds
3. **Listener diversification** — multiple Tuoni listener types to avoid
   single-signature detection

### Origin

CTF exercise lessons #30–#33 and #235. During the November CTF, sql02 was
unreachable from Kali without a pivot, and all C2 traffic used a single HTTPS
listener on :443 — an obvious Tuoni signature.

---

## 1. Connection Templating

### Problem

Connections are currently created by hand through Guacamole admin UI or REST
API. An engagement may add 5–15 targets over hours; manual creation is slow and
error-prone. The harness needs programmatic connection management tied to
engagement state.

### Design

Add a `guacamole_connections` section to the engagement YAML schema
(`schemas/engagement.yaml`):

```yaml
guacamole_connections:
  - hostname: fw-target
    protocol: rdp          # rdp | ssh | vnc
    ip: "198.51.100.1"
    port: 3389
    cred_ref: cred-001     # reference into cred_refs[]
    proxy: null             # or proxy ref (see §2)
    recording: true
    status: active          # active | removed
  - hostname: sql02
    protocol: rdp
    ip: "10.20.30.42"
    port: 3389
    cred_ref: cred-003
    proxy: socks-fw         # routed through foothold (see §2)
    recording: true
    status: active
```

### Connection lifecycle

```
engagement-state skill adds target
  → operator approves target (RT-TGT-001)
  → guac-sync creates Guacamole connection via REST API
  → engagement YAML updated with connection entry
  → operator uses connection through T3 preview_open

target removed or engagement ends
  → guac-sync deletes connection via REST API
  → engagement YAML entry marked status: removed
```

### Implementation: `guac-sync` script

A Python script (`scripts/guac-sync.py`) that:

1. Reads engagement YAML `guacamole_connections[]`
2. Authenticates to Guacamole REST API (`POST /api/tokens`)
3. Lists existing connections (`GET /api/session/data/postgresql/connections`)
4. Diffs desired vs actual state
5. Creates missing connections (`POST /api/session/data/postgresql/connections`)
6. Removes connections marked `status: removed`
7. Configures proxy settings for SOCKS-routed connections (see §2)

Connection parameters map to Guacamole REST API:

| YAML field   | Guacamole API parameter          |
|-------------|----------------------------------|
| `protocol`  | `protocol`                       |
| `ip`        | `parameters.hostname`            |
| `port`      | `parameters.port`                |
| `cred_ref`  | resolved → `parameters.username` / `parameters.password` |
| `proxy`     | `parameters.proxy-hostname`, `proxy-port`, `proxy-type` |
| `recording` | `parameters.recording-path`, `recording-name` |

Credentials are resolved from tuoni cred store (via tuoni-mcp) at sync time —
never stored in engagement YAML or Guacamole config files.

### Skill integration

The `engagement-state` skill gains a new action: `guac-sync`. After any target
add/remove, the skill calls `guac-sync.py` to reconcile Guacamole connections.
This keeps the connection list in lockstep with engagement targets.

---

## 2. SOCKS Proxy Routing

### Problem

Firewalled targets (e.g., internal VLAN hosts) are not reachable from Kali
directly. During the CTF, sql02 required pivoting through a compromised host.
Guacamole supports SOCKS proxy natively via `guacd` parameters, but no
automation exists to wire this up.

### Design

Add a `socks_proxies` section to engagement YAML:

```yaml
socks_proxies:
  - id: socks-fw
    foothold_agent: agent-fw    # tuoni agent providing the tunnel
    listen_host: "127.0.0.1"
    listen_port: 1080
    type: socks5
    status: active
    reachable_nets:
      - "10.20.30.0/24"
      - "10.20.31.0/24"
```

### Routing flow

```
Guacamole connection (sql02, proxy: socks-fw)
  → guacd connects to 127.0.0.1:1080 (SOCKS5)
  → Tuoni C2 tunnel forwards through agent-fw
  → agent-fw routes to 10.20.30.42:3389
  → RDP session established through pivot
```

Guacamole's native SOCKS support means no proxychains wrapper is needed for
Guacamole connections. The `guac-sync` script maps `proxy: socks-fw` to the
corresponding `proxy-hostname`, `proxy-port`, and `proxy-type` parameters.

### SOCKS proxy setup

Tuoni's built-in SOCKS proxy is activated through tuoni-mcp:

1. `lateral-move` skill identifies foothold with routes to target network
2. SOCKS proxy started on foothold via tuoni agent command
3. Proxy registered in engagement YAML `socks_proxies[]`
4. `guac-sync` reads proxy config and applies to relevant connections

### Kali-side proxychains (non-Guacamole tools)

For tools other than Guacamole (nmap, crackmapexec, etc.), generate
`/etc/proxychains4.conf` entries from `socks_proxies[]`. This is a separate
concern from Guacamole but shares the same SOCKS infrastructure.

```
# Auto-generated from engagement YAML — do not edit
[ProxyList]
socks5 127.0.0.1 1080   # socks-fw → 10.20.30.0/24, 10.20.31.0/24
```

---

## 3. Listener Diversification

### Problem

All Tuoni agents currently use a single HTTPS listener on :443 with default
parameters. This creates:

- **Single signature** — defenders detect one C2 profile
- **Single point of failure** — if :443 is blocked, all agents lose comms
- **Easy fingerprinting** — default URIs (`/get`, `/post`, `/payload`), default
  cookie (`JWT_SESSION`), self-signed cert

### Design

This component extends the engagement YAML with listener profiles and modifies
`persist-swarm` to assign listeners per agent type.

```yaml
listeners:
  - id: https-primary
    type: reverse_https
    port: 443
    uris: ["/api/v2/telemetry", "/cdn/health"]
    cookie: "__cf_bm"
    user_agent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
    sleep: 30
    jitter: 15
    tls_cert: letsencrypt     # or self-signed, custom-pkcs12
    status: active

  - id: smb-relay
    type: bind_smb
    pipe_name: "\\spoolss_alt"
    status: active
    note: "Agent-to-agent lateral, zero external traffic"

  - id: dns-sleeper
    type: reverse_dns
    domain: "telemetry.example.com"
    sleep: 300
    status: planned            # requires commercial license
```

### persist-swarm integration

`persist-swarm` currently deploys dual-beacon (operational + sleeper) using the
same listener. With diversification:

| Agent type   | Listener assignment            |
|-------------|-------------------------------|
| Operational  | `https-primary` (30s beacon)  |
| Sleeper      | `dns-sleeper` or `https-primary` with long sleep |
| Lateral relay| `smb-relay` (no external traffic) |

The skill reads `listeners[]` from engagement YAML and selects by type. If only
one listener exists, it falls back to current behavior (single listener for
both).

### Listener creation

Listeners are created through tuoni-mcp before engagement start:

1. Operator defines listener profiles in engagement YAML
2. `kali-bootstrap` or a new `listener-setup` script creates listeners via
   tuoni-mcp
3. Listener IDs in engagement YAML map to tuoni listener IDs
4. Skills reference listeners by engagement YAML ID, resolved to tuoni ID at
   runtime

---

## Dependencies and Blockers

| Dependency | Status | Impact |
|-----------|--------|--------|
| #302 Guacamole base deploy | **Closed** (PR #364 merged) | None — prerequisite satisfied |
| Tuoni SOCKS proxy capability | **Partial** — built-in SOCKS exists in Tuoni, #186 plugin story closed but plugin not built | SOCKS routing blocked until tuoni-mcp exposes SOCKS setup |
| Tuoni listener creation via MCP | **Available** — tuoni-mcp has listener tools | None |
| Guacamole REST API access from Kali | **Working** — proven in PoC | None |
| Commercial Tuoni license (DNS listener) | **Not available** | DNS listener deferred; design works without it |

### Known limitations

- **Keyboard passthrough**: T3 preview canvas apps don't pass keystrokes when
  operator takes over. Agent can type via `press` key-by-key. Workaround
  research dispatched but unresolved.
- **NLA-enforcing targets**: RDP connections fail on hosts requiring Network
  Level Authentication unless credentials are provided upfront. `guac-sync`
  must resolve credentials before creating the connection.

---

## Decomposed Stories

Each story is independently implementable. Suggested ordering reflects
dependencies.

### Story 1: Engagement YAML schema extension

**What:** Add `guacamole_connections`, `socks_proxies`, and `listeners`
sections to `schemas/engagement.yaml`.

**Acceptance:**
- Schema validates with new sections
- Existing engagement files remain valid (all new sections optional)
- Schema documented in comments

**Estimate:** Small

---

### Story 2: guac-sync connection management script

**What:** Python script that reconciles Guacamole connections with engagement
YAML. Creates, updates, removes connections via REST API.

**Acceptance:**
- Reads `guacamole_connections[]` from engagement YAML
- Creates connections with correct protocol, IP, port, credentials
- Removes connections marked `status: removed`
- Idempotent — running twice produces same state
- Credentials resolved from tuoni cred store, never hardcoded

**Depends on:** Story 1

**Estimate:** Medium

---

### Story 3: engagement-state skill integration

**What:** Add `guac-sync` action to engagement-state skill. Auto-runs after
target add/remove.

**Acceptance:**
- `engagement-state` calls `guac-sync` after target mutations
- Connection entries added to engagement YAML automatically
- Operator can manually trigger sync

**Depends on:** Story 2

**Estimate:** Small

---

### Story 4: SOCKS proxy registration and Guacamole routing

**What:** Wire SOCKS proxy setup through tuoni-mcp into engagement YAML and
guac-sync.

**Acceptance:**
- SOCKS proxy started on foothold via tuoni agent
- Proxy registered in `socks_proxies[]`
- `guac-sync` applies proxy settings to connections with `proxy:` field
- Connection to firewalled target works through pivot

**Depends on:** Story 2, tuoni SOCKS proxy capability

**Estimate:** Medium

---

### Story 5: proxychains config generation

**What:** Generate `/etc/proxychains4.conf` from engagement YAML
`socks_proxies[]` for non-Guacamole tools.

**Acceptance:**
- Config generated from engagement YAML
- Existing manual entries preserved (append, don't overwrite)
- lateral-move skill uses generated config

**Depends on:** Story 4

**Estimate:** Small

---

### Story 6: Listener diversification profiles

**What:** Add listener profiles to engagement YAML and create listeners via
tuoni-mcp.

**Acceptance:**
- `listeners[]` section in engagement YAML
- Listener creation script/function using tuoni-mcp
- Listener IDs mapped between engagement YAML and tuoni

**Depends on:** Story 1

**Estimate:** Medium

---

### Story 7: persist-swarm listener assignment

**What:** Modify persist-swarm to assign different listeners to different
agent types based on engagement YAML profiles.

**Acceptance:**
- Operational agents use primary HTTPS listener
- Sleeper agents use DNS or long-sleep HTTPS
- Lateral relay agents use SMB listener (when available)
- Falls back to single listener if only one defined

**Depends on:** Story 6

**Estimate:** Small

---

## Implementation Order

```
Wave 1 (foundation):
  Story 1: Schema extension
  Story 6: Listener profiles        (independent of connection templating)

Wave 2 (connection management):
  Story 2: guac-sync script
  Story 3: engagement-state integration

Wave 3 (routing):
  Story 4: SOCKS proxy + Guacamole routing
  Story 5: proxychains generation
  Story 7: persist-swarm listener assignment
```

Wave 1 and Wave 2 can overlap — schema lands first, then guac-sync and
listener setup build on it in parallel. Wave 3 depends on Wave 2 completion.

---

## Out of Scope

- Guacamole user/group management (single operator, guacadmin sufficient)
- Guacamole session recording playback UI (recordings stored, playback manual)
- T3 Device native SSH integration (separate long-term path)
- VNC protocol support (RDP and SSH cover all current targets)
- CDN domain fronting (requires CDN access not currently available)
