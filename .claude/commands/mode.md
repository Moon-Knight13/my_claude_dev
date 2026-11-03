---
name: mode
description: "Switch or query operational mode. Usage: /mode <name> to switch, /mode list to see modes. Mode rules inject via hook on next prompt."
---

# Mode Switching

Switch the session to a different operational mode. Each mode configures
different OPSEC rules, documentation pipelines, and MCP server guidance.

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

### If `list` or no argument

Show all available modes with descriptions. Read each
`.claude/modes/<name>/settings.json` for `_description`.
Show which mode is currently active from `.claude/.active-mode`.

### If a mode name

#### 1. Validate

Check `.claude/modes/<name>/` exists with `system-prompt.md` and `settings.json`.
If validation fails, report what is missing and refuse the switch.

#### 2. Write active mode

```bash
echo "$MODE_NAME" > .claude/.active-mode
```

The `mode-inject.sh` hook reads this file on every prompt and injects the
mode's `system-prompt.md` as `additionalContext`. Rules take effect on the
**next prompt** — no restart needed.

#### 3. Report

Tell the operator:
- Which mode is now active
- Key OPSEC rules now in effect (summarize from system-prompt.md)
- Which MCP servers the mode recommends (from system-prompt.md)
- **Note about MCP servers**: all MCPs are loaded at startup. The mode's
  system prompt tells Claude which ones to use. For hard MCP isolation
  (only load specific servers), use `scripts/start-mode.sh` instead.

#### 4. Immediate context

Read `.claude/modes/<name>/system-prompt.md` and apply its rules starting
from this response. Do not wait for the hook — the hook ensures persistence
across future prompts, but you should follow mode rules immediately.

## How It Works

Two mechanisms, complementary:

### Hook-based (conversational, recommended)
- Operator says `/mode red-dev` or just "red-dev mode"
- Skill writes `.claude/.active-mode`
- `mode-inject.sh` hook injects rules as `additionalContext` on every prompt
- All MCPs already loaded — mode rules govern which Claude uses
- **No restart needed** for rule changes
- MCP availability is soft (all loaded, guidance-enforced)

### Script-based (hard isolation, parallel sessions)
- Operator runs `scripts/start-mode.sh red-dev` before starting Claude
- CLI flags set system prompt, settings, and MCP config per-session
- Only mode's MCP servers are loaded (`--strict-mcp-config`)
- **Parallel-safe** — no shared file conflicts
- Best for `--bg` background agents

## Safety

- Base hooks MUST survive every mode switch — hook is additive, not replacing
- Mode switch is idempotent — switching to current mode is a no-op refresh
- If `.active-mode` file is missing or empty, no mode rules are injected
