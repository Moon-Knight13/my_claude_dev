---
name: flag-hunt
description: "Search compromised hosts for CTF flags via Tuoni agent. Runs after host-id or as standalone post-access step. Platform-aware (Linux/Windows)."
modes: [red-team, ctf]
---

# Flag Hunt — CTF Flag Discovery

## When to use

After gaining access to a host during CTF or exercise engagements. Searches
for planted flags via Tuoni agent commands. Can run:
- As optional step in Thread C POST-ACCESS (after cred-dump)
- Standalone on any host with active Tuoni agent
- As follow-on after discovery skill completes

Active in: **red-team** and **ctf** modes.

## Entry criteria

- Active Tuoni agent on target host
- Know current privilege level (user vs root/SYSTEM)

## OPSEC Rules — ENFORCED

- RT-TGT-002: no tools uploaded. Native OS commands only via tuoni agent.
- All commands through tuoni-mcp agent workflow.
- RT-SCOPE-001: skip gt-prefixed account directories.

## Platform Detection

Determine OS from prior discovery or agent metadata before running searches.
Use Linux commands on Linux, Windows commands on Windows. Never mix.

## Search Procedure — Linux

Run searches in order. Stop expanding search if flags found match expected count.

### Step 1: Common flag files
```bash
find / -maxdepth 4 \( -name "flag*" -o -name "proof*" -o -name "user.txt" -o -name "root.txt" -o -name "local.txt" -o -name "*.flag" \) -type f 2>/dev/null
```

### Step 2: Home directories
```bash
find /home /root -maxdepth 3 -name "*.txt" 2>/dev/null
```

### Step 3: Desktop and Documents
```bash
find /home/*/Desktop /home/*/Documents /root/Desktop /root/Documents -type f 2>/dev/null
```

### Step 4: Grep for flag patterns
```bash
grep -rn "FLAG{" /home /root /tmp /opt /var/www 2>/dev/null | head -30
```

### Step 5: Web roots
```bash
find /var/www /srv/www /opt -maxdepth 3 -name "flag*" -type f 2>/dev/null
```

### Step 6: Environment and processes
```bash
env | grep -i flag
ps aux | grep -i flag
```

### Step 7: Database and service configs (if root)
```bash
find /etc /var/lib -maxdepth 3 -name "flag*" -type f 2>/dev/null
```

## Search Procedure — Windows

### Step 1: Common flag files
```cmd
dir /s /b C:\flag* C:\proof* C:\Users\*\user.txt C:\Users\*\root.txt C:\Users\*\local.txt 2>nul
```

### Step 2: User desktops and documents
```cmd
dir /s /b C:\Users\*\Desktop\*.txt C:\Users\*\Documents\*.txt 2>nul
```

### Step 3: Administrator locations
```cmd
type C:\Users\Administrator\Desktop\proof.txt 2>nul
type C:\Users\Administrator\Desktop\flag.txt 2>nul
type C:\Users\Administrator\Documents\flag.txt 2>nul
```

### Step 4: Grep for flag patterns
```cmd
findstr /s /i "FLAG{" C:\Users\*.txt C:\inetpub\*.txt C:\xampp\*.txt 2>nul
```

### Step 5: Web roots
```cmd
dir /s /b C:\inetpub\wwwroot\flag* C:\xampp\htdocs\flag* 2>nul
```

### Step 6: Environment
```cmd
set | findstr /i flag
```

## Output

For each flag found, record:

| Field | Value |
|-------|-------|
| Path | Full filesystem path |
| Content | Flag string (exact) |
| Privilege | user / root / SYSTEM |
| Host | Hostname |
| Timestamp | When found |

### Report to operator

Print found flags immediately with path, content, and privilege level.

### Write to Obsidian

Update target page with `## Flags` section:

```markdown
## Flags

| Flag | Path | Privilege | Timestamp |
|------|------|-----------|-----------|
| FLAG{example} | /root/root.txt | root | 2026-11-09 |
```

Also append to engagement page summary under `## Captured Flags`.

## Failure modes

| Failure | Action |
|---------|--------|
| No flags found | Report negative result. May need deeper search or different privilege level. |
| Agent dies mid-search | Use sleeper beacon to re-establish. Resume from last completed step. |
| Permission denied on paths | Note which paths blocked. Return after privilege escalation. |
| Flag format unknown | Collect all suspicious strings. Operator determines validity. |

## MCP Tool Reference

| MCP | Tools | When |
|-----|-------|------|
| tuoni-mcp | agent commands (commands_search → command_describe → command_prepare → operation_execute) | All flag search commands |
| obsidian-mcp | obsidian_create_note, obsidian_patch_content | Write flags to target page |
