---
name: mode
description: "Show mode info or generate launch command. Usage: /mode list | /mode <name> — prints the start-mode.sh command for that mode."
---

# Mode Info

Show available modes, describe a mode, or generate the launch command.
Modes are set at session start via `scripts/start-mode.sh`, not mid-session.

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

### If a mode name

1. **Validate** — check `.claude/modes/<name>/` exists with `system-prompt.md`
   and `settings.json`. If missing, report and refuse.

2. **Show mode info** — read `system-prompt.md` and summarize:
   - MCP servers available
   - OPSEC rules enforced
   - Key workflow steps

3. **Print launch command:**

```
./scripts/start-mode.sh <name>
```

With common variants:

```bash
# Interactive session
./scripts/start-mode.sh <name>

# Background agent
./scripts/start-mode.sh <name> --bg -p "<prompt>"

# With worktree
./scripts/start-mode.sh <name> -w
```

4. **If operator is already in a session** — explain that mode is set at
   session start. To switch, exit and relaunch with `start-mode.sh`.
   Mid-session mode switching is not supported because MCP servers and
   system prompt are loaded once at startup.

## How It Works

`start-mode.sh` uses Claude Code CLI flags for per-session isolation:

- `--append-system-prompt-file` — injects mode rules into system prompt
- `--settings` — overlays mode metadata on project settings
- `--mcp-config` + `--strict-mcp-config` — loads only this mode's MCP servers
- `--name` — labels session in `claude agents` list

No shared files are overwritten. Parallel sessions in different modes are safe.

## Legacy Fallback

If `start-mode.sh` is unavailable (e.g. remote session without shell access),
the old file-swap approach still works:

```bash
bash scripts/setup-mcp-servers.sh "$MODE_NAME"
# Generates .mcp-<mode>.json — copy to .mcp.json if needed
cp ".mcp-${MODE_NAME}.json" .mcp.json
cat .claude/modes/base/CLAUDE.md > CLAUDE.md
echo "" >> CLAUDE.md
cat ".claude/modes/$MODE_NAME/system-prompt.md" >> CLAUDE.md
echo "$MODE_NAME" > .claude/.active-mode
# Restart session
```
