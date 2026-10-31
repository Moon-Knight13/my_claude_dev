# /note-search — Search personal notes for technique knowledge

Search the operator's Obsidian vault for relevant technique notes and
prior engagement experience before executing an action. Searches MITRE
technique notes, Write_Ups, and Vuln_Labs. Uses the tag taxonomy to map
operational intent to vault tags and tactic directories.

## Arguments

$ARGUMENTS — The operational context: a tactic name, technique description,
tool name, or free-text query (e.g. "kerberoasting", "lateral movement
with winrm", "privilege escalation linux suid").

## Instructions

1. Load the tag taxonomy from `config/tag_taxonomy.yaml` via Read.

2. Parse the query to identify:
   - Which skill category best matches (recon, initial_access, credential_access, etc.)
   - Specific tool or technique names mentioned
   - Platform context (Windows, Linux, AD)

3. Search the Obsidian vault using `obsidian_search_vault` with vault `my_notes`:
   - First search: the exact query text
   - Second search: each matching vault_tag from the taxonomy
   - Third search: any specific tool/technique name extracted from query

4. For each matching note, read it with `obsidian_read_note` and extract:
   - The frontmatter (tags, tactic, mitre_tactic)
   - The Summary line
   - The Commands table (if present)
   - OPSEC Considerations (if present)

5. Present results as a concise briefing, grouped by source:

   **Prior Knowledge: $QUERY**

   **Technique Notes (MITRE):**
   | Note | Tactic | Tags | Summary |
   |------|--------|------|---------|
   | [[note_name]] | tactic_id | tags | one-line summary |

   **Engagement Experience:**
   | Note | Engagement | Type | Context |
   |------|-----------|------|---------|
   | [[writeup_note]] | DCM27 | exercise | one-line context |

   Notes from Write_Ups/ and Vuln_Labs/ have `engagement` and
   `engagement_type` in frontmatter — use these to identify prior
   experience with the technique in real engagements vs labs.

   **Commands Available:**
   List any command tables found, grouped by note.

   **OPSEC Notes:**
   Any OPSEC considerations from matching notes.

   **Gaps:**
   If no notes match, or if the taxonomy has the category but vault has no
   content, flag it as a knowledge gap — candidate for research note creation
   using `templates/obsidian/research_note.md`.

6. If the query mentions a technique not in the vault, suggest creating a
   research note:
   ```
   No prior knowledge for [technique]. Consider creating a research note
   using templates/obsidian/research_note.md after engagement validation.
   ```
