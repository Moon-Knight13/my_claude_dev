---
name: pre-engagement-cache
description: "Cache Providentia, GitLab, and wiki intel into Obsidian before red-team engagement. Run in green-dev mode when range-intel and outline MCPs are connected. Use when operator says 'cache intel', 'prep for engagement', or before mode switch to red-team."
---

# Pre-Engagement Cache

Cache critical range intel into Obsidian vault so red-team mode is
self-sufficient. Run in green-dev mode where range-intel and outline-readonly
MCPs are connected.

## Prerequisites

- green-dev mode active (range-intel + outline MCPs connected)
- obsidian-mcp connected to vault
- Engagement YAML exists with `targets` list populated
- Operator has confirmed target list (RT-TGT-001)

## Procedure

### Step 1: Verify MCP Connectivity

Check all three required MCPs respond:
- range-intel: query any host to confirm Providentia reachable
- outline-readonly: search for any doc to confirm wiki reachable
- obsidian-mcp: list vault to confirm Obsidian connected

If any MCP unreachable: report which and stop. Do NOT cache with
partial sources — operator should fix connectivity first.

### Step 2: Read Engagement Targets

Parse engagement YAML `targets` section. Extract list of target hostnames.

If no targets defined: warn operator and stop. Caching without a target
list produces noise, not intel.

### Step 3: Cache Providentia Data

For each target hostname:
1. Query `range_host` via range-intel MCP
2. Write to Obsidian: `raw/providentia/<hostname>.md`
3. Include: OS, IPs, services, team assignment, role, network segment
4. Frontmatter:
   ```yaml
   ---
   source: providentia
   cached_at: <ISO-8601 timestamp>
   target: <hostname>
   ---
   ```

If target not found in Providentia: warn and continue (may be external target).

### Step 4: Cache GitLab READMEs

For each target hostname:
1. Query `range_host` with README content via range-intel MCP
2. Write to Obsidian: `raw/gitlab/<hostname>.md`
3. Include: full README content, deploy notes, known defaults
4. Frontmatter: `source: gitlab`, `cached_at`, `target`

If no README exists: skip silently (not all boxes have READMEs).

### Step 5: Cache Wiki Vulnerability Docs

1. Search outline for vulns-docs collection entries relevant to targets
2. For each relevant page:
   - Write to Obsidian: `wiki/vulnerabilities/<topic>.md`
   - Frontmatter: `source: outline-wiki`, `cached_at`, `collection: vulns-docs`

### Step 6: Cache Wiki Doctrine

1. Search outline for architecture and doctrine docs
2. Write to Obsidian: `wiki/doctrine/<topic>.md`
3. Frontmatter: `source: outline-wiki`, `cached_at`, `collection: doctrine`

### Step 7: Update Engagement YAML

Set cache timestamp:
```yaml
cache_timestamp: <ISO-8601 timestamp>
```

### Step 8: Report

Print summary:
- Targets cached: N
- Providentia records: N
- GitLab READMEs: N
- Wiki pages: N
- Targets with NO Providentia data: list (these need investigation)
- Cache timestamp: <ISO-8601>
- Warning if any target had no data from any source

## Staleness Warning

At engagement start (or in red-team preflight), check `cache_timestamp`
in engagement YAML. Warn operator if older than 24 hours — range state
may have changed (new enclaves, IP changes, network re-segmentation).

## Exit Criteria

All must be true:
- [ ] All target Providentia records cached (or warned if missing)
- [ ] All target GitLab READMEs cached (where they exist)
- [ ] Relevant wiki docs cached
- [ ] `cache_timestamp` set in engagement YAML
- [ ] Summary printed with any warnings
