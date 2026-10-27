# Range-Intel MCP Server — Design

**Date:** 2026-10-27
**Status:** Draft
**Location:** New sub-project in `my_claude_dev` (or standalone repo TBD)

## Intent

An AI-orchestrated red team session begins with "target t10" — the operator
names a team, not a list of IPs. Today the orchestrator has no way to resolve
that intent into concrete targets. The operator must manually supply IPs, guess
at services, and correlate vulnerabilities from separate documentation.

This MCP server closes that gap. It unifies range infrastructure data from
**Providentia** (team/host/IP allocation) and **GitLab-hosted VM READMEs** (documented
vulnerabilities and exploitation steps) into a single read-only MCP surface that
the orchestrator queries before issuing commands to the C2 or generic plugins.

### Why now

We proved in testing that 40+ attack vectors fail when the operator (human or AI)
works blind — brute-forcing credentials that were never default, scanning ports
that don't carry the documented vulnerability. The README intel was sitting in
the repo the whole time; we just couldn't access it programmatically or correlate
it with live targeting data.

### What success looks like

Operator says "target t10, go after the file server." Orchestrator:
1. Calls `range_targets("<env>", 10)` — gets the host at its allocated IP
2. Sees vuln manifest: known weaknesses, ports, exploitation steps
3. Picks highest-value vector and issues commands via C2 MCP
4. Never touches a plugin's source code to achieve this

## Goals

1. **Resolve team → hosts → IPs → vulns in one MCP call**
2. **Keep range-specific intel strictly separated from generic plugins** — plugins
   receive `(ip, port, technique)`, never Providentia concepts
3. **Work anywhere** — no local catapult checkout required; fetches READMEs via
   GitLab API
4. **Read-only** — no writes to Providentia, GitLab, or any target system

## Non-goals

- vSphere integration (defer to v2 if live VM power state proves necessary)
- Write operations (creating hosts, modifying READMEs)
- Direct plugin invocation (this is a data source, not an execution layer)
- Wiki/Outline integration in v1 (supplementary, less managed — v2 candidate)

## Anti-goals (would make this a failure)

- **Poisoning plugins** — if any tuoni-plugin imports or references range-intel
  concepts (team numbers, environment IDs, Providentia models), this has failed
- **Bespoke-to-one-range** — if the MCP only works for one exercise or team, it
  has failed. Must work for any Providentia environment with any repo inventory
- **Stale-by-default** — if data requires manual refresh to be current, operators
  won't trust it

## Architecture

### Separation boundary

```
┌─────────────────────────────────────────────────────┐
│  Orchestrator (Claude Code session)                 │
│                                                     │
│  READS:  range-intel MCP  →  targeting decisions    │
│  CALLS:  tuoni MCP + tuoni-plugins  →  execution    │
│                                                     │
│  Plugins receive: (ip, port, technique, params)     │
│  Plugins NEVER see: team_nr, env_id, spec_name,     │
│    or any Providentia / range-intel concept          │
└─────────────────────────────────────────────────────┘
```

The orchestrator is the **sole consumer** of range-intel. It translates
environment-specific intelligence into generic parameters that any plugin can
accept. If range-intel MCP isn't connected, the orchestrator falls back to
operator-supplied targeting (manual IPs, manual vuln hints). Plugins work
identically either way.

### Data sources

| Source | What it provides | Access method | Auth |
|--------|-----------------|---------------|------|
| Providentia v3 API | Environments, teams, hosts, instances (per-team IPs), networks, tags | HTTPS REST (`/api/v3/`) | Local API token (header `Authorization: Token <key>`) |
| GitLab repo | VM READMEs with vuln frontmatter + exploitation steps | GitLab API v4 (Repository Files) | Personal access token (`read_repository`) |

### Providentia data model (relevant subset)

```
Environment
  ├── id, name, description
  ├── teams: {actor_name: [team_nrs]}
  └── hosts[]
        ├── id, spec_name, role, actor_id, tags[]
        └── instances[] (one per team)
              ├── id, vm_name, hostname, fqdn
              ├── connection_address
              ├── team_nr, team_nr_str
              └── interfaces[]
                    └── addresses[] {address, gateway, dns_enabled}
```

Key: `host.spec_name` is the merge key to VM directories in the GitLab repo.

### VM README model (parsed)

```
VMProfile
  ├── box_name, category, platform
  ├── domains[]
  ├── contains_vulns[]        # CVE IDs or common names
  ├── vuln_paths[]            # Ansible role paths
  ├── mitre_attack_ids[]
  ├── last_updated
  └── implemented_vulns[]     # Parsed from "Implemented Vulnerabilities" section
        ├── name              # Role name or description
        ├── description       # How to exploit
        └── abuse_steps[]     # Step-by-step exploitation
```

### Merge logic

**Providentia is source of truth for identity.** Range naming conventions change
year-to-year; directory names in the repo may be stale. Providentia knows the
current `spec_name`; the README index provides vuln enrichment.

**Step 1 — Build README index (startup + cached refresh):**
Fetch all `vm/*/README.md` files via GitLab API. Parse frontmatter. Build lookup:
```
{
  "webserver":  {boxName: "WebServer",  domains: ["blue"], platform: "linux", ...},
  "dc-blue":    {boxName: "DC-Blue",    domains: ["blue"], platform: "windows", ...},
  ...
}
```
Index keyed by directory name, with boxName as alternate key.

**Step 2 — Match Providentia host → README:**
For each Providentia host, resolve to a README using cascading match:
1. `spec_name` == directory name (fast path, exact match)
2. `spec_name` normalized ↔ `boxName` normalized (case-insensitive, strip hyphens)
3. Tag/domain correlation as tiebreaker (Providentia tags vs README `domains[]`)
4. Explicit override file (`mapping_overrides.json`) for stubborn mismatches

If no match: return Providentia data without vuln enrichment (graceful degradation).

**Step 3 — Merge:**
```
Providentia                          GitLab repo
───────────                          ──────────────────────
host.spec_name = "webserver"     ──→ vm/webserver/README.md (matched step 1)
                                     ├── frontmatter → containsVulns, platform
instance.team_nr = 10                └── body → implemented_vulns[]
instance.addresses → <allocated IP>
                    ↓
            MERGED TARGET
            {
              host_id: "webserver",
              ip: "<allocated IP>",
              platform: "linux",
              match_method: "exact",     # how the README was matched
              vulns: [
                {name: "web_backdoor", port: 8080, access: "root"},
                {name: "weak_users", description: "Default credentials"},
                ...
              ]
            }
```

### Vuln role enrichment (bonus layer)

Beyond README frontmatter, the MCP can parse the actual Ansible vuln role files
(e.g., `roles/vulns/linux/initial_access_ttyd_webshell/defaults/main.yml`) to
extract concrete parameters: ports, usernames, binary paths. This gives the
orchestrator actionable details like "ttyd on port 7681 running as root with
/usr/bin/bash" rather than just "ttyd_webshell exists."

Source: GitLab API, same auth. Path pattern:
`<GITLAB_VULN_PATH>/{platform}/{vuln_name}/`

## MCP Tools

### range_environments

List available exercises from Providentia.

```
Input:  (none)
Output: [{id: string, name: string}]
Source: GET /api/v3/
```

### range_targets

**The primary tool.** Full targeting manifest for a team.

```
Input:  {env: string, team_nr: int, host_filter?: string}
Output: [{
  host_id: string,
  spec_name: string,
  role: string,
  platform: string,
  tags: string[],
  instance: {
    vm_name: string,
    hostname: string,
    fqdn: string,
    connection_address: string,
    interfaces: [{network_id, address, gateway}]
  },
  vulns: [{
    name: string,
    category: string,         # initial_access | privesc | persist | ...
    description: string,
    abuse_steps: string[],
    parameters: object        # port, username, binary, etc. from role defaults
  }],
  mitre_attack_ids: string[]
}]
Source: Providentia inventory + GitLab READMEs + vuln role defaults (merged)
Cache:  Providentia 5min TTL, READMEs 30min TTL, vuln roles 30min TTL
```

### range_host

Single host detail with full enrichment.

```
Input:  {env: string, host_id: string, team_nr?: int}
Output: (same shape as one range_targets entry, with full README body included)
```

### range_networks

Network topology for a team.

```
Input:  {env: string, team_nr?: int}
Output: [{
  id: string,
  name: string,
  team_instance: {cloud_id, domains[], address_pools: [{ip_family, network_address, gateway}]}
}]
Source: GET /api/v3/:env/networks
```

### range_vuln_lookup

Find which hosts carry a specific vulnerability.

```
Input:  {env: string, vuln_name: string}
Output: [{
  host_id: string,
  platform: string,
  vuln: {name, description, abuse_steps, parameters},
  team_instances: [{team_nr, ip}]   # every team that has this host
}]
Source: Cross-reference all READMEs against vuln_name
```

### range_tags

Environment tags (OS types, zones, team colors).

```
Input:  {env: string}
Output: [{id, name, config_map, children}]
Source: GET /api/v3/:env/tags
```

## Tech Stack

- **Python 3.12+** — matches tuoni-mcp patterns
- **mcp** (official Python MCP SDK)
- **httpx** — async HTTP for Providentia and GitLab APIs
- **python-frontmatter** — README YAML frontmatter parsing
- **pydantic** — data models and validation
- Caching: in-memory with configurable TTLs per source

## Configuration

```env
# Providentia
PROVIDENTIA_URL=                         # e.g. https://providentia.example.com
PROVIDENTIA_TOKEN=                       # local API token from /api_tokens

# GitLab — domain-scoped: MCP ONLY reaches this GitLab instance.
# Prevents accidental leakage to other git hosts.
# Accept namespace/path — resolved to project ID at startup.
GITLAB_URL=                              # e.g. https://gitlab.example.com
GITLAB_TOKEN=                            # PAT with read_repository scope
GITLAB_PROJECT=                          # namespace/path or numeric ID
GITLAB_REF=main                          # branch to read READMEs from
GITLAB_VM_PATH=                          # path to VM directories containing README.md
GITLAB_VULN_PATH=                        # path to vuln roles directory

# Optional
CACHE_TTL_PROVIDENTIA=300                # seconds
CACHE_TTL_README=1800
MAPPING_OVERRIDES=mapping_overrides.json # explicit spec_name → dir overrides
LOG_LEVEL=INFO
```

## Project structure

```
range-intel-mcp/
├── pyproject.toml
├── README.md
├── src/
│   └── range_intel/
│       ├── __init__.py
│       ├── server.py              # MCP server entry point
│       ├── tools.py               # MCP tool definitions
│       ├── models.py              # Pydantic data models
│       ├── clients/
│       │   ├── __init__.py
│       │   ├── providentia.py     # Providentia API v3 client
│       │   └── gitlab.py          # GitLab Repository Files client
│       ├── parsers/
│       │   ├── __init__.py
│       │   ├── readme.py          # README frontmatter + body parser
│       │   └── vuln_role.py       # Ansible vuln role defaults parser
│       ├── enrichment.py          # Merge logic: Providentia + README + roles
│       └── cache.py               # TTL cache layer
├── tests/
│   ├── test_providentia_client.py
│   ├── test_gitlab_client.py
│   ├── test_readme_parser.py
│   ├── test_enrichment.py
│   └── fixtures/                  # Sample API responses + READMEs
└── .claude/
    └── settings.local.json
```

## Constraints

- **No secrets in repo** — tokens via env vars or `.env` (gitignored)
- **No writes** — every API call is GET; no POST/PUT/DELETE anywhere
- **Graceful degradation** — if Providentia is down, return error with
  cache-stale data if available. If GitLab is down, return Providentia data
  without vuln enrichment. Never block on a secondary source.
- **No range-specific hardcoding** — environment ID, team numbers, host names
  all come from API responses, never from constants in code

## Builder decisions (settled during review)

- **GitLab project resolution** — accept `namespace/path` in config, resolve to
  numeric project ID at startup via `GET /api/v4/projects/:encoded_path`
- **`host_filter` semantics** — substring match on `spec_name`
- **Vuln category** — infer from role name prefix convention
  (`initial_access_*` → initial_access, `privesc_*` → privesc). Return null
  when ambiguous.
- **IP field** — `connection_address` as primary, full `interfaces[]` nested
- **Cache keys** — include `GITLAB_REF` so branch switch mid-session works
- **One repo per instance** — for multiple GitLab repos, run multiple MCP
  instances with different `.env` configs. No multi-repo mapping in v1.
- **Inventory path** — configurable via `GITLAB_VM_PATH` and `GITLAB_VULN_PATH`

## Open questions (builder's call)

- **README parsing robustness** — READMEs vary in quality (some have no
  "Implemented Vulnerabilities" section, some have broken YAML frontmatter).
  Parser should be tolerant and return partial data rather than failing.
- **Vuln role depth** — How deep to parse Ansible roles? v1: just
  `defaults/main.yml` for parameters. v2: parse `tasks/main.yml` for port
  numbers, service names, etc.
