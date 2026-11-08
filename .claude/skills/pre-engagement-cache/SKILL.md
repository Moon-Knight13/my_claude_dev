---
name: pre-engagement-cache
description: "Cache Providentia, GitLab, and wiki intel into Obsidian before engagement. Full inventory sweep — targets selected after cache from reachability scan. Use when operator says 'cache intel', 'prep for engagement', 'cache --lite'."
modes: [red-team, purple]
---

# Pre-Engagement Cache

Cache critical range intel into Obsidian vault so engagement threads are
self-sufficient. Run when range-intel and outline-readonly MCPs are connected
(any mode — red-team, green-dev, or purple).

## Prerequisites

- range-intel + outline-readonly MCPs connected (any mode)
- obsidian-mcp connected to vault
- Engagement Obsidian page exists (created by engagement-state skill)
- Targets NOT required — cache does full Providentia inventory sweep.
  Operator selects targets FROM cached data after Phase 1 reachability scan.

## Token Cost Budget

Each source contributes tokens when its cached data is later read into
conversation context by downstream skills (recon, initial-access, etc.).
Estimates per target (7 targets = multiply by 7):

| Source | Tokens/target | 7 targets | Notes |
|--------|--------------|-----------|-------|
| Providentia host record | ~800 | ~5,600 | OS, IPs, services, role, network |
| GitLab README | ~2,000 | ~14,000 | Varies wildly (500–5,000). Deploy notes, defaults, vulns |
| Wiki vuln docs | ~1,500 | ~10,500 | Per matching vuln page from outline |
| CVE trending cross-ref | ~400 | ~2,800 | Only if matches found |
| Wiki playbooks | ~1,200 | ~8,400 | Per matching role playbook |
| Wiki doctrine | ~1,000 | ~7,000 | Architecture + doctrine (shared, not per-target) |
| Plugin inventory | ~300 | ~300 | One-time, not per-target |
| **Full cache total** | **~7,200** | **~48,600** | Worst case ~50k tokens before any work begins |

At 20 targets: ~130k tokens. Context pressure becomes real.

### Lite Summary Format

When `--lite` is active, downstream skills receive a compressed summary
per target instead of full cached pages:

```
<hostname> | <ip> | <os> | Top ports: <3 key ports> | Top vulns: <3 CVE IDs or short names> | Role: <role>
```

Approx 80–120 tokens per target. 7 targets = ~700 tokens. 20 targets = ~2,000.

Skills that need full detail read specific target pages from Obsidian
on-demand via `obsidian_read_note`.

## Selective Loading Modes

### Default (full cache)

`cache intel` or `prep for engagement` — runs all steps, loads everything
into Obsidian. Downstream skills read full pages into context.

### Lite mode

`cache intel --lite` or `cache --lite` — caches everything to Obsidian
(full data preserved) but only loads compressed summaries into context.
Full data available on-demand from Obsidian when a skill targets a
specific host.

### Source-selective mode

`cache intel --sources providentia,gitlab` — cache only named sources.
Valid source names: `providentia`, `gitlab`, `wiki-vulns`, `wiki-playbooks`,
`wiki-doctrine`, `cve-trending`, `plugins`.

Combine with lite: `cache intel --lite --sources providentia,gitlab`.

### Target-selective mode

`cache intel --targets <host1>,<host2>` — cache only named targets
instead of full target list from engagement YAML. Useful for focused
recon on specific hosts.

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

### Step 1.8: Parse Selective Loading Flags

Parse operator command for flags:
- `--lite`: set `lite_mode = true`. Cache full data to Obsidian but only
  load summaries into context.
- `--sources <list>`: set `selected_sources` to comma-separated list.
  Valid: `providentia`, `gitlab`, `wiki-vulns`, `wiki-playbooks`,
  `wiki-doctrine`, `cve-trending`, `plugins`. Default: all.
- `--targets <list>`: set `selected_targets` to comma-separated hostnames.
  Default: all targets from engagement YAML.

If no flags: full cache mode (backward compatible).

### Step 2: Read Engagement Targets

Parse engagement YAML `targets` section. Extract list of target hostnames.
If `--targets` flag present, filter to only named targets.

If no targets defined: warn operator and stop. Caching without a target
list produces noise, not intel.

### Step 3: Cache Providentia Data

**Skip if** `--sources` set and `providentia` not in list.

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

**Skip if** `--sources` set and `gitlab` not in list.

For each target hostname:
1. Query `range_host` with README content via range-intel MCP
2. Write to Obsidian: `llm-wiki/raw/gitlab/<hostname>.md`
3. Include: full README content, deploy notes, known defaults
4. Frontmatter: `source: gitlab`, `cached_at`, `target`, `tags: [raw, intake, gitlab]`

If no README exists: skip silently (not all boxes have READMEs).

### Step 5: Cache Wiki Vulnerability Docs

**Skip if** `--sources` set and `wiki-vulns` not in list.

1. `outline_collection_structure` for vulns-docs collection — understand doc tree
2. Search outline for vulns-docs collection entries relevant to targets
3. For each relevant page:
   - Write to Obsidian: `llm-wiki/wiki/vulnerabilities/<topic>.md`
   - Frontmatter: `source: outline-wiki`, `cached_at`, `collection: vulns-docs`

### Step 5.3: CVE Trending Intelligence (NEW)

**Skip if** `--sources` set and `cve-trending` not in list.

1. `cve_trending`: check currently trending CVEs with high EPSS scores
2. Cross-reference against target services from Providentia data
3. If matches found, write to `llm-wiki/wiki/vulnerabilities/trending-<date>.md`
4. Flag matching CVEs in engagement YAML `next_steps` as high-priority vectors

### Step 5.5: Cache Wiki Playbooks (NEW)

**Skip if** `--sources` set and `wiki-playbooks` not in list.

1. Search outline for wiki playbooks matching target roles (firewall, DC, mail, etc.)
2. For each relevant playbook:
   - Write to Obsidian: `llm-wiki/wiki/playbooks/<topic>.md`
   - Frontmatter: `source: outline-wiki`, `cached_at`, `collection: doctrine`
3. Parse playbook steps into engagement YAML `next_steps` as checklist items

### Step 6: Cache Wiki Doctrine

**Skip if** `--sources` set and `wiki-doctrine` not in list.

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

### Step 7.5: Generate Context Summaries (Lite Mode)

**Only when** `--lite` is active.

For each cached target, generate compressed summary line:
```
<hostname> | <ip> | <os> | Top ports: <3 key ports> | Top vulns: <3 CVE IDs> | Role: <role>
```

Write all summaries to `llm-wiki/raw/cache-summary-<engagement-id>.md`.
This file is what downstream skills load into context instead of full pages.

Set in engagement YAML:
```yaml
cache_mode: lite
cache_summary_path: llm-wiki/raw/cache-summary-<engagement-id>.md
```

When `cache_mode: lite`, downstream skills (recon, initial-access, etc.)
MUST read the summary file first, then `obsidian_read_note` for specific
targets only when full detail is needed.

### Step 8: Report

Print summary:
- **Mode**: full | lite | selective (list sources)
- Targets cached: N (of M total)
- Sources cached: list of sources run
- Sources skipped: list of sources not run (if `--sources` active)
- Providentia records: N
- GitLab READMEs: N
- Wiki pages: N
- Targets with NO Providentia data: list (these need investigation)
- Cache timestamp: <ISO-8601>
- **Estimated context tokens**: total based on token cost table above
- **Lite mode savings**: if lite, show full vs lite token estimate
- Warning if any target had no data from any source

## Staleness Warning

At engagement start (or in red-team preflight), check `cache_timestamp`
in engagement YAML. Warn operator if older than 24 hours — range state
may have changed (new enclaves, IP changes, network re-segmentation).

## Exit Criteria

All must be true:
- [ ] All selected target Providentia records cached (or warned if missing)
- [ ] All selected target GitLab READMEs cached (where they exist)
- [ ] Selected wiki docs cached (all if no `--sources` filter)
- [ ] `cache_timestamp` set in engagement YAML
- [ ] `cache_mode` set in engagement YAML (full or lite)
- [ ] If lite: summary file generated at `cache_summary_path`
- [ ] Summary printed with token cost estimate and any warnings
