---
name: ask
description: "Universal router skill for skill discovery. Describe your intent and get ranked skill recommendations with mode context. Use when unsure which skill to invoke, when exploring available capabilities, or when asked 'what skill for X'. Triggers: 'ask', 'which skill', 'what skill', 'help me find', 'what can I do', 'skill for', 'how do I'."
---

# Universal Skill Router

Match operator intent to the best available skill(s). Recommend only — never
auto-invoke.

## Procedure

### Step 1: Discover available skills

Run the discovery script to index all skills with their metadata:

```bash
bash "$CLAUDE_PROJECT_DIR/.claude/skills/ask/discover.sh"
```

This outputs one line per skill:
```
<name> | <modes> | <description>
```

Skills with no `modes:` field are available in all modes.

### Step 2: Detect current mode

Check if a mode is active:

```bash
if [ -f "$CLAUDE_PROJECT_DIR/.current-mode" ]; then
  cat "$CLAUDE_PROJECT_DIR/.current-mode"
else
  echo "base"
fi
```

### Step 3: Match intent to skills

Given the operator's described intent:

1. Compare intent against each skill's `description:` field
2. Rank by relevance — weight keyword overlap and semantic fit
3. Flag mode compatibility:
   - **Available** — skill has no mode restriction, or current mode is in its `modes:` list
   - **Requires mode switch** — skill needs a mode not currently active; name the required mode(s)

### Step 4: Report recommendations

Format output as a ranked list:

```
## Skill Recommendations

1. **skill-name** — one-line what it does
   Mode: available | requires [mode-name]
   Why: brief rationale for this match

2. **skill-name** — one-line what it does
   Mode: available | requires [mode-name]
   Why: brief rationale for this match
```

Rules:
- Maximum 5 recommendations per query
- If no skills match, say so and suggest refining the intent
- Never auto-invoke a skill — operator chooses
- Include skills from all families: engagement, platform-ops, OPSEC guards, infrastructure
- If operator intent maps to a built-in superpowers skill (brainstorming, debugging, etc.), mention it but note it auto-triggers via `using-superpowers` and does not need manual invocation
