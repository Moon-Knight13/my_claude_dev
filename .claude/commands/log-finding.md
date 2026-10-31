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

6. Confirm the action:
   ```
   Finding logged: [[note_name]]
   Location: Notes_Mitre_ATTack_Framework/{path}
   Action: [created new note | appended to existing]
   Tags: [tags applied]
   ```

7. If the finding reveals a knowledge gap (technique worked differently
   than documented, or no prior notes existed), flag it:
   ```
   Knowledge gap identified: [description]
   Consider enriching this note after the engagement.
   ```
