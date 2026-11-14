---
name: note-search
description: "Search operator's Obsidian vault for technique knowledge, prior engagement experience, and operational notes. Used standalone via /note-search or auto-invoked by engagement skills (recon, initial-access, engagement-state) to ground decisions in operator experience."
modes: [red-team, purple, ctf, red-dev]
---

# Note Search — Operator Knowledge Retrieval

Search the operator's Obsidian vault (`my_notes`) for relevant technique notes,
prior engagement experience, and operational wiki state. Queries MITRE technique
notes, Write_Ups, Vuln_Labs, and llm-wiki structured pages.

**Two invocation modes:**
- **Standalone** (`/note-search <query>`): operator-initiated lookup, full briefing output
- **Programmatic** (invoked by engagement skills): structured return for skill chaining

## Arguments

Query: tactic name, technique description, tool name, hostname, IP, MITRE ID,
or free-text (e.g. "kerberoasting", "lateral movement winrm", "10.0.5.20",
"T1003.001").

## Instructions

1. Load tag taxonomy from `config/tag_taxonomy.yaml` via Read.

2. Parse query to identify:
   - Skill category (recon, initial_access, credential_access, etc.)
   - Specific tool or technique names
   - Platform context (Windows, Linux, AD)
   - Hostnames or IPs (for target-scoped queries)
   - MITRE technique IDs (T-number patterns)

3. Search Obsidian vault using `obsidian_search_vault` with vault `my_notes`:
   - **Search 1**: exact query text
   - **Search 2**: matching vault_tags from taxonomy
   - **Search 3**: specific tool/technique name extracted from query
   - **Search 4**: scope `llm-wiki/wiki` for operational wiki pages
     (techniques, targets, creds) with structured engagement data
   - **Search 5** (if hostname/IP in query): scope `llm-wiki/wiki/targets/`
     for target-specific pages with prior engagement data

4. For each matching note, read with `obsidian_read_note` and extract:
   - Frontmatter (tags, tactic, mitre_tactic, engagement, engagement_type)
   - Summary line
   - Commands table (if present)
   - OPSEC Considerations (if present)
   - Prior engagement outcomes (success/failure/partial with context)

5. Present results grouped by source:

   **Prior Knowledge: $QUERY**

   **Technique Notes (MITRE):**
   | Note | Tactic | Tags | Summary |
   |------|--------|------|---------|
   | [[note_name]] | tactic_id | tags | one-line summary |

   **Engagement Experience:**
   | Note | Engagement | Result | Context |
   |------|-----------|--------|---------|
   | [[writeup_note]] | engagement-id | success/fail | one-line context |

   Notes from Write_Ups/ and Vuln_Labs/ have `engagement` and
   `engagement_type` in frontmatter — use these to identify prior
   experience with the technique in real engagements vs labs.

   **Commands Available:**
   List command tables found, grouped by note.

   **Wiki (Operational State):**
   | Page | Type | Key detail |
   |------|------|------------|
   | [[wiki_page]] | technique/target/cred | structured summary |

   Notes from `llm-wiki/wiki/` have structured YAML frontmatter —
   technique pages have `mitre_tactic` and engagement usage; target
   pages have `hostname`, `ip`, `os`; credential pages have `username`,
   `domain`, `type`. Present as actionable intel.

   **OPSEC Notes:**
   Any OPSEC considerations from matching notes.

   **Gaps:**
   If no notes match, flag as knowledge gap — candidate for research note
   creation using `templates/obsidian/research_note.md`.

6. If query mentions technique not in vault, suggest research note:
   ```
   No prior knowledge for [technique]. Consider creating a research note
   using templates/obsidian/research_note.md after engagement validation.
   ```

## Programmatic Invocation (Skill Chaining)

When invoked by another skill (engagement-orchestration, recon, initial-access,
engagement-state), return structured data instead of formatted briefing:

```yaml
query: "<original query>"
matches:
  technique_notes:
    - note: "<path>"
      tactic: "<tactic>"
      summary: "<one-line>"
      commands: [list of command snippets]
      opsec: "<considerations>"
  engagement_experience:
    - note: "<path>"
      engagement: "<id>"
      engagement_type: "exercise|lab|engagement"
      result: "success|failed|partial|blocked"
      context: "<one-line>"
  wiki_state:
    - page: "<path>"
      type: "technique|target|cred"
      detail: "<structured summary>"
  gaps: ["<unfound technique/topic>"]
```

Calling skills use this structured output to:
- **Recon**: prioritize scan targets where operator has prior knowledge
- **Research**: weight attack vectors by operator's success history
- **Initial-access**: prefer techniques operator has executed before
- **Engagement-state**: surface notes alongside engagement queries
- **Technique-scoring**: augment empirical scores with operator experience

## Integration Points

Other skills that auto-invoke note-search:

| Skill | When | Query |
|-------|------|-------|
| engagement-orchestration | Phase 1 recon | Each target hostname/IP |
| engagement-orchestration | Phase 2 research | Each service:version + technique |
| engagement-orchestration | Phase 2 exploit | Ranked vectors before execution |
| engagement-orchestration | Phase 3 lateral | Lateral technique + target |
| engagement-state | Query engagement | Targets and techniques in scope |
| engagement-state | Resume engagement | All active targets |
| engagement-state | Technique scoring | Techniques being ranked |
| recon | Target research | Hostname, IP, service names |
| initial-access | Vector selection | Technique names + MITRE IDs |
