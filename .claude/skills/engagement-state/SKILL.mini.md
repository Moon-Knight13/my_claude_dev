<!-- Mini variant for subagent dispatch. Full version: SKILL.md -->
---
name: engagement-state
description: "Create, update, query, resume, and archive engagement state. Primary state in Obsidian llm-wiki. Thin YAML gate file for existence check only. Triggers: 'engagement', 'state', 'resume engagement', 'what targets', 'new engagement', 'add target', 'record technique', 'what creds', 'archive engagement', 'clean slate', 'untested creds', 'creds from host', 'credential inventory', 'spray candidates', 'mark cred tested', 'reclassify target', 'mark target as', 'show confirmed targets', 'show unreachable targets', 'target status'."
modes: [red-team, purple]
---

# Engagement State — Mini

Primary state: Obsidian (`llm-wiki/wiki/engagements/<id>.md`). Thin YAML gate file (`engagements/<id>.yaml`) for existence check only — ID, mode, team, exclusions, wiki pointer. ALL detail in Obsidian.

## Target Classification State Machine

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
| `candidate` | pre-engagement-cache, add target | Exists but unverified |
| `confirmed` | recon Phase 0 | Reachable, services match |
| `unreachable` | recon Phase 0 | No route/response |
| `different-than-expected` | recon Phase 0 | Reachable but services diverge |
| `compromised` | initial-access, lateral-move | Agent + persistence |
| `hardened` | initial-access | All vectors exhausted (min 3 logged) |
| `patched` | initial-access | Specific CVE confirmed patched |

## Mandatory Auto-Creation Gate

Invoke automatically when:
- Session enters red-team/purple/red-dev mode
- Operator names scope and no engagement YAML exists
- Any kill-chain skill invoked without engagement YAML

CREATE engagement before allowing other skills to proceed.

## Pre-Engagement Gates (BLOCKING)

1. **spoke-health** — all SSH hops reach Kali, tuoni-mcp responds. Fail = BLOCK.
2. **kali-bootstrap** (red-team) — `tuoni_agents_list` for Kali agent. No agent + no `degraded_mode` = BLOCK.
3. **agent routing** — `ip route` per agent, verify target subnet reach. All unreachable = BLOCK.

Record results in Obsidian `## Preflight`.

## Create Engagement

1. Ask operator for engagement ID (slug, e.g. `ex01-t10-nov2026`)
2. Read `.env` for `OPERATOR_CALLSIGN`, `OPERATOR_TEAM`
3. `tuoni_agents_list` for agent inventory
4. Write gate YAML `engagements/<id>.yaml`: engagement_id, mode, type (black-box optional), team, environment, status: active, wiki_page pointer, exclusions
5. `obsidian_create_note` at `llm-wiki/wiki/engagements/<id>.md` — sections: Overview, Targets, Reachability, Agents, Credentials, Findings, Techniques Tried, Next Steps, Preflight. Tags: `#engagement/<id>`, `#mode/<mode>`, `#team/<team>`
6. Verify `engagements/` in `.gitignore`
7. Invoke `pre-engagement-cache` (skip if `type: black-box`)

## Add Targets

**RT-TGT-001 ENFORCED:** explicit operator approval required in current message.

1. Confirm operator named targets explicitly
2. `range_targets` or `range_host` for ground truth
3. Set classification: `candidate`
4. Update Obsidian engagement `## Targets` table: `| Host | IP | OS | Classification | Phase | Wiki |`
5. Create target page `llm-wiki/wiki/targets/<hostname>.md` with `classification: candidate` frontmatter + empty `## Classification History`
6. Update engagement YAML target entry
7. Report: targets added as candidates, remind recon Phase 0 needed

## Reclassify Target

Auto-reclassification points:
- **recon Phase 0**: candidate → confirmed | unreachable | different-than-expected
- **initial-access**: confirmed → compromised | hardened | patched
- **lateral-move**: confirmed → compromised
- **Operator override**: any transition with reason

Procedure:
1. Validate transition per state machine (illegal = operator override required)
2. Update Obsidian target page frontmatter + append `## Classification History` row: `| <ISO-8601> | <old> | <new> | <reason> | <evidence> | <actor> |`
3. Update engagement page `## Targets` table
4. Update engagement YAML
5. Apply tag `#classification/<new>`

Post-reclassification: confirmed = eligible for attack; unreachable = skip, re-check after pivot; different-than-expected = alert operator + `providentia-tracker`; compromised = persist-swarm if not deployed; hardened/patched = deprioritize + log.

## Record Technique Outcome

1. Update Obsidian engagement `## Techniques Tried`: target, MITRE ID, phase, result, agent, timestamp
2. Success/partial → also `## Findings`
3. Credentials obtained → add ref to `## Credentials`
4. Update target page
5. Invoke `/log-finding`

## Update Credential Inventory (auto-called by cred-harvest)

**REFS ONLY — never plaintext in YAML or Obsidian.**

Fields: tuoni_cred_id, username, domain, type (password/NTLM/NTLMv2/Kerberos/key/token/certificate), source_host, harvest_method (MITRE ID or plugin), timestamp, status (untested|tested:success|tested:failed|tested:expired).

1. Store in Tuoni via `tuoni_credential_add` (if not already)
2. Dedup: search `## Credentials` for (username, domain, type, source_host) — update existing, don't duplicate
3. Append/update Obsidian engagement `## Credentials` table row
4. Update target page `## Credentials`
5. Return: `new` or `existing`

## Mark Credential Tested

1. Find entry by tuoni_cred_id or (username, domain)
2. Update status: tested:success | tested:failed | tested:expired
3. Update target page if tested on new host

## Query Credential Inventory

Filters: all | untested/spray candidates | tested | by host | by domain | by type | by user. Compound queries supported.

## Query Engagement

Read Obsidian engagement page and answer: targets (by classification), classification history, credential inventory, techniques on host, findings, next steps, detection scores (purple), status summary. Auto-invoke `note-search` for technique/target context.

Cross-engagement: search by tags `#classification/<state>`, `#mitre/<T-id> #result/<outcome>`.

## Cross-Session Resume

1. Find most recent `engagements/*.yaml` (ask if multiple)
2. Read gate YAML for ID + wiki_page
3. `obsidian_read_note` with wiki_page
4. `tuoni_agents_list` — compare against `## Agents`, flag lost agents
5. `obsidian_search_vault` for `#engagement/<id>`
6. `note-search` per active target
7. Present summary: ID, targets by classification, agents, creds, last technique, next steps, new notes
8. Ask: "Resume? Scope changes?"

## Archive Engagement

1. Set `status: archived`, `archived_at: <ISO-8601>` in YAML
2. Move to `engagements/archive/<id>.yaml`
3. Add `archived: true` to Obsidian frontmatter
4. Add `#archived` tag to all engagement notes (do NOT delete content)
5. Preserved: techniques/, vulnerabilities/, MITRE notes, accuracy tracker, archived YAML
6. Warn about stale cache files in `llm-wiki/raw/providentia/` and `llm-wiki/raw/gitlab/`
7. If "new engagement" / "clean slate": proceed to Create flow

## Documentation Pipeline — ENFORCED

After EACH technique (success OR failure): `/log-finding` → raw dump to `llm-wiki/raw/` → update wiki pages → store creds in Tuoni → log tooling gaps.

Obsidian write paths: raw/ (immutable dumps), wiki/targets/ (per-host), wiki/techniques/ (per-technique), wiki/engagements/ (overview). Templates in `llm-wiki/templates/`.

Tag strategy (ENFORCED): `#engagement/<id>`, `#phase/<phase>`, `#target/<hostname>`, `#classification/<state>`, `#mitre/<T-id>`, `#result/<outcome>`.

## Safety

- **RT-TGT-001**: never add targets without explicit operator approval
- **RT-SCOPE-001**: GT accounts permanently out of scope — exclude from all output
- **Credentials**: REFS ONLY in YAML and Obsidian. Values in Tuoni only.
- **Gitignored**: `engagements/` must be in `.gitignore`

## File Locations

- `engagements/<id>.yaml` / `engagements/archive/<id>.yaml` — gate files (gitignored)
- Obsidian `my_notes`: `llm-wiki/raw/`, `llm-wiki/wiki/targets/`, `llm-wiki/wiki/techniques/`, `llm-wiki/wiki/engagements/`, `llm-wiki/templates/`, `llm-wiki/log.md`, `llm-wiki/index.md`
- Tuoni credential store via tuoni-mcp
