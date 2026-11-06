# T3 Code Reference

Full API surface and architecture reference for agents operating inside T3 Code.
Derived from MCP tool schemas, CLI help, and filesystem inspection on a live
`v0.1.8-nightly` install (2026-11-06).

---

## Architecture Overview

T3 Code is an orchestration platform that wraps multiple AI coding providers
(Claude Code, Codex, OpenCode, Cursor, Kiro, Grok, Muse, Pi, Antigravity, fx)
behind a unified web UI, project model, and MCP server. It runs as a local
background service (systemd on Linux, launchd on macOS) and exposes:

- **Web UI** — threads, preview tabs, file explorer, terminal, device panel
- **MCP server** — `mcp__t3-code__*` tools available to any agent session
- **CLI** — `t3` binary for administration, scripting, and headless operation
- **T3 Connect** — cloud relay for remote access from other devices

Key concepts:
- **Project** — a registered workspace directory (usually a git repo)
- **Thread** — a conversation tied to a project. Has a provider, model, branch.
- **Delegate (task)** — a child agent spawned by a thread. Async by default.
- **Worktree** — isolated git checkout for a thread or delegate
- **Preview tab** — headless browser tab for UI testing
- **Scheduled task** — cron/interval/webhook-triggered autonomous agent runs

### Relationship to Claude Code

T3 Code *hosts* Claude Code as one of its providers (`claudeAgent`). When a
Claude Code session runs inside T3, it gains the `mcp__t3-code__*` MCP tools
in addition to its native tools. T3 reads:

- `.claude/settings.json` — hooks, permissions (Claude Code reads these)
- `.mcp.json` — MCP server definitions (shared with Claude Code)
- `CLAUDE.md` — project instructions (Claude Code reads these)

T3 adds its own layer on top:
- `~/.t3/userdata/settings.json` — provider preferences, idle compaction
- `~/.t3/userdata/keybindings.json` — keyboard shortcuts
- `~/.t3/caches/<provider>.json` — cached provider state (models, skills)
- Project-level scripts (build, test, lint) — configured via MCP tools

---

## MCP Tool Reference

### 1. Thread Management

#### `t3_thread_launch`
Create a new top-level thread bound to a workspace.

| Parameter | Type | Notes |
|-----------|------|-------|
| `title` | string | **Required.** Thread title. |
| `message` | string | First prompt. Omit for idle thread. Max 120k chars. |
| `projectId` | string | Omit to inherit from caller. |
| `modelSelection` | object | `{provider, model, options, instanceId}` |
| `runtimeMode` | enum | `approval-required`, `auto-accept-edits`, `auto`, `full-access` |
| `interactionMode` | enum | `default`, `plan` |
| `workspaceStrategy` | object | See below. |
| `scratch` | bool | No project — new Scratch folder. |
| `attachments` | array | Up to 8 image/file attachments. |
| `clientRequestId` | string | Idempotency key for retries. |
| `environmentId` | string | Target another linked environment. |

**workspaceStrategy types:**
- `root` — project checkout (default, not your worktree)
- `worktree` — new checkout from `baseRef`. Set `branch`, `startFromOrigin`.
- `existing_worktree` — bind to `worktreePath`

**When to use:** Creating independent top-level threads with their own worktree
or model. For delegation use `delegate_task` instead.

**Gotcha:** Modes cannot exceed yours. Uncommitted edits are not copied to
worktrees.

#### `create_threads`
Create multiple top-level threads in this checkout (batch). Project, branch,
and worktree inherit.

| Parameter | Type | Notes |
|-----------|------|-------|
| `threads` | array | 1–20 thread objects. Each has `title`, `prompt`, `target`, `runtimeMode`, `interactionMode`. |

**When to use:** Parallel threads in same checkout. For separate checkouts, use
`t3_thread_launch` with `workspaceStrategy`.

#### `t3_thread_list`
List threads newest first.

| Parameter | Type | Notes |
|-----------|------|-------|
| `projectId` | string | One project, or `allProjects: true`. |
| `statuses` | array | Filter: `idle`, `running`, `completed`, `failed`, etc. |
| `settled` | bool | Filter settled threads. |
| `snoozed` | bool | Filter snoozed threads. |
| `titleContains` | string | Title substring filter. |
| `includeSubagents` | bool | Include subagent threads. |
| `limit` | int | 1–100. |
| `cursor` | int | Pagination. |

#### `t3_thread_read`
Read thread messages or activity.

| Parameter | Type | Notes |
|-----------|------|-------|
| `threadId` | string | **Required.** |
| `view` | enum | `messages` (default) or `activity`. |
| `limit` | int | 1–100 items. Keep small. |
| `maxCharsPerItem` | int | 1–50000. Truncate large items. |
| `afterPosition` | int | Pagination via `nextPosition`. |
| `itemId` + `textOffset` | string, int | Resume a cut-off item. |

**Gotcha:** Reading a child's final result marks it "delivered". Name threads
by their `link`, verbatim.

#### `t3_thread_send`
Send message to any thread.

| Parameter | Type | Notes |
|-----------|------|-------|
| `threadId` | string | **Required.** |
| `message` | string | **Required.** |
| `mode` | enum | `auto` (default), `queue`, `steer`, `restart`. |

- `auto` — starts idle, steers running, or queues
- `steer` — mid-turn update to running agent
- `queue` — queue as next turn
- `restart` — interrupt and restart

**Gotcha:** Target cannot run with broader modes than yours. Sending to a
finished child thread starts a fresh task (returns `taskId`).

#### `t3_thread_send_attachments`
Send uploaded attachments as a message. Up to 8 attachments. No retry key.

#### `t3_thread_search`
Search active threads by title, branch, PR, project, then message text.
Not exhaustive. Skips subagent threads.

#### `t3_thread_configure`
Read or set a thread's provider, model, and options. Omit `threadId` for
current thread. Use `modelSelection` to change. Values from
`orchestrator_capabilities`.

#### `t3_thread_update`
Rename a thread or regenerate its title. Cannot change workspace or branch.

#### `t3_thread_organize`
Lifecycle management: `pin`, `unpin`, `snooze` (needs `snoozedUntil`),
`unsnooze`, `settle`, `unsettle`, `archive`, `unarchive`, `mark_unread`.

Settling current thread applies at turn end.

#### `t3_thread_transfer`
Move context between threads.
- `fork` — copy into a new thread from `sourcePoint`
- `merge_back` — merge into related `targetThreadId`
- `status` — check transfer state

#### `t3_thread_interrupt`
Interrupt a running turn. For delegates, use `task_cancel`.

#### `t3_thread_wait`
Wait for a thread's run to finish. Returns at once if idle. On timeout with
`next`, end your turn. `untilDelegatedWorkSettled: true` also waits for
child tasks.

### 2. Delegation and Orchestration

#### `delegate_task`
Spawn a child agent. No parent history passed.

| Parameter | Type | Notes |
|-----------|------|-------|
| `task` | string | **Required.** The prompt. |
| `title` | string | Display name. |
| `isolation` | enum | `shared` (default) or `worktree` (separate checkout). |
| `mode` | enum | `async` (default) or `wait` (blocks this turn). |
| `role` | enum | `implementation`, `research`, `review`, `design`, `test`, `general`. |
| `target` | object | `{provider, model, options, environmentId, projectId, providerInstanceId, driverKind}` |
| `runtimeMode` | enum | Cannot exceed parent's mode. |
| `interactionMode` | enum | `inherit`, `default`, `plan`. |
| `timeoutMs` | number | Wait mode only. Default 10 min. |

**When to use:** Child work that doesn't need parent context.
Use `isolation:'worktree'` for separate PRs per child.

**Gotcha:** Async is default. A question or approval from the child ends the
wait. Call `orchestrator_capabilities` once before first delegation.

#### `task_status`
Read a delegated task. Do NOT poll a running task — wait for completion
notification.

| Field | Meaning |
|-------|---------|
| `workState: 'working'` | Still running. |
| `workState: 'waiting_for_children'` | Has live child work. |
| `workState: 'result_available'` | Done. `summary` has result. |

Reading marks it delivered.

#### `task_cancel`
Stop a delegated task. Stops its running turns, delegates, and PR watches.
A finished task keeps its result.

#### `orchestrator_capabilities`
List available providers, models, options, and runtime modes.
Call once per thread before first `delegate_task`. Use `search` to find
unlisted models.

#### `t3_background_wait`
Keep thread in "Working" state while background tasks run. Pass task IDs.
`waiting: false` clears. Does NOT stop the task. Claude only.

#### `t3_workflow_stop`
Stop a running Claude Workflow in a thread. Pass `subagentId` from
`t3_thread_read` activity view.

### 3. Project Management

#### `t3_project_create`
Register a project folder.

| Parameter | Type | Notes |
|-----------|------|-------|
| `title` | string | **Required.** |
| `workspaceRoot` | string | Path. Omit to create new git repo from title. |
| `createWorkspaceRootIfMissing` | bool | Create dir if absent. |
| `defaultModelSelection` | object | Default model for threads. |
| `scripts` | array | Build/test/lint scripts. |

#### `t3_project_read`
Read one project: workspace path and saved scripts.

#### `t3_project_update`
Update project settings: `title`, `workspaceRoot`, `defaultModelSelection`,
`scripts`, `archived`, `pinned`, `autoPull`, `defaultThreadEnvMode`,
`projectIcon`, `faviconPath`.

Scripts schema:
```json
{
  "id": "test",
  "name": "Run Tests",
  "command": "npm test",
  "icon": "test",
  "runOnWorktreeCreate": true,
  "runOnSettle": false,
  "async": false,
  "autoOpenPreview": false
}
```

Icon choices: `play`, `test`, `lint`, `configure`, `build`, `debug`.

#### `t3_project_delete`
Delete a project. Folder on disk stays. Nonempty needs `force: true`.

#### `t3_project_list`
List all projects. Paginate with `cursor` and `limit` (1–100).

#### `t3_project_clone`
Clone a repository to `destinationPath`. Register after with
`t3_project_create`.

### 4. Worktree Management

#### `t3_worktree_handoff`
Move THIS thread into a new git worktree on a new branch.

| Parameter | Type | Notes |
|-----------|------|-------|
| `branch` | string | **Required.** |
| `baseRef` | string | Base branch/tag/commit. |
| `continuationPrompt` | string | Resumes work in next turn. |
| `runSetupScript` | bool | Default true. |
| `startFromOrigin` | bool | Fetch and start from remote ref. |

**Gotcha:** Call last in your turn — move ends the live session. Without
`continuationPrompt`, thread waits idle. Worktree stays after thread deletion.

#### `t3_worktree_status`
Check if this thread has a worktree: path, branch, project root, and
`startFromOrigin` default.

#### `t3_worktree_list`
List branch refs and checkout paths for a thread's workspace. Paginate.
Filter with `query`, `refKind` (`all`, `local`, `remote`).

### 5. Preview / Browser

#### `preview_open`
Open a preview tab. For dev servers, pass `target: {kind:'environment-port', port}`.
For websites, pass `url`.

| Parameter | Type | Notes |
|-----------|------|-------|
| `url` | string | Absolute http(s) URL. |
| `target` | object | `{kind:'environment-port', port, path?, protocol?}` |
| `open` | bool | Show to user. Default true. |
| `reuseExistingTab` | bool | Default true. `false` makes new tab. |
| `tabId` | string | Reuse specific tab. |
| `profileId` | string | Login profile for new tab. |

**Gotcha:** Parallel subagents must each use `reuseExistingTab: false` and
track their own `tabId`.

#### `preview_snapshot`
Returns page state, accessibility tree, diagnostics, screenshot size.
Use `locator='aria-ref=<ref>'` for element targeting.
`save: true` writes PNG, returns `screenshotPath`.
`includeImage: true` to see the page visually.

#### `preview_act`
Interact with page: `click`, `type`, `hover`, `select`, `drag`, `upload`,
`press`, `scroll`. Target with `locator='aria-ref=<ref>'` from snapshot.

#### `preview_navigate`
Navigate tab to URL or dev server port.

#### `preview_evaluate`
Run JavaScript in page. Returns up to 64KB. Needs your tab or unclaimed one.

#### `preview_wait_for`
Wait for locator/selector/text/URL conditions to match.

#### `preview_resize`
Resize tab: `fill`, `freeform` (width/height), or `preset` (iPhone, iPad,
Pixel, Galaxy, Surface, Nest Hub, etc.).

#### `preview_set_appearance`
Set `prefers-color-scheme`: `dark`, `light`, or `system`.

#### `preview_dialog`
Accept or dismiss page dialogs reported by `preview_status`.

#### `preview_recording_start` / `preview_recording_stop`
Record tab activity. Stop returns local path to recording (max 50 MiB).

#### `preview_status`
Report tab state: owner, dialog, URL, title, loading, viewport.
`tabs` lists this thread's tabs. `profiles` lists login profiles.

#### `t3_preview_list`
List this thread's preview tabs. Only `runtime:'server'` tabs can be
automated — others are on user's local desktop.

#### `t3_preview_close`
Close a preview tab this thread owns.

#### `html_preview`
Check HTML before rendering. Returns PNG, `contentHeight`, console output.
Inline styles/scripts. Local images as absolute paths are inlined.

#### `html_render`
Show finished HTML inline in thread above your reply. Uses T3 theme CSS
variables (`--background`, `--foreground`, `--primary`, `--chart-1` to
`--chart-6`, etc.). Max frame height 2000px. No `vh` units.

### 6. Device Management

#### `device_list`
List iOS Simulators and Android Emulators on device hosts.

#### `device_open`
Open a simulator/emulator for this thread. Boots if needed.
Returns `agent-device` CLI command for driving it.

#### `device_close`
Remove device from thread panel. `shutdown: true` turns it off.

#### `device_screenshot`
Get PNG of open device screen.

### 7. Scheduling

#### `schedule_task`
Create or update scheduled autonomous work.

Schedule types:
- `{type:'interval', everyMs}` — min 60000 ms
- `{type:'fixed_time', timeOfDay, weekdays?}` — weekdays 0=Sun to 6=Sat
- `{type:'once', runAt}` — one-time
- `{type:'webhook'}` — HTTP trigger, returns `webhookUrl`

Webhook features:
- `filters` — match request headers/body (up to 16)
- `signature` — HMAC verification (header, encoding, prefix, secret)
- `dedupe` — replay/coalesce keys, configurable window

| Parameter | Type | Notes |
|-----------|------|-------|
| `prompt` | string | Agent prompt for each run. |
| `schedule` | object | **Required for create.** |
| `title` | string | Display name. |
| `bindToCurrentThread` | bool | Default true. False = new thread per run. |
| `enabled` | bool | Default true. Set false to pause. |
| `scheduledTaskId` | string | To update existing task. |

#### `list_scheduled_tasks`
List scheduled tasks for a project.

#### `run_scheduled_task_now`
Trigger a scheduled task immediately. Returns thread or null.

#### `delete_scheduled_task`
Delete a scheduled task (stops at once). To pause, use `schedule_task` with
`enabled: false`.

### 8. Environment and Configuration

#### `t3_environment_read`
Read server identity and preferences.

#### `t3_environment_preferences_update`
Update environment-wide preferences.

| Parameter | Type | Notes |
|-----------|------|-------|
| `backgroundActivity` | object | `{profile: 'balanced'|'performance'|'battery-saver'}` |
| `defaultThreadEnvMode` | enum | `local` or `worktree` |
| `newWorktreesStartFromOrigin` | bool | |
| `enableProviderUpdateChecks` | bool | |
| `sourceControlWritingStyle` | object | `{mode: 'repo_conventions'|'conventional_commits'|'custom', customInstructions, followChangeRequestTemplates}` |

### 9. Pull Requests

#### `link_pull_request` / `link_pull_requests`
Link PR(s) to a thread. T3 shows status and settles thread on merge.

#### `list_thread_pull_requests`
List PRs linked to a thread with state and stack order.

#### `watch_pull_request`
Watch PR for check failures, passed checks, new comments/reviews, conflicts.
T3 wakes you on events. End your turn after calling. Watch persists — don't
re-watch on wake.

#### `unwatch_pull_request`
Stop watching. PR stays linked.

#### `unlink_pull_request` / `unlink_pull_requests`
Remove PR link(s). Batch version filters by state (`open`, `closed`, `merged`).

#### `read_pull_request_guide`
Read PR's stored review guide and run state. Never starts a run.

#### `write_pull_request_guides`
Write review guides for up to 20 PRs. Runs in temporary checkouts. Takes
minutes. A run for the same HEAD is joined.

### 10. Secrets

#### `request_secret`
Prompt user for a secret in a private card.

| Parameter | Type | Notes |
|-----------|------|-------|
| `label` | string | **Required.** What the secret is. |
| `reason` | string | **Required.** Why it's needed. |
| `delivery` | enum | `secretRef` (for T3 tools) or `file` (for shell: `cat <path>`). |
| `timeoutMs` | int | Default 10 min. Max 1 hour. |

Returns one-use `secretRef` or file path. Agent never sees the value.

### 11. Attachments

#### `t3_attachment_prepare_upload`
Get upload URL. POST file bytes, then send via `t3_thread_send_attachments`.

#### `t3_attachment_discard`
Discard a pending (unsent) upload.

### 12. Queue Management

#### `t3_queue`
Manage queued messages for a thread.

Actions: `list`, `read`, `edit`, `cancel`, `reorder`, `promote_to_steer`.
Writes fail once run is no longer queued.

### 13. Pending Requests

#### `t3_pending_request`
Manage pending user questions in a thread.

Actions: `list`, `read` (by `requestId`), `respond` (with `answers`).
Cannot approve permission requests.

---

## CLI Reference

### Core Commands

| Command | Purpose |
|---------|---------|
| `t3` | Start server + open browser. `--no-browser` to skip. |
| `t3 serve` | Start server, no browser. |
| `t3 app` | Open project in running desktop app. |
| `t3 status` | Show service setup and remote access settings. |
| `t3 --version` | Print version. |

### Service Management

| Command | Purpose |
|---------|---------|
| `t3 up` | Set up remote access + background service. Interactive. |
| `t3 up --yes` | Non-interactive, keep current settings. |
| `t3 up --connect` | Enable T3 Connect. |
| `t3 up --lan` | Enable LAN access. |
| `t3 service install` | Install systemd/launchd service. |
| `t3 service restart` | Restart (picks up new version). |
| `t3 service uninstall` | Remove background service. |
| `t3 service status` | Check if service is installed. |
| `t3 service protect` | Set OOM protection (Linux systemd, needs sudo). |

### Updates

| Command | Purpose |
|---------|---------|
| `t3 update` | Update to newest on current channel. |
| `t3 update --channel stable` | Switch to stable channel. |
| `t3 update --channel nightly` | Switch to nightly channel. |
| `t3 update --channel preview` | Switch to preview channel. |
| `t3 update <version>` | Install exact version. |
| `t3 update --allow-downgrade` | Allow older version. |
| `t3 update --yes` | Auto-restart service. |
| `t3 uninstall` | Remove t3 from machine. Keeps projects/threads. |

### Project Management

| Command | Purpose |
|---------|---------|
| `t3 project add <path>` | Register workspace directory. `--title` optional. |
| `t3 project remove` | Remove project registration. |
| `t3 project rename` | Rename project. |

### Thread Management (CLI)

| Command | Purpose |
|---------|---------|
| `t3 thread start <project> <message>` | Start thread. `-` reads stdin. |
| `t3 thread send <threadId> <message>` | Send message. `--wait` blocks for reply. |
| `t3 thread show <threadId>` | Show state + messages. `--messages N`. |
| `t3 thread list` | List project threads. `--project <id>`. |

Thread start flags: `--model`, `--provider`, `--worktree <ref>`, `--branch`,
`--wait`, `--json`.

### Remote Access

| Command | Purpose |
|---------|---------|
| `t3 pair` | Generate pairing QR code/token. `--ttl`, `--scope`, `--label`. |
| `t3 connect` | Same as `t3 up --connect`. |
| `t3 connect login` | Authorize CLI without enabling remote access. |
| `t3 connect link` | Authorize for T3 Connect on next start. |
| `t3 connect publish` | Toggle push notifications to mobile. |
| `t3 connect status` | Check connectivity. |
| `t3 connect unlink` | Disable T3 Connect (keep auth). |
| `t3 connect logout` | Disable + clear auth. |
| `t3 environment link <url>` | Link another T3 environment. `--pairing-code`, `--access`. |
| `t3 environment list` | List linked environments. |
| `t3 environment unlink` | Forget linked environment. |

### Authentication

| Command | Purpose |
|---------|---------|
| `t3 auth pairing create` | Issue pairing token. |
| `t3 auth pairing list` | List active pairing tokens. |
| `t3 auth pairing revoke` | Revoke pairing token. |
| `t3 auth session issue` | Issue bearer access token. |
| `t3 auth session list` | List active sessions. |
| `t3 auth session revoke` | Revoke session. |

Pairing scopes: `orchestration:read`, `orchestration:operate`,
`settings:write`, `providers:manage`, `environment:maintain`,
`preview:operate`, `diagnostics:read`, `terminal:read`, `terminal:operate`,
`filesystem:read`, `filesystem:write`, `source-control:write`, `access:read`,
`access:write`, `relay:read`, `relay:write`.

### Diagnostics

| Command | Purpose |
|---------|---------|
| `t3 doctor` | Inspect and repair data directory. `--fix`, `--dry-run`. |
| `t3 triage` | Investigate problem with claude/codex agent. |
| `t3 trace summary` | Summarize server trace: counts, rates, latency. |
| `t3 policy show` | Show managed policy. |
| `t3 policy check` | Validate policy file. |
| `t3 policy templates` | Write GPO/macOS config templates. |

### Browser and Theme

| Command | Purpose |
|---------|---------|
| `t3 browser setup` | Set up Linux for headless Chrome sandbox + libs. |
| `t3 theme set` | Set environment theme. |
| `t3 theme clear` | Remove theme. |
| `t3 theme show` | Show current theme. |

---

## Filesystem Layout

```
~/.t3/
├── service.env              # Environment vars (T3CODE_LAN=true, etc.)
├── usage-host-id            # Machine identifier
├── caches/
│   ├── claudeAgent.json     # Cached provider state (models, skills, etc.)
│   ├── codex.json
│   ├── opencode.json
│   ├── cursor.json
│   ├── kiro.json
│   ├── grok.json
│   ├── muse.json
│   ├── pi.json
│   ├── antigravity.json
│   ├── fx.json
│   └── pull-requests/       # PR guide cache
├── runtime/
│   ├── launchers            # Launcher path
│   ├── service-state.json   # Service PID, state
│   ├── .restart-pending     # Flag for pending restart
│   └── versions/
│       ├── 0.1.7/           # Previous version
│       │   ├── t3           # Binary
│       │   └── client/      # Web UI static files
│       └── 0.1.8-.../       # Current version
│           ├── t3
│           ├── client/
│           └── lib/          # Native libs (libatomic, etc.)
├── tools/
│   ├── chrome-headless-shell/  # Managed headless browser
│   └── cloudflared/            # T3 Connect tunnel binary
├── userdata/
│   ├── settings.json           # User preferences
│   ├── keybindings.json        # Keyboard shortcuts
│   ├── model-manifest.json     # Full model catalog
│   ├── server-runtime.json     # PID, port, origin, version
│   ├── server-owner.sqlite     # Owner/auth database
│   ├── statev2.sqlite          # Main state database (threads, projects)
│   ├── environment-id          # This environment's UUID
│   ├── anonymous-id            # Anonymous telemetry ID
│   ├── themes/                 # Custom themes
│   ├── secrets/                # Secret storage
│   ├── logs/                   # Server logs
│   │   └── boot-service.log
│   ├── attachments/            # Uploaded file staging
│   ├── usage-model-rates.json  # Model pricing data
│   └── usage-scan-cache-*.json # Usage tracking cache
└── worktrees/
    └── <project>/              # Git worktrees per project
        └── t3-<hash>/         # Individual worktree checkouts
```

---

## Provider Configuration

Providers configured in `~/.t3/userdata/settings.json`:

```json
{
  "providerModelPreferences": {
    "claudeAgent": {
      "hiddenModels": ["claude-opus-5-5", ...],
      "modelOrder": []
    }
  },
  "providerInstances": {
    "codex": {
      "driver": "codex",
      "enabled": false
    }
  },
  "idleCompaction": "onReturn",
  "deviceOnboardingCompleted": true
}
```

Known provider drivers: `claudeAgent`, `codex`, `opencode`, `cursor`, `kiro`,
`grok`, `muse`, `pi`, `antigravity`, `fx`.

Enable/disable via `providerInstances.<name>.enabled`. Model visibility
controlled via `hiddenModels` array.

---

## MCP Server Configuration

T3 reads `.mcp.json` from the project root — same file Claude Code reads.
Format:

```json
{
  "mcpServers": {
    "server-name": {
      "command": "/path/to/executable",
      "args": ["arg1", "arg2"],
      "env": {"KEY": "VALUE"}
    }
  }
}
```

No separate T3-specific MCP config exists. What's in `.mcp.json` is what
T3 exposes to agent sessions.

---

## Hooks and Mode System

T3 respects `.claude/settings.json` hooks because it *hosts* Claude Code:

```json
{
  "hooks": {
    "UserPromptSubmit": [{"matcher": "", "hooks": [...]}],
    "PreToolUse": [{"matcher": "Bash|Read", "hooks": [...]}],
    "PostToolUse": [{"matcher": "", "hooks": [...]}],
    "Stop": [{"matcher": "", "hooks": [...]}]
  }
}
```

This project's mode system works by:
1. `.claude/.active-mode` file tracks current mode
2. `mode-inject.sh` hook fires on `UserPromptSubmit`
3. Per-mode settings in `.claude/modes/<mode>/settings.json`
4. Mode-specific MCP servers could be in `.mcp-<mode>.json`

T3 itself does NOT have a native mode concept. The mode system is our custom
layer built on Claude Code hooks that T3 inherits.

---

## What T3 Handles Natively vs Our Custom Layer

### T3 Native
- Thread lifecycle (create, send, settle, archive, snooze)
- Delegation with worktree isolation
- Multi-provider model selection
- Preview browser (headless Chrome)
- Scheduled tasks (cron, interval, webhook)
- PR linking, watching, auto-settle on merge
- PR review guide generation
- Git worktree management
- Project registration and scripts
- Remote access (T3 Connect, LAN, pairing)
- Environment linking (multi-machine)
- Secret management (user never sees value)
- Queue management for thread messages
- Background service with OOM protection
- Managed tool installs (Chrome, cloudflared)
- Keyboard shortcuts and theming

### Our Custom Layer (hooks + scripts)
- Mode system (platform-ops, red-team, green-dev, etc.)
- Mode-gated tool access (`mode-tool-gate.sh`)
- Secret scanning (`secret-scan.sh`)
- Audit trail (`audit-trail.sh`)
- Response scanning (`response-scanner.sh`)
- CTP bridge gate (`pretooluse-ctp.sh`)
- Tuoni secret guard (`tuoni-secret-guard.sh`)
- Session end audit (`session-end-audit.sh`)
- Mode-specific MCP server selection
- Statusline (caveman badge, mode indicator)
- Board/kanban integration (GitHub Projects)
- Skill system (bmad-*, engagement-*, etc.)
