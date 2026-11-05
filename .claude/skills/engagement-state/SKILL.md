---
name: engagement-state
description: "Create, update, query, and resume engagement state (YAML). Triggers: 'engagement', 'state', 'resume engagement', 'what targets', 'new engagement', 'add target', 'record technique', 'what creds'."
modes: [red-team, purple]
---

# Engagement State Management

Manage engagement state across sessions. State lives in `engagements/<id>.yaml`
(gitignored). Every red-team, purple, and red-dev session operates against an
engagement file.

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

Record gate results in engagement YAML:
```yaml
preflight:
  spoke_health: passed | failed
  kali_agent: <agent_id> | missing
  degraded_mode: false | router-only
  agent_routing:
    r1: [reachable_subnets]
    r2: [reachable_subnets]
  gate_timestamp: <ISO-8601>
```

### Create Engagement

Trigger: operator says "new engagement", "start engagement", or no engagement
file exists when entering red-team/purple/red-dev mode.

1. Ask operator for engagement ID (short slug, e.g. `dcm27-t10-nov`).
2. Read `.env` for `OPERATOR_CALLSIGN` and `OPERATOR_TEAM`.
3. Query `tuoni_agents_list` for current agent inventory.
4. Write `engagements/<id>.yaml`:

```yaml
engagement_id: <id>
start_date: <YYYY-MM-DD>
operator: <callsign>
team: <team>
mode: <active-mode>
status: active

targets: []
# Targets added ONLY after explicit operator approval (RT-TGT-001).
# Each entry: {host, ip, role, approved_by, approved_at, status}

agents:
  # Populated from tuoni_agents_list. Refreshed each session.
  # Each entry: {agent_id, hostname, ip, os, integrity, listener, first_seen, last_seen}

credentials: []
# REFS ONLY — never plaintext passwords, hashes, or keys.
# Each entry: {ref_id, tuoni_cred_id, type, username, domain, source_host, source_technique, notes}
# ref_id is a local slug for cross-referencing in findings.

findings: []
# Each entry: {id, target, technique_id, technique_name, result, timestamp, notes}
# result: success | partial | failed | blocked

techniques_tried: []
# Per-target technique log. Each: {target, technique_id, technique_name, phase, result, agent_id, timestamp}

next_steps: []
# Operator-curated task list. Each: {priority, target, action, notes}

# Purple mode extension (present only in purple engagements)
# detection_scores: []
# Each: {technique_id, technique_name, target, time_to_detect, alert_fidelity,
#         action_completeness, payload_uniqueness, total, notes}
```

5. Ensure `engagements/` directory exists and is in `.gitignore`.
6. Report: engagement created, agent count, ready for target approval.

### Add Targets

Trigger: operator approves targets ("approve target <host>", "add target",
"these hosts are in scope").

**RT-TGT-001 ENFORCED:** Do NOT add targets without explicit operator approval
in the current message. Discovered hosts are NOT automatically in scope.

1. Confirm operator explicitly named the targets in this message.
2. For each target, query `range_targets` or `range_host` via range-intel for
   ground truth (IP, role, OS, services).
3. Append to `targets` list with `approved_by: operator`, `approved_at: <now>`,
   `status: active`.
4. Report: targets added, total scope count.

### Record Technique Outcome

Trigger: after executing an offensive technique, "record technique",
"log finding", or automatically at end of each kill chain step.

1. Append to `techniques_tried` with target, technique ID (MITRE ATT&CK where
   applicable), phase, result, agent used, timestamp.
2. If result is `success` or `partial`, also append to `findings`.
3. If credentials were obtained, add credential REF (see below).
4. Write updated YAML.

### Add Credential Reference

Trigger: credentials harvested during engagement.

**REFS ONLY — never store plaintext passwords, hashes, tickets, or keys in
the engagement YAML or Obsidian notes.**

1. Store actual credential in Tuoni credential store via `tuoni_credential_add`.
2. Record in engagement YAML `credentials` list:
   - `tuoni_cred_id`: ID from Tuoni store
   - `type`: password | hash | ticket | key | token
   - `username`, `domain`: identity info (these are not secrets)
   - `source_host`, `source_technique`: provenance
   - `notes`: brief context
3. Credential refs can be cross-referenced by `ref_id` in findings and
   technique logs.

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
"engagement status", "scope check".

Read engagement YAML and answer the query:
- **Targets**: list with status, IP, role
- **Credentials**: list refs with username, type, source (never actual creds)
- **Techniques on host**: filter `techniques_tried` by target
- **Findings**: filter by result=success/partial
- **Next steps**: current task list
- **Detection scores** (purple): per-technique and average
- **Status summary**: target count, agent count, finding count, cred ref count

### Cross-Session Resume

Trigger: session start in red-team/purple/red-dev mode, operator says "resume",
or skill detects existing engagement file.

1. Find most recent engagement YAML in `engagements/` (by `start_date` or
   file modification time). If multiple, ask operator which to resume.
2. Read engagement YAML.
3. Refresh agent list from `tuoni_agents_list` — update `agents` section,
   flag agents that disappeared since last session.
4. Load prior Obsidian context via `obsidian_search_vault` for `#engagement/<id>`
   — read existing wiki pages to understand prior session state.
5. Summarize state to operator:
   - Engagement ID, start date, mode
   - Active targets (count + list)
   - Live agents (count, any lost since last session)
   - Credential refs (count)
   - Last technique tried + result
   - Next steps from previous session
5. Ask operator: "Resume this engagement? Any scope changes?"

### Archive Engagement (Clean Slate)

Trigger: operator says "archive engagement", "clean slate", "new engagement"
when an active engagement exists, or "close engagement".

Purpose: range changes between engagements (new enclaves, IP reassignment,
vulns deployed/removed). Stale engagement data misleads. Technique KNOWLEDGE
persists; target-specific STATE archives.

1. Set engagement YAML `status: archived`, add `archived_at: <ISO-8601>`
2. Move `engagements/<id>.yaml` to `engagements/archive/<id>.yaml`
   (create `archive/` if needed)
3. Tag Obsidian target pages with `#archived/<id>` via `obsidian_add_tags`:
   - `llm-wiki/wiki/targets/<hostname>.md` — add `#archived`
   - These pages remain searchable but recon skill treats them as historical
4. **PRESERVE** (do NOT archive):
   - `llm-wiki/wiki/techniques/*.md` — technique knowledge persists across
     engagements. This is the learning.
   - `llm-wiki/wiki/providentia-accuracy/*.md` — vuln accuracy data persists
   - `llm-wiki/log.md` — append-only, never truncated
5. Generate engagement summary in Obsidian:
   - Create `llm-wiki/wiki/engagements/<id>/Summary.md`
   - Include: targets, techniques_tried with results, findings, metrics
   - This is the permanent record
6. Report: "Engagement <id> archived. Technique pages preserved. Ready for
   new engagement."

After archive, "new engagement" creates fresh state from Providentia ground
truth. Pre-engagement-cache runs fresh. No stale target data carried forward.

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
DCM27 redteam-test2 documentation.

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
| `#mitre/<T-id>` | Every technique note with MITRE mapping |
| `#result/<outcome>` | success, failed, partial, blocked |

Tags enable cross-engagement knowledge retrieval. A search for
`#mitre/T1003 #result/success` finds all successful credential dumps
across all engagements.

## File Locations

- `engagements/<id>.yaml` — engagement state (gitignored)
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
