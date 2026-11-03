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

Check all required MCPs respond:
- range-intel: query any host to confirm Providentia reachable
- outline-readonly: search for any doc to confirm wiki reachable
- obsidian-mcp: list vault to confirm Obsidian connected
- tuoni-mcp: `tuoni_capabilities` to verify C2 connection + version

If any MCP unreachable: report which and stop. Do NOT cache with
partial sources — operator should fix connectivity first.

### Step 1.5: Plugin and Listener Inventory (ENFORCED)

Verify tuoni-plugins deployment and record available capabilities:

1. `tuoni_command_plugins_list`: list all command plugins deployed
2. `tuoni_aliases_list`: list all DynamicAlias modules available
3. `tuoni_listeners_list`: list active listeners
4. Record in engagement YAML:
   ```yaml
   plugin_inventory:
     command_plugins: [<names>]
     aliases: [<names>]
     listeners: [<names + ports>]
     inventoried_at: <ISO-8601>
   ```
5. Compare against expected plugins (net-recon, cred-dump, persist-swarm,
   lateral-wmi, ad-enum, collect-intel, get-system). Warn if any missing.

This prevents "use cred-dump plugin" instructions failing because plugins
aren't deployed — a known failure mode from redteam-test2.

### Step 2: Read Engagement Targets

Parse engagement YAML `targets` section. Extract list of target hostnames.

If no targets defined: warn operator and stop. Caching without a target
list produces noise, not intel.

### Step 3: Cache Providentia Data

For each target hostname:
1. Query `range_host` via range-intel MCP
2. Write to Obsidian: `llm-wiki/raw/providentia/<hostname>.md`
3. Include: OS, IPs, services, team assignment, role, network segment
4. Frontmatter:
   ```yaml
   ---
   source: providentia
   cached_at: <ISO-8601 timestamp>
   target: <hostname>
   tags: [raw, intake, providentia]
   ---
   ```

If target not found in Providentia: warn and continue (may be external target).

### Step 4: Cache GitLab READMEs

For each target hostname:
1. Query `range_host` with README content via range-intel MCP
2. Write to Obsidian: `llm-wiki/raw/gitlab/<hostname>.md`
3. Include: full README content, deploy notes, known defaults
4. Frontmatter: `source: gitlab`, `cached_at`, `target`, `tags: [raw, intake, gitlab]`

If no README exists: skip silently (not all boxes have READMEs).

### Step 5: Cache Wiki Vulnerability Docs

1. `outline_collection_structure` for vulns-docs collection — understand doc tree
2. Search outline for vulns-docs collection entries relevant to targets
3. For each relevant page:
   - Write to Obsidian: `llm-wiki/wiki/vulnerabilities/<topic>.md`
   - Frontmatter: `source: outline-wiki`, `cached_at`, `collection: vulns-docs`

### Step 5.3: CVE Trending Intelligence (NEW)

1. `cve_trending`: check currently trending CVEs with high EPSS scores
2. Cross-reference against target services from Providentia data
3. If matches found, write to `llm-wiki/wiki/vulnerabilities/trending-<date>.md`
4. Flag matching CVEs in engagement YAML `next_steps` as high-priority vectors

### Step 5.5: Cache Wiki Playbooks (NEW)

1. Search outline for wiki playbooks matching target roles (firewall, DC, mail, etc.)
2. For each relevant playbook:
   - Write to Obsidian: `llm-wiki/wiki/playbooks/<topic>.md`
   - Frontmatter: `source: outline-wiki`, `cached_at`, `collection: doctrine`
3. Parse playbook steps into engagement YAML `next_steps` as checklist items

### Step 6: Cache Wiki Doctrine

1. Search outline for architecture and doctrine docs
2. Write to Obsidian: `llm-wiki/wiki/doctrine/<topic>.md`
3. Frontmatter: `source: outline-wiki`, `cached_at`, `collection: doctrine`

### Step 6.5: Create Engagement Wiki Page (NEW)

1. Create `llm-wiki/wiki/engagements/<engagement-id>.md` using
   template `llm-wiki/templates/engagement.md`
2. Fill: name, start_date, team, scope (from engagement YAML)
3. Update `llm-wiki/index.md` to add engagement to Exercises list
4. Append row to `llm-wiki/log.md`

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
