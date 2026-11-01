# /log-finding — Log an engagement finding to personal MITRE notes

Create or append a field observation to the operator's Obsidian vault
using the field observation template. This captures novel findings from
engagement work back into the personal knowledge base.

## Arguments

$ARGUMENTS — A description of what was observed, discovered, or validated
during engagement (e.g. "kerberoasting worked on SVC_SQL account using
Rubeus on DC01", "AMSI bypass via reflection method still works on
Server 2022").

## Instructions

1. Parse the finding to extract:
   - **Technique**: What was done (map to MITRE tactic/technique if possible)
   - **Target context**: What platform/OS/service was involved
   - **Outcome**: What happened (success/failure/partial)
   - **Tool**: What tool was used
   - **OPSEC notes**: Any detection or evasion observations

2. Load the tag taxonomy from `config/tag_taxonomy.yaml` to map to correct
   tags and tactic directory.

3. Search existing notes with `obsidian_search_vault` (vault: `my_notes`)
   to check if a note for this technique already exists.

4. **If note exists**: Read it with `obsidian_read_note`, then append the
   finding as a new section using `obsidian_edit_note` (operation: append):
   ```markdown

   ### Field Observation — YYYY-MM-DD
   - **Context**: [target description]
   - **Outcome**: [what happened]
   - **Detection**: [detected or not]
   - **Notes**: [observation details]
   ```

5. **If note does not exist**: Create a new note using
   `obsidian_create_note` following the field observation template at
   `templates/obsidian/field_observation.md`. Place it in the appropriate
   tactic directory under `Notes_Mitre_ATTack_Framework/`.

   The note path should follow the vault convention:
   `Notes_Mitre_ATTack_Framework/{tactic_dir}/{technique_name}/{technique_name}.md`

6. **Write to LLM Wiki** (dual-write: reference layer + operational layer):

   a. **Technique page** (`llm-wiki/wiki/techniques/{technique_slug}.md`):
      Search the wiki techniques dir first. If a page exists, append the
      finding under `## Engagement Usage`. If not, create one using the
      template at `llm-wiki/templates/technique.md`, filling `name`,
      `mitre_tactic`, `tactic`, `reference_note` (wikilink to the MITRE
      note), and adding the finding under `## Engagement Usage`.

   b. **Target page** (`llm-wiki/wiki/targets/{hostname_or_ip}.md`):
      If the finding names a specific host or IP, search wiki targets.
      If a page exists, append under `## Findings`. If not, create one
      using the template at `llm-wiki/templates/target.md`, filling what
      is known (hostname, IP, OS if stated).

   c. **Changelog**: Append a row to `llm-wiki/log.md`:
      `| YYYY-MM-DD | [[page_name]] | created/updated | one-line summary |`

   d. **Dedup check**: Before creating any wiki page, also search
      `Write_Ups/` for the technique or target name to avoid duplicating
      existing narrative notes. If a Write_Up exists, link to it from the
      wiki page rather than duplicating content.

7. Confirm the action:
   ```
   Finding logged: [[note_name]]
   MITRE: Notes_Mitre_ATTack_Framework/{path} — [created | appended]
   Wiki:  llm-wiki/wiki/techniques/{slug} — [created | appended]
   Wiki:  llm-wiki/wiki/targets/{target} — [created | appended | skipped]
   Tags: [tags applied]
   ```

8. If the finding reveals a knowledge gap (technique worked differently
   than documented, or no prior notes existed), flag it:
   ```
   Knowledge gap identified: [description]
   Consider enriching this note after the engagement.
   ```
