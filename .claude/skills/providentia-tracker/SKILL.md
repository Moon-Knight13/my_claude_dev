---
name: providentia-tracker
description: "Track Providentia data accuracy. Log discrepancies found during engagements, query accuracy history. Triggers: 'log accuracy', 'providentia accuracy', 'accuracy finding', 'what broke on', 'accuracy summary', 'broken vulns', 'working vulns', 'verify providentia'."
modes: [red-team, purple, red-dev, platform-ops]
---

# Providentia Accuracy Tracker

Track discrepancies between Providentia ground truth data and actual range state.
Findings persist in Obsidian (`llm-wiki/wiki/providentia-accuracy/`) across
engagements, so pre-engagement-cache can flag known-broken vulns.

**Why:** Providentia data is aspirational (what SHOULD be deployed), not always
factual. Engagements waste time retrying vectors that are broken on specific hosts.
This tracker closes the feedback loop.

## Operations

### Log Accuracy Finding

Trigger: operator says "log accuracy", "providentia wrong", "vuln broken",
"vuln not working", or automatic when engagement-state reclassifies a target
as `different-than-expected` or `patched`.

**Input fields:**

| Field | Required | Description |
|-------|----------|-------------|
| `vuln_name` | yes | Providentia vulnerability/service name (e.g. `sqli_login`, `rsh_service`) |
| `hostname` | yes | Host where finding was made |
| `expected` | yes | What Providentia said (e.g. "listed as vulnerable") |
| `actual` | yes | What was found (e.g. "service not running", "patched", "config changed") |
| `severity` | no | `cosmetic` (label wrong), `misleading` (wastes time), `dangerous` (causes wrong assumptions). Default: `misleading` |
| `engagement_id` | no | Current engagement ID (auto-read from engagement YAML if active) |
| `notes` | no | Why broken, additional context |

**Procedure:**

1. Normalize `vuln_name` to lowercase slug (spaces to underscores, strip special chars).

2. Read engagement YAML from `engagements/` if exists — extract `engagement_id`.

3. Search Obsidian for existing accuracy page:
   `obsidian_search_vault` in vault `my_notes`, query: `providentia-accuracy {{vuln_name}}`

4. **If page exists** (`llm-wiki/wiki/providentia-accuracy/{{vuln_name}}.md`):
   a. Read with `obsidian_read_note`.
   b. Check `## Host Status` table for existing row matching `hostname`.
      - **Row exists**: update `Actual Status`, `Verified` date, `Notes` via `obsidian_edit_note`.
      - **No row**: append new row to `## Host Status` table.
   c. Append entry to `## Verification History`:
      ```markdown
      ### Verified: {{date}} — {{engagement_id}}
      - **Hosts tested**: {{hostname}}
      - **Working**: {{working_list or "none"}}
      - **Broken**: {{broken_list or "none"}}
      - **Notes**: {{notes}}
      ```
   d. Update frontmatter `last_verified` to current date.
   e. Update frontmatter `severity` if new finding is higher severity.

5. **If page does not exist**:
   a. Create from template `llm-wiki/templates/providentia-accuracy.md` via
      `obsidian_create_note` at path `llm-wiki/wiki/providentia-accuracy/{{vuln_name}}.md`.
   b. Fill template: vuln_name, severity, date.
   c. Add first host row to `## Host Status` table.
   d. Add first verification history entry.

6. Apply Obsidian tags via `obsidian_add_tags`:
   - `#providentia-accuracy`
   - `#severity/{{severity}}`
   - `#target/{{hostname}}`
   - `#engagement/{{engagement_id}}` (if active engagement)

7. Append row to `llm-wiki/log.md`:
   `| {{date}} | [[providentia-accuracy/{{vuln_name}}]] | {{created_or_updated}} | {{vuln_name}} {{actual}} on {{hostname}} |`

8. Report:
   ```
   Accuracy finding logged: [[providentia-accuracy/{{vuln_name}}]]
   Host: {{hostname}} — expected: {{expected}}, actual: {{actual}}
   Severity: {{severity}}
   Page: {{created | updated}}
   ```

### Query Accuracy Findings

Trigger: "accuracy summary", "broken vulns", "what broke", "working vulns",
"accuracy for host X", "providentia accuracy", "verify providentia".

**Query types:**

| Query | Action |
|-------|--------|
| "accuracy summary" / "broken vulns" | List all accuracy pages, group by severity |
| "accuracy for host X" / "what broke on X" | Filter accuracy pages mentioning hostname X |
| "working vulns" | List vulns with at least one "working" host status |
| "accuracy for vuln X" | Read specific accuracy page |
| "dangerous accuracy" | Filter pages with severity = dangerous |

**Procedure:**

1. Search Obsidian: `obsidian_search_vault` in vault `my_notes`,
   query: `tag:#providentia-accuracy`

2. Read each matching page with `obsidian_read_note`.

3. Parse `## Host Status` tables to build summary.

4. Apply filters based on query type.

5. Report:
   ```
   ## Providentia Accuracy Summary

   **Dangerous** ({{count}}):
   | Vuln | Hosts Broken | Hosts Working | Last Verified |
   |------|-------------|---------------|---------------|

   **Misleading** ({{count}}):
   | Vuln | Hosts Broken | Hosts Working | Last Verified |
   |------|-------------|---------------|---------------|

   **Cosmetic** ({{count}}):
   | Vuln | Hosts Broken | Hosts Working | Last Verified |
   |------|-------------|---------------|---------------|

   Total: {{total}} findings across {{host_count}} hosts
   ```

### Pre-Engagement Accuracy Check

Trigger: auto-invoked by `pre-engagement-cache` after caching Providentia data,
or operator says "check accuracy before engagement".

**Procedure:**

1. Read cached Providentia data for engagement targets.

2. For each target's listed vulnerabilities, search accuracy pages:
   `obsidian_search_vault` for `providentia-accuracy {{vuln_name}}`

3. Cross-reference: if accuracy page shows vuln as "broken" on this host
   or on other hosts of same OS/role, flag it.

4. Report flagged vulns to operator:
   ```
   ## Known Accuracy Issues for Engagement Targets

   ⚠ {{vuln_name}} — broken on {{N}} hosts ({{severity}})
     Listed on: {{target_hostname}}
     Previously broken on: {{other_hosts}}
     Notes: {{notes}}

   {{count}} of {{total_vulns}} listed vulns have known accuracy issues.
   ```

5. Return structured data for recon/initial-access to deprioritize broken vectors:
   ```yaml
   flagged_vulns:
     - vuln_name: "{{name}}"
       severity: "{{severity}}"
       broken_hosts: [list]
       notes: "{{notes}}"
   ```

## Integration Points

| Skill | Integration |
|-------|-------------|
| `engagement-state` | Reclassify `different-than-expected` or `patched` auto-invokes log finding |
| `pre-engagement-cache` | After cache, auto-invokes pre-engagement accuracy check |
| `recon` | Accuracy flags deprioritize known-broken vectors |
| `initial-access` | Research gate checks accuracy before attempting vuln |

## File Locations

- `llm-wiki/wiki/providentia-accuracy/` — per-vuln accuracy pages (Obsidian)
- `llm-wiki/templates/providentia-accuracy.md` — page template
- Accuracy pages are **preserved across engagement archives** (not cleared)
