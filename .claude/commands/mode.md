---
name: mode
description: "Switch operational mode. Usage: /mode <mode-name> — rewrites CLAUDE.md + settings.json from mode templates. Requires session restart."
---

# Mode Switching

Switch the session to a different operational mode. Each mode configures
different MCP servers, permissions, OPSEC rules, and documentation pipelines.

## Available Modes

| Mode | Description | Range Required |
|------|-------------|----------------|
| `platform-ops` | Framework self-maintenance (default) | No |
| `red-team` | Offensive ops against authorized targets | Yes |

Future modes (not yet available): `red-dev`, `green-dev`, `purple`.

## Procedure

When the operator invokes `/mode <name>`:

### 1. Validate

Read the mode template directory at `.claude/modes/<name>/`. Check:
- Directory exists
- `CLAUDE.md` fragment exists and is non-empty
- `settings.json` fragment exists and is valid JSON

If validation fails, report what is missing and refuse the switch.

### 2. Merge Settings

Read `.claude/modes/base/settings.json` (hooks, guards, base MCP servers).
Read `.claude/modes/<name>/settings.json` (mode-specific MCP servers).

Merge:
- Base `hooks` are ALWAYS preserved (guards must stay active in all modes)
- Base `mcpServers` are included (local-ollama always available)
- Mode `mcpServers` are added on top (may override base if same key)
- Base meta fields (`_pii_shield_note`, `_statusline_note`) preserved

Write merged result to `.claude/settings.json`.

### 3. Merge CLAUDE.md

Read `.claude/modes/base/CLAUDE.md` (workflow contract — always active).
Read `.claude/modes/<name>/CLAUDE.md` (mode-specific instructions).

Concatenate: base CLAUDE.md + blank line + mode CLAUDE.md.
Write to `CLAUDE.md` at repository root.

### 4. Report and Restart

Tell the operator:
- Which mode was applied
- Which MCP servers are now active
- Any OPSEC rules now in effect
- **They must restart the session** for CLAUDE.md changes to take effect

Do NOT attempt to restart the session programmatically. The operator
restarts manually (exit + re-enter, or `/clear`).

## Implementation

Execute these steps using Bash (read JSON, merge with jq) and Write tool.
Validate before writing — never write a broken config.

```bash
# Validate mode exists
MODE_DIR=".claude/modes/$MODE_NAME"
if [[ ! -d "$MODE_DIR" ]]; then
  echo "Mode '$MODE_NAME' not found. Available: $(ls .claude/modes/ | grep -v base)"
  exit 1
fi

# Validate files
[[ -s "$MODE_DIR/CLAUDE.md" ]] || { echo "Missing CLAUDE.md in $MODE_DIR"; exit 1; }
jq empty "$MODE_DIR/settings.json" 2>/dev/null || { echo "Invalid settings.json in $MODE_DIR"; exit 1; }
```

### Settings merge (jq)

```bash
jq -n \
  --slurpfile base .claude/modes/base/settings.json \
  --slurpfile mode ".claude/modes/$MODE_NAME/settings.json" '
  $base[0] + {
    mcpServers: (($base[0].mcpServers // {}) + ($mode[0].mcpServers // {})),
    _mode: $mode[0]._mode,
    _description: $mode[0]._description
  }
'
```

### CLAUDE.md merge

```bash
cat .claude/modes/base/CLAUDE.md > CLAUDE.md
echo "" >> CLAUDE.md
cat ".claude/modes/$MODE_NAME/CLAUDE.md" >> CLAUDE.md
```

## Safety

- Base hooks MUST survive every mode switch — verify after merge
- If merge produces invalid JSON, refuse and report error
- Never delete `.claude/settings.json` — always overwrite atomically
- Mode switch is idempotent — switching to current mode is a no-op refresh
