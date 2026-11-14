---
name: engagement-state
description: "Create, update, query, resume, and archive engagement state. Primary state in Obsidian llm-wiki. Thin YAML gate file for existence check only. Triggers: 'engagement', 'state', 'resume engagement', 'what targets', 'new engagement', 'add target', 'record technique', 'what creds', 'archive engagement', 'clean slate', 'untested creds', 'creds from host', 'credential inventory', 'spray candidates', 'mark cred tested', 'reclassify target', 'mark target as', 'show confirmed targets', 'show unreachable targets', 'target status'."
modes: [red-team, purple]
---

# Engagement State Management

Manage engagement state across sessions. **Primary state lives in Obsidian**
(`llm-wiki/wiki/engagements/<id>.md`). A thin YAML gate file
(`engagements/<id>.yaml`) exists for filesystem existence check only — it
contains engagement ID, mode, team, scope exclusions, and a pointer to the
Obsidian page. ALL detail (targets, findings, creds, techniques, next steps)
lives in Obsidian.

**Why Obsidian, not YAML:** Single source of truth. Threads already read/write
Obsidian for target pages. No split brain between YAML and Obsidian. Obsidian
pages are structured markdown — queryable, taggable, cross-linkable.

## Target Classification

Targets progress through classification states as engagement advances.
Classification drives which kill-chain skills apply and what actions are valid.

### State Machine

```
candidate ──┬── confirmed ──┬── compromised
             │                ├── hardened
             │                └── patched
             ├── unreachable
             └── different-than-expected ──┬── confirmed (re-recon)
                                            └── unreachable
```

| Classification | Set by | Meaning |
|----------------|--------|---------|
| `candidate` | `pre-engagement-cache`, `add target` | Providentia/operator says host exists. Not yet verified. |
| `confirmed` | `recon` Phase 0 | Reachable, services match Providentia (or blind scan populated services). |
| `unreachable` | `recon` Phase 0 | No route, no response, or all ports filtered after scan. |
| `different-than-expected` | `recon` Phase 0 | Reachable but services diverge significantly from Providentia data. |
| `compromised` | `initial-access`, `lateral-move` | Agent established, persistence deployed. |
| `hardened` | `initial-access` | All vectors exhausted, target resists exploitation. |
| `patched` | `initial-access` | Specific CVE/vuln confirmed patched during attempt. |

### Classification Rules

- Every target starts as `candidate`. No target enters scope as `confirmed`.
- `confirmed` requires live scan evidence (nmap, service response).
- `unreachable` can revert to `confirmed` if later pivot opens route.
- `different-than-expected` triggers operator notification — Providentia may need
  correction, or host was rebuilt. Operator decides whether to proceed.
- `compromised` requires active agent + persistence (per persist-swarm).
- `hardened` requires documented exhaustion of prioritized vectors (minimum 3
  technique attempts logged in `## Techniques Tried`).
- `patched` records specific CVE/vuln and evidence of patch (version string,
  error response, etc.).

### Where Classification Lives

- **Obsidian engagement page `## Targets`**: classification column in target table.
- **Obsidian target page**: `classification` field in frontmatter + full
  `## Classification History` section with timestamped entries.
- **Engagement YAML**: `classification` field per target (lean reference only).

### Classification History Format (Obsidian target page)

Each reclassification appends to `## Classification History`:

```markdown
## Classification History

| Timestamp | From | To | Reason | Evidence | Actor |
|-----------|------|----|--------|----------|-------|
| 2026-11-14T10:30:00Z | candidate | confirmed | Phase 0 sweep: 5 services match Providentia | nmap scan llm-wiki/raw/network-sweep-2026-11-14.md | recon |
| 2026-11-14T14:15:00Z | confirmed | compromised | Initial access via CVE-2024-XXXX | agent ID a1b2c3, persist-swarm deployed | initial-access |
```

Columns: ISO-8601 timestamp, previous classification, new classification,
human-readable reason, evidence pointer (raw dump path, agent ID, scan
reference), skill/phase that triggered reclassification.

## Operations

### Mandatory Auto-Creation Gate

This skill MUST be invoked automatically when:
- Session enters red-team, purple, or red-dev mode
- Operator names a target scope and no engagement YAML exists
- Any kill-chain skill (recon, initial-access, discovery, cred-harvest, persist-swarm, lateral-move) is invoked and no engagement YAML exists

If no engagement YAML exists, CREATE ONE before allowing any other skill to proceed. Prompt operator for engagement ID if not obvious from context.

After creation, auto-invoke `pre-engagement-cache` skill to warm Providentia data per-host (not bulk) and load reference MCP tool schemas via ToolSearch.

### Mandatory Pre-Engagement Gates (red-team / purple)

Before ANY kill-chain skill (recon, initial-access, discovery, etc.) runs,
verify these gates IN ORDER. Gate failures block engagement start — they are
not warnings.

**Gate 1: spoke-health** — invoke `spoke-health` skill.
- All SSH hops must reach Kali spoke
- tuoni-mcp must respond
- If Kali spoke unreachable: BLOCK. Operator must deploy Kali or explicitly
  acknowledge degraded (router-only) mode in engagement YAML:
  `degraded_mode: router-only`

**Gate 2: kali-bootstrap** (red-team only) — verify Kali agent exists.
- Query `tuoni_agents_list` for a Kali-hosted agent
- If no Kali agent AND `degraded_mode` not set: BLOCK. Report:
  "No Kali spoke agent. Run kali-bootstrap or set degraded_mode: router-only"
- If `degraded_mode: router-only`: warn and continue. Skills must use their
  degraded-mode sections (router agents only, limited tooling).

**Gate 3: agent routing verification** — for each router agent hostname:
- Run `ip route` or equivalent via a single agent per host
- Verify at least one agent can reach each target subnet
- Report unreachable targets. If ALL targets unreachable from ALL agents: BLOCK.

Record gate results in Obsidian engagement page under `## Preflight` section.
Include: spoke_health status, kali_agent ID, degraded_mode flag, agent routing
table, gate timestamp.

### Create Engagement

Trigger: operator says "new engagement", "start engagement", or no engagement
exists when entering red-team/purple/red-dev mode.

1. Ask operator for engagement ID (short slug, e.g. `dcm27-t10-nov2026`).
2. Read `.env` for `OPERATOR_CALLSIGN` and `OPERATOR_TEAM`.
3. Query `tuoni_agents_list` for current agent inventory.
4. Write thin YAML gate file `engagements/<id>.yaml`:

```yaml
# GATE FILE ONLY — all detail lives in Obsidian
engagement_id: <id>
mode: <active-mode>
team: <team>
environment: <env>
status: active
wiki_page: llm-wiki/wiki/engagements/<id>.md
exclusions:
  - "GT accounts per RT-SCOPE-001"
```

5. Create Obsidian engagement page via obsidian-mcp (`obsidian_create_note`):
   Path: `llm-wiki/wiki/engagements/<id>.md`
   Content sections:
   - **## Overview** — engagement ID, start date, operator, team, mode, scope
   - **## Targets** — added after RT-TGT-001 approval (host, IP, OS, classification, phase, wiki page link)
   - **## Reachability** — populated by Phase 0 sweep
   - **## Agents** — self-agent ID, target agents as they're deployed
   - **## Credentials** — REFS ONLY, auto-populated by cred-harvest. Table columns:
     `| Ref ID | Username | Domain | Type | Source Host | Harvest Method | Timestamp | Status |`
     Status values: `untested`, `tested:success`, `tested:failed`, `tested:expired`
   - **## Findings** — technique outcomes (ID, target, result, timestamp)
   - **## Techniques Tried** — per-target log
   - **## Next Steps** — operator-curated task list
   - **## Preflight** — gate results (spoke-health, kali-bootstrap, agent routing)
   Tags: `#engagement/<id>`, `#mode/<mode>`, `#team/<team>`

6. Ensure `engagements/` directory exists and is in `.gitignore`.
7. Report: engagement created, agent count, ready for target approval.

### Add Targets

Trigger: operator approves targets ("approve target <host>", "add target",
"these hosts are in scope").

**RT-TGT-001 ENFORCED:** Do NOT add targets without explicit operator approval
in the current message. Discovered hosts are NOT automatically in scope.

1. Confirm operator explicitly named the targets in this message.
2. For each target, query `range_targets` or `range_host` via range-intel for
   ground truth (IP, role, OS, services).
3. Set initial classification to `candidate` for each target.
4. Update Obsidian engagement page `## Targets` table with new entries including
   classification column:
   ```markdown
   | Host | IP | OS | Classification | Phase | Wiki |
   |------|----|----|----------------|-------|------|
   | <hostname> | <ip> | <os> | candidate | pending | [[targets/<hostname>]] |
   ```
5. Create Obsidian target page (`llm-wiki/wiki/targets/<hostname>.md`) if not exists.
   Include `classification: candidate` in frontmatter and initialize empty
   `## Classification History` table.
6. Update engagement YAML target entry:
   ```yaml
   targets:
     - hostname: <target>
       classification: candidate
       phase: pending
       wiki_page: llm-wiki/wiki/targets/<hostname>.md
   ```
7. Report: targets added as candidates, total scope count.
   Remind operator: targets need recon Phase 0 before they become `confirmed`.

### Reclassify Target

Trigger: automatic after recon Phase 0 sweep, after initial-access attempt,
after lateral-move landing, or operator says "reclassify", "mark target as",
"target is unreachable", "target compromised".

**Auto-reclassification points** (skills invoke this automatically):
- **recon Phase 0**: `candidate` → `confirmed` | `unreachable` | `different-than-expected`
- **initial-access**: `confirmed` → `compromised` | `hardened` | `patched`
- **lateral-move**: `confirmed` → `compromised` (on successful pivot landing)
- **Operator override**: any transition at any time with stated reason

**Procedure:**

1. Validate transition is legal per state machine (see Target Classification).
   Illegal transitions (e.g., `candidate` → `compromised` skipping `confirmed`)
   require operator override with explicit reason.
2. Read current classification from Obsidian target page frontmatter.
3. Update Obsidian target page:
   a. Set `classification: <new>` in frontmatter.
   b. Append row to `## Classification History` table:
      `| <ISO-8601> | <old> | <new> | <reason> | <evidence> | <actor-skill> |`
4. Update Obsidian engagement page `## Targets` table: set classification column.
5. Update engagement YAML target entry: `classification: <new>`.
6. Apply Obsidian tag: `#classification/<new>` to target page.
7. Report reclassification to operator.

**Post-reclassification actions:**

| New Classification | Action |
|--------------------|--------|
| `confirmed` | Target eligible for Phase 1+ recon and initial-access. |
| `unreachable` | Log reason. Skip in attack planning. Re-check after pivot. |
| `different-than-expected` | Alert operator. Log Providentia discrepancy. Await guidance. |
| `compromised` | Trigger persist-swarm if not already deployed. Update agent list. |
| `hardened` | Log exhausted vectors. Deprioritize unless new intel arrives. |
| `patched` | Log specific patch evidence. Flag for Providentia accuracy feedback. |

**Bulk reclassification** (after Phase 0 sweep): reclassify all scanned targets
in one pass. Group by new classification and report summary:
```
Reclassification summary:
  confirmed: 5 (host1, host2, ...)
  unreachable: 2 (host3, host4)
  different-than-expected: 1 (host5 — expected SSH+HTTP, found only RDP)
```

### Record Technique Outcome

Trigger: after executing an offensive technique, "record technique",
"log finding", or automatically at end of each kill chain step.

1. Update Obsidian engagement page `## Techniques Tried` with: target,
   technique ID (MITRE ATT&CK), phase, result, agent used, timestamp.
2. If result is `success` or `partial`, also update `## Findings`.
3. If credentials obtained, add credential REF to `## Credentials` (see below).
4. Update target page (`llm-wiki/wiki/targets/<hostname>.md`) with technique outcome.
5. Invoke `/log-finding` for Obsidian raw dump + log entry.

### Query Technique Scores (Orchestrator Grounding)

Trigger: before selecting attack vectors, "rank techniques", "what works",
"prioritize attack", or during initial-access/lateral-move planning.

Invoke the `technique-scoring` skill or run directly:

```bash
python3 scripts/technique-scoring.py --format json --top 10
python3 scripts/technique-scoring.py --query T1003.001 --format json
python3 scripts/technique-scoring.py --gaps --providentia-cache llm-wiki/raw/providentia/vulns.yaml
```

Scores are computed from all engagement YAMLs (active + archived). The
orchestrator should prefer techniques with high empirical success rates on
this range over theoretical Providentia/EPSS scores. See
`config/technique-scoring.yaml` for weights and thresholds.

**note-search enrichment:** After scoring, invoke `note-search` for each top-N
technique (by MITRE ID and name). Operator notes add qualitative context that
empirical scores miss:
- Prior success notes reveal working commands and exact parameters
- Prior failure notes reveal environmental blockers (e.g. "fail2ban on SSH",
  "AppLocker blocks LOLBins on this host type")
- OPSEC notes from write-ups flag detection risk not captured in scoring

Present note-search results alongside technique scores. Operator experience
can promote a lower-scored technique (operator has proven PoC) or demote a
higher-scored one (operator notes show environmental blocker on this target type).

### Update Credential Inventory (Auto-Called by cred-harvest)

Trigger: **automatic** — called by cred-harvest Phase 4 step 4, Phase 5 spray
success, and lateral-move on credential validation. Also callable manually:
"add cred", "record credential".

**REFS ONLY — never store plaintext passwords, hashes, tickets, or keys in
the engagement YAML or Obsidian notes.**

#### Input fields

| Field | Required | Description |
|-------|----------|-------------|
| `tuoni_cred_id` | yes | ID from Tuoni credential store |
| `username` | yes | Account name (not a secret) |
| `domain` | no | Domain or realm (not a secret) |
| `type` | yes | password, NTLM, NTLMv2, NetNTLMv2, Kerberos, key, token, certificate |
| `source_host` | yes | Host where credential was harvested |
| `harvest_method` | yes | MITRE technique ID (e.g. T1003.001) or plugin name |
| `timestamp` | yes | ISO-8601 harvest time |
| `status` | yes | `untested` (default on harvest) or `tested` |

#### Procedure

1. Store actual credential in Tuoni credential store via `tuoni_credential_add`
   (if not already stored by cred-harvest — check `tuoni_cred_id` exists).
2. **Dedup check**: Read Obsidian engagement page `## Credentials` section.
   Search for existing entry matching `(username, domain, type, source_host)`.
   - **Match found**: update existing entry's `tuoni_cred_id` if changed,
     append `harvest_method` if new method, update `timestamp` to latest.
     Do NOT create duplicate row.
   - **No match**: append new entry.
3. Record entry in Obsidian engagement page `## Credentials` section using
   this table row format:
   ```
   | <tuoni_cred_id> | <username> | <domain> | <type> | <source_host> | <harvest_method> | <timestamp> | <status> |
   ```
4. Update target page (`llm-wiki/wiki/targets/<source_host>.md`) with cred ref
   under `## Credentials` section.
5. Return confirmation: `new` (entry created) or `existing` (deduped).
6. **NEVER store plaintext passwords, hashes, tickets, or keys in Obsidian.**

### Mark Credential Tested

Trigger: **automatic** — called by cred-harvest Phase 5 (spray result),
lateral-move (credential validated on new host), or manually: "mark cred tested".

1. Read Obsidian engagement page `## Credentials` section.
2. Find entry by `tuoni_cred_id` or `(username, domain)`.
3. Update `status` column:
   - `tested:success` — credential validated on at least one target
   - `tested:failed` — credential attempted but access denied
   - `tested:expired` — credential no longer valid (password changed, token expired)
4. Optionally append tested-against host to a `tested_on` note if provided.
5. Update target page if tested on a new host.

### Query Credential Inventory

Trigger: "list all creds", "what creds", "untested creds", "creds from host X",
"creds for domain Y", "credential inventory", "spray candidates".

Read Obsidian engagement page `## Credentials` section and filter:

| Query | Filter |
|-------|--------|
| "list all creds" / "credential inventory" | Return full table |
| "untested creds" / "spray candidates" | Filter `status = untested` |
| "tested creds" | Filter `status` starts with `tested` |
| "creds from host X" | Filter `source_host = X` |
| "creds for domain Y" | Filter `domain = Y` |
| "creds of type Z" | Filter `type = Z` (e.g. NTLM, key, token) |
| "creds for user U" | Filter `username = U` |

Compound queries supported: "untested NTLM creds from host X" applies all
matching filters.

Report format:
```
## Credential Inventory — <engagement_id>
Total: N | Untested: N | Tested (success): N | Tested (failed): N

| Ref ID | Username | Domain | Type | Source | Method | Harvested | Status |
|--------|----------|--------|------|--------|--------|-----------|--------|
| ...    | ...      | ...    | ...  | ...    | ...    | ...       | ...    |
```

For "spray candidates" queries, also cross-reference against known target hosts
from `## Targets` section — report which untested creds could plausibly work
on which targets based on domain match.

### Record Detection Score (Purple Mode)

Trigger: after detection validation step in purple mode.

1. Append to `detection_scores` (create list if first score):
   - `technique_id`, `technique_name`, `target`
   - `time_to_detect`: 0-3 (0=not detected, 1=>10min, 2=1-10min, 3=<1min)
   - `alert_fidelity`: 0-3 (0=no alert, 1=generic, 2=correct category, 3=exact)
   - `action_completeness`: 0-3 (0=no response, 1=logged, 2=alert+ticket, 3=auto-block)
   - `payload_uniqueness`: 0-3 (0=known sig, 1=modified, 2=custom+detected, 3=custom+missed)
   - `total`: sum of above (0-12)
   - `notes`: detection details
2. Report running average score across all techniques.

### Query Engagement

Trigger: "what targets", "what creds", "what techniques worked on <host>",
"engagement status", "scope check", "show confirmed targets",
"show unreachable targets", "show compromised", "target status".

Read Obsidian engagement page (`obsidian_read_note`) and answer the query:
- **Targets**: read `## Targets` section
- **Targets by classification**: filter `## Targets` table by classification column.
  Supports: "show all confirmed", "show unreachable", "show candidates",
  "show compromised", "show hardened", "show patched", "show different-than-expected".
  Also: "show actionable" = confirmed (not yet compromised/hardened/patched).
  Also: "show stale candidates" = candidate targets with no recon Phase 0 data.
- **Target classification history**: read specific target page `## Classification History`
- **Classification summary**: count per classification state:
  ```
  Target classifications:
    candidate: 2
    confirmed: 4
    unreachable: 1
    compromised: 2
    hardened: 1
  ```
- **Credentials**: use **Query Credential Inventory** (supports filtering by
  status, host, domain, type, username — see that section for full query syntax)
- **Techniques on host**: read `## Techniques Tried`, filter by target
- **Findings**: read `## Findings`, filter by result=success/partial
- **Next steps**: read `## Next Steps`
- **Detection scores** (purple): per-technique and average
- **Status summary**: target count (by classification), agent count, finding count,
  cred ref count, untested cred count
- **Operator notes**: invoke `note-search` for each queried target/technique
  to surface relevant personal notes (MITRE write-ups, prior engagement
  experience, vuln lab results). Present under **Prior Knowledge** in response.

Additionally, search by Obsidian tags for cross-engagement queries:
- `#classification/confirmed` — all confirmed targets across engagements
- `#classification/compromised` — all compromised targets across engagements

When answering technique-specific queries ("what works on <host>",
"what techniques for <service>"), auto-invoke `note-search` with the
technique/service name. Operator notes that show prior success or
failure on similar targets add context beyond engagement YAML data.

### Cross-Session Resume

Trigger: session start in red-team/purple/red-dev mode, operator says "resume",
or skill detects existing engagement file.

1. Find most recent gate YAML in `engagements/` (by file modification time).
   If multiple, ask operator which to resume.
2. Read gate YAML for engagement ID and wiki_page path.
3. Read Obsidian engagement page (`obsidian_read_note` with wiki_page path).
4. Refresh agent list from `tuoni_agents_list` — update `## Agents` section,
   flag agents that disappeared since last session.
5. Load related Obsidian pages via `obsidian_search_vault` for `#engagement/<id>`.
6. Invoke `note-search` for each active target (hostname + IP) to refresh
   operator knowledge context. New notes written since last session surface
   here — operator may have done research or lab work between sessions.
7. Summarize state to operator:
   - Engagement ID, start date, mode
   - Active targets (count + list)
   - Live agents (count, any lost since last session)
   - Credential refs (count)
   - Last technique tried + result
   - Next steps from previous session
   - **New operator notes** since last session (if note-search finds notes
     not already referenced in engagement page)
8. Ask operator: "Resume this engagement? Any scope changes?"

### Archive Engagement

Trigger: operator says "archive engagement", "clean slate", "new engagement"
(when an active engagement already exists), or "start fresh".

Purpose: preserve historical data while resetting active state so next
engagement starts from Providentia ground truth, not stale cached data.

1. Read gate YAML from `engagements/<id>.yaml`.
2. Set `status: archived` and `archived_at: <ISO-8601>` in gate YAML.
3. Create `engagements/archive/` directory if it does not exist.
4. Move `engagements/<id>.yaml` to `engagements/archive/<id>.yaml`.
5. Update Obsidian engagement page: add `archived: true` to frontmatter.
5. Obsidian tag update — for all notes tagged `#engagement/<id>`:
   - Add `#archived` tag via `obsidian_add_tags`.
   - Do NOT delete or modify note content. Technique knowledge persists.
6. Preserved data (NOT touched during archive):
   - `llm-wiki/wiki/techniques/` pages — these are cross-engagement learnings.
   - `llm-wiki/wiki/vulnerabilities/` pages — reusable vulnerability intel.
   - `Notes_Mitre_ATTack_Framework/` pages — MITRE cross-references.
   - Providentia accuracy tracker pages — operator feedback loop.
   - `engagements/archive/<id>.yaml` — technique scoring reads archived
     engagement data to compute cross-engagement success rates. See
     `technique-scoring` skill for orchestrator grounding.
7. Cleared data (scoped to archived engagement only):
   - Active engagement YAML removed from `engagements/` (moved to archive).
   - `llm-wiki/raw/providentia/` and `llm-wiki/raw/gitlab/` cache files
     are stale — warn operator but do NOT auto-delete (operator may want
     to diff old vs new).
8. If operator said "new engagement" or "clean slate", immediately proceed
   to Create Engagement flow after archive completes.
9. Report:
   - Engagement `<id>` archived to `engagements/archive/<id>.yaml`
   - N Obsidian notes tagged `#archived`
   - Technique pages preserved: N
   - Cache files flagged stale: N
   - Ready for new engagement creation

#### Staleness Guard

When resuming or creating a new engagement, check for stale cached data:
1. Read `cache_timestamp` from engagement YAML (or from archived engagement
   if operator is starting fresh after archive).
2. If `cache_timestamp` is older than 24 hours: warn operator.
3. If no `cache_timestamp` exists: warn — cache was never populated.
4. Recommend running `pre-engagement-cache` after new engagement creation
   to refresh from current Providentia ground truth.

#### Listing Archived Engagements

Trigger: "list engagements", "past engagements", "engagement history".

1. List files in `engagements/archive/`.
2. For each, read `engagement_id`, `start_date`, `archived_at`, target count.
3. Report table: ID, dates, target count, status.

### Update Next Steps

Trigger: "next steps", "plan next", "what's next", or end of session.

1. Read current `next_steps` from engagement YAML.
2. Based on conversation context, update the list:
   - Mark completed items
   - Add new items from current session findings
   - Prioritize by kill chain phase and opportunity
3. Write updated YAML.
4. At session end, remind operator of top 3 next steps.

## Documentation Pipeline — ENFORCED GATES

Documentation is NOT optional. Each kill-chain phase transition MUST produce
Obsidian output before the next phase starts.

### Primary method: `/log-finding`

After EACH technique execution (success OR failure), invoke `/log-finding`
with the outcome description. This command auto-writes to correct paths:

- `llm-wiki/wiki/techniques/<technique>.md` — from template `llm-wiki/templates/technique.md`
- `llm-wiki/wiki/targets/<hostname>.md` — from template `llm-wiki/templates/target.md`
- `Notes_Mitre_ATTack_Framework/` — MITRE cross-link
- `llm-wiki/log.md` — changelog row

### Tooling Gap Feedback Loop

When a technique fails with `result: blocked` and reason is a missing tool:

1. Log finding in engagement YAML with `notes: tooling_gap — <tool_name>`
2. Append tool to `llm-wiki/wiki/tools/tools-needed.md` via Obsidian:
   ```
   - <tool_name> | needed for: <technique_slug> | target: <hostname> | date
   ```
3. Update technique wiki page `## Tool Requirements` with specific tool name
4. Next kali-bootstrap run reads `tools-needed.md` and installs discovered tools

This creates a closed feedback loop: engagement discovers gap, wiki records
it, bootstrap installs it, next engagement has the tool.

### Phase Gate Checklist

After EACH technique execution or phase completion, BEFORE moving on:

1. **Update engagement YAML** with technique outcome + finding (if success/partial)
2. **Invoke `/log-finding`** with technique outcome (writes to llm-wiki automatically)
3. **Write raw dump** to `llm-wiki/raw/<host>-<phase>-<date>.md` (immutable intake)
4. **Store credentials** in Tuoni cred store (if any harvested), add ref to YAML
5. **If tooling gap**: append to `llm-wiki/wiki/tools/tools-needed.md` (see above)

If ANY gate item is skipped, the session MUST catch up before proceeding to
the next target or phase. "I'll document later" is NOT acceptable — context
degrades and findings are lost.

### Obsidian Write Points (llm-wiki/ vault paths)

All paths are under `llm-wiki/` in the `my_notes` Obsidian vault.

| Kill-Chain Phase | raw/ Write | wiki/ Write |
|-----------------|------------|-------------|
| Recon | `llm-wiki/raw/<host>-recon-<date>.md` | `llm-wiki/wiki/targets/<host>.md` (create) |
| Initial Access | `llm-wiki/raw/<host>-initial-access-<date>.md` | `llm-wiki/wiki/techniques/<technique>.md` |
| Discovery | `llm-wiki/raw/<host>-discovery-<date>.md` | `llm-wiki/wiki/targets/<host>.md` (update) |
| Cred Harvest | `llm-wiki/raw/<host>-creds-<date>.md` | `llm-wiki/wiki/targets/<host>.md` (refs only) |
| Lateral Move | `llm-wiki/raw/<host>-lateral-<date>.md` | `llm-wiki/wiki/targets/<host>.md` (update) |
| Persist | — | `llm-wiki/wiki/targets/<host>.md` (update persistence) |

### Templates (in `llm-wiki/templates/`)

| Template | When to use |
|----------|-------------|
| `target.md` | New target page: hostname, IP, OS, domain, role, services, findings |
| `technique.md` | New technique page: mitre_id, tactic, platforms, execution steps |
| `credential.md` | Credential ref page: username, domain, type, source (NO plaintext) |
| `ioc.md` | IOC page: type, value, context, associated targets |
| `engagement.md` | Engagement overview: scope, objectives, timeline, findings summary |

### Engagement Wiki Page

On engagement creation, also create `llm-wiki/wiki/engagements/<engagement-id>.md`
using `llm-wiki/templates/engagement.md`. Update `llm-wiki/index.md` to add
engagement to the Exercises list. This is the missing link that caused zero
prior engagement documentation.

### Engagement Close / Session End

When operator closes engagement or session ends:

1. **Generate ATT&CK Navigator layer** (mitre-mcp):
   - Extract all MITRE technique IDs from `techniques_tried` in YAML
   - Call `generate_layer` with technique IDs + color by result (green=success, red=failed, yellow=partial)
   - Write layer JSON to `llm-wiki/raw/<engagement-id>-attack-layer.json`
   - This is powerful reporting automation — shows exact coverage exercised
   - **Fallback if mitre-mcp unavailable**: build manual ATT&CK layer JSON
     (format: `{"name":"<id>","versions":{"attack":"14","navigator":"5.1"},"domain":"enterprise-attack","techniques":[{"techniqueID":"<T-id>","color":"<hex>","score":<1-100>}]}`)
     and write to same path. Operator can import into Navigator manually.

2. **Generate LOLBins report** (lolbins-mcp):
   - Call `export_report` with engagement technique summary
   - Write to `llm-wiki/raw/<engagement-id>-lolbins-report.md`

3. **Plugin utilization audit**:
   - Compare `plugin_inventory` from YAML against actual plugin calls in session
   - Report: plugins available vs plugins used vs plugins that would have helped
   - Record in engagement YAML `plugin_utilization` section

### Catch-Up Procedure

When operator requests review or session is ending:
1. Audit engagement YAML `findings` vs `techniques_tried` — gaps = missing findings
2. For each technique with no corresponding llm-wiki note, invoke `/log-finding` retroactively
3. For each target with no `llm-wiki/wiki/targets/` page, create from template
4. Apply Obsidian tags to all engagement notes (see Tag Strategy below)
5. Report documentation debt to operator

- **llm-wiki/raw/**: immutable intake dumps (scan output, command output).
  Write via `obsidian_create_note` with timestamp prefix. Never modify after
  creation. Frontmatter: `tags: [raw, intake]`
- **llm-wiki/wiki/**: AI-maintained structured pages. One page per target
  (host profile, findings, techniques, cred refs). One page per technique
  used (procedure, targets, results, detection notes). Update via
  `obsidian_edit_note` as findings grow.
- **Dedup check**: Before creating any note, call `obsidian_search_vault` to
  check if page already exists. Update existing pages instead of creating duplicates.
- **Directory creation**: Call `obsidian_create_directory` for engagement dirs
  at engagement start if they don't exist.

### Obsidian Tag Strategy (ENFORCED)

After every note write, apply tags via `obsidian_add_tags`:

| Tag pattern | When to apply |
|-------------|---------------|
| `#engagement/<id>` | Every note created during this engagement |
| `#phase/<phase>` | recon, initial-access, discovery, cred-harvest, persist, lateral |
| `#target/<hostname>` | Every note mentioning a specific target |
| `#classification/<state>` | candidate, confirmed, unreachable, different-than-expected, compromised, hardened, patched — updated on reclassification (replace previous classification tag) |
| `#mitre/<T-id>` | Every technique note with MITRE mapping |
| `#result/<outcome>` | success, failed, partial, blocked |

Tags enable cross-engagement knowledge retrieval. A search for
`#mitre/T1003 #result/success` finds all successful credential dumps
across all engagements.

## File Locations

- `engagements/<id>.yaml` — active engagement state (gitignored)
- `engagements/archive/<id>.yaml` — archived engagement state (gitignored)
- `engagements/` directory — created automatically, added to `.gitignore`
- Obsidian vault `my_notes` — tactical documentation (via obsidian-mcp)
  - `llm-wiki/raw/` — immutable intake dumps
  - `llm-wiki/wiki/targets/` — per-target structured pages
  - `llm-wiki/wiki/techniques/` — per-technique structured pages
  - `llm-wiki/wiki/engagements/` — per-engagement overview pages
  - `llm-wiki/templates/` — page templates (target, technique, credential, ioc, engagement)
  - `llm-wiki/log.md` — append-only changelog
  - `llm-wiki/index.md` — master index (update on new pages)
- Tuoni credential store — actual credentials (via tuoni-mcp)

## Safety

- **RT-TGT-001**: never add targets without explicit operator approval in
  the current message. "I found host X" is NOT approval.
- **RT-SCOPE-001**: GT (green team) accounts permanently out of scope. When
  recording techniques or findings that enumerate users, exclude gt-prefixed
  accounts from the data. Never add gt credentials to the credential store.
- **Credentials**: REFS ONLY in YAML and Obsidian. Actual values in Tuoni
  cred store only.
- **No secrets in engagement YAML**: no passwords, hashes, keys, tokens.
  Only metadata and references.
- **Gitignored**: `engagements/` must be in `.gitignore`. Verify on create.
