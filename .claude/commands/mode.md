---
name: mode
description: "Switch operational mode. Usage: /mode <mode-name> — rewrites CLAUDE.md + .mcp.json from mode templates. Requires session restart."
---

# Mode Switching

Switch the session to a different operational mode. Each mode configures
different MCP servers, OPSEC rules, and documentation pipelines.

## Available Modes

| Mode | Description | Range Required |
|------|-------------|----------------|
| `platform-ops` | Framework self-maintenance (default) | No |
| `red-team` | Offensive ops against authorized targets | Yes |
| `red-dev` | Exploit development, RE, CVE research | Yes (test range) |
| `green-dev` | Range infrastructure build and configure | Yes |
| `purple` | Attack + detection testing with scoring | Yes |

## Procedure

When the operator invokes `/mode <name>`:

### 1. Validate

Check `.claude/modes/<name>/` exists with `CLAUDE.md` and `settings.json`.
If validation fails, report what is missing and refuse the switch.

### 2. Generate .mcp.json

Run `setup-mcp-servers.sh` with the mode name to generate `.mcp.json` with
only the servers that mode needs. Server configs are centralized in the
script's catalog — modes do not define server configs.

```bash
bash scripts/setup-mcp-servers.sh "$MODE_NAME"
```

### 3. Merge Settings

Read `.claude/modes/base/settings.json` (hooks, guards — always active).
Read `.claude/modes/<name>/settings.json` (mode metadata).

Merge: base hooks are ALWAYS preserved. Mode metadata (`_mode`, `_description`)
is added. No MCP servers in settings — those are in `.mcp.json`.

```bash
jq -n \
  --slurpfile base .claude/modes/base/settings.json \
  --slurpfile mode ".claude/modes/$MODE_NAME/settings.json" \
  '$base[0] * $mode[0]' > .claude/settings.json
```

### 4. Merge CLAUDE.md

Read `.claude/modes/base/CLAUDE.md` (workflow contract — always active).
Read `.claude/modes/<name>/CLAUDE.md` (mode-specific instructions).

Concatenate: base CLAUDE.md + blank line + mode CLAUDE.md.
Write to `CLAUDE.md` at repository root.

```bash
cat .claude/modes/base/CLAUDE.md > CLAUDE.md
echo "" >> CLAUDE.md
cat ".claude/modes/$MODE_NAME/CLAUDE.md" >> CLAUDE.md
```

### 5. Write mode state file

Write current mode to `.claude/.active-mode` for statusline and other scripts.

```bash
echo "$MODE_NAME" > .claude/.active-mode
```

### 6. Report and Restart

Tell the operator:
- Which mode was applied
- Which MCP servers are now active (from `setup-mcp-servers.sh` output)
- Any OPSEC rules now in effect
- **They must restart the session** for CLAUDE.md changes to take effect

Do NOT attempt to restart the session programmatically. The operator
restarts manually (exit + re-enter, or `/clear`).

## Safety

- Base hooks MUST survive every mode switch — verify after merge
- If merge produces invalid JSON, refuse and report error
- Never delete `.claude/settings.json` — always overwrite atomically
- Mode switch is idempotent — switching to current mode is a no-op refresh
