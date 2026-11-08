# T3 Project Scaffold — Design Document

**Issue:** #256
**Status:** Design — no implementation
**Date:** 2026-11-07
**Depends on:** `feat/env-profiles` (PR #270)

---

## 1. Problem Statement

The current system runs all modes in a single T3 project with a shared
`.active-mode` file. Two threads in the same project can stomp each other's
mode state, breaking tool-policy enforcement. Context bleed between modes
(red-team rules leaking into dev sessions) degrades with long conversations.

Environment profiles (#255) solve the *what config* question. This scaffold
solves the *where it lives* question: one T3 project per environment, with
security config generated from the my_claude_dev template.

## 2. What the Scaffold Produces

Running `scripts/scaffold-project.sh <profile>` creates a T3 project and
populates its `.claude/` directory from the template.

### 2.1 Directory Structure (per project)

```
<project-root>/
├── .claude/
│   ├── settings.json          # hooks pointing to guard scripts
│   ├── .active-mode           # mode state (isolated per project)
│   ├── CLAUDE.md              # project-scoped instructions
│   ├── hooks/                 # symlinks → my_claude_dev hooks
│   │   ├── mode-tool-gate.sh
│   │   ├── pretooluse-ctp.sh
│   │   ├── tuoni-secret-guard.sh
│   │   ├── auto-log-finding.sh
│   │   └── session-end-audit.sh
│   ├── modes/                 # only modes valid for this profile
│   │   ├── <mode-a>/
│   │   │   ├── system-prompt.md
│   │   │   ├── tool-policy.yaml
│   │   │   └── settings.json
│   │   └── <mode-b>/
│   │       └── ...
│   └── project-routes.yaml    # (only in hub project)
├── .mcp.json                  # MCP server config for this profile
├── .env                       # profile env overlaid at launch
└── profiles/                  # (only in hub project — templates)
```

### 2.2 Generated Files

| File | Source | Strategy |
|------|--------|----------|
| `.claude/settings.json` | Template `settings.json` | Copy, rewrite `$CLAUDE_PROJECT_DIR` paths to point at my_claude_dev install |
| `.claude/hooks/*` | my_claude_dev `.claude/hooks/` | **Symlink** — single source of truth for guard logic |
| `.claude/modes/<mode>/` | my_claude_dev `.claude/modes/` | **Copy** filtered by `PROFILE_MODES` from profile |
| `.claude/CLAUDE.md` | Template + profile metadata | Generate: base contract + profile-specific instructions |
| `.mcp.json` | Build from `PROFILE_MCPS` | Generate: only servers this profile needs |
| `.active-mode` | Profile default mode | Write initial mode for this profile |

### 2.3 Security Config

Each project carries its own:
- **tool-policy.yaml per mode** — copied from template, deterministic deny
- **.active-mode** — isolated, no cross-project stomping
- **hooks** — symlinked to central guard stack (single update point)
- **settings.json** — hook wiring scoped to this project's `$CLAUDE_PROJECT_DIR`

## 3. Project-to-Profile Mapping

One T3 project per environment profile. Mapping from issue #256:

| T3 Project | Profile | Modes | Spokes |
|------------|---------|-------|--------|
| Cyber Range | `range` | platform-ops, green-dev, red-team, red-dev, purple | deploybox, kali |
| CTF | `ctf` | platform-ops, red-dev, red-team | none (VPN) |
| Pentest | `pentest` | platform-ops, red-team, red-dev | client VPN spoke |
| Homelab | `homelab` | platform-ops, homelab | homelab spoke |
| Dev | `general` | platform-ops, dev | none |

Every profile includes `platform-ops` — framework maintenance always available.

The scaffold reads `PROFILE_MODES` and `PROFILE_MCPS` from the profile `.env`
file (from `feat/env-profiles`) to determine which modes to copy and which
MCP servers to configure.

## 4. Machine-Level vs Project-Level

### 4.1 Machine-Level (shared, not duplicated)

These live in my_claude_dev and are referenced by symlink or path:

| Component | Location | Why machine-level |
|-----------|----------|-------------------|
| Guard scripts (hooks) | `my_claude_dev/.claude/hooks/` | Single update point. Bug fix propagates to all projects. |
| `scripts/hooks/` | `my_claude_dev/scripts/hooks/` | Same — secret-scan, mode-inject, response-scanner, audit-trail |
| Profile templates | `my_claude_dev/profiles/` | Source of truth for profile definitions |
| Scaffold script | `my_claude_dev/scripts/scaffold-project.sh` | Meta — creates projects |
| Mode definitions (master) | `my_claude_dev/.claude/modes/` | Template source. Projects get copies filtered by profile. |
| Skills + MCP configs | `~/.claude/` user-level | Skills available in all projects |
| `project-routes.yaml` | `my_claude_dev/.claude/modes/` | Hub routing table (hub project only) |

### 4.2 Project-Level (per-project, isolated)

| Component | Why project-level |
|-----------|-------------------|
| `.active-mode` | Mode state must be isolated. Two projects in different modes simultaneously. |
| `settings.json` | Hook *wiring* scoped to project. Points at symlinked scripts. |
| `tool-policy.yaml` (copies) | Copied so project can't see policies for modes it doesn't have. |
| `CLAUDE.md` | Project-specific instructions (engagement scope, SOW ref, etc.) |
| `.mcp.json` | Only this profile's MCP servers. Prevents connection attempts to unavailable servers. |
| `.env` | Profile-specific credentials and spoke endpoints |

### 4.3 Decision: Symlink vs Copy

**Hooks = symlink.** Guard logic must be uniform. A bug fix in
`mode-tool-gate.sh` should propagate instantly to all projects without
re-scaffolding.

**Mode configs = copy.** Each project only has modes valid for its profile.
If CTF project has no `green-dev/tool-policy.yaml`, switching to green-dev
in that project fails immediately (correct behavior). Copy also allows
per-project policy overrides (e.g., pentest project loosening one MCP for
a specific engagement).

**Risk:** Copied mode configs drift from template. Mitigated by:
- `scripts/scaffold-project.sh --check <project>` — diff project configs
  against template, report drift
- Template version stamp in generated `CLAUDE.md` (e.g., `scaffold-version: 2026-11-07`)
- Operator re-scaffolds to pull updates: `scaffold-project.sh --update <project>`

## 5. Migration Path

Incremental. No big-bang cutover.

### Phase 1: Scaffold Script (this issue)
- Build `scripts/scaffold-project.sh`
- Reads profile env, creates T3 project via `t3_project_create`
- Populates `.claude/` per §2
- Test with one non-range profile (CTF or Dev)
- **my_claude_dev continues working as-is** — no disruption

### Phase 2: First Non-Range Project
- Scaffold CTF or Dev project
- Verify: hooks fire, mode-tool-gate enforces, MCP config correct
- Verify: hub thread can route to new project's threads
- Acceptance: operator runs a session in new project, mode isolation holds

### Phase 3: Range Migration
- Scaffold Cyber Range project
- Existing range hooks/modes stay in my_claude_dev (backward compat)
- New project gets copies pointing at same guard stack
- Parallel run: old single-project and new multi-project coexist
- Cutover when operator confirms equivalent behavior

### Phase 4: Hub Thread as Router
- Hub thread in my_claude_dev (or dedicated hub project) becomes pure router
- `t3_thread_launch` dispatches to project threads by intent
- `project-routes.yaml` evolves to map projects, not just repos
- mode-inject hook in hub project stays minimal (base mode only)

### Phase 5: Cleanup
- Remove duplicated mode configs from my_claude_dev if no longer hub
- Or: keep my_claude_dev as hub + template source (likely outcome)
- Archive migration scaffolding

## 6. Hub Thread Routing

### 6.1 Current State
Hub = main thread in my_claude_dev. Routes work via:
- `/mode <name>` — switches `.active-mode`, hook injects new rules
- `delegate_task` / `t3_thread_launch` — spawns worker threads
- `project-routes.yaml` — maps repos to default modes

### 6.2 Target State
Hub thread sits in hub project (my_claude_dev or dedicated). Routes by:

```
Operator request
    ↓
Hub thread (base mode, minimal policy)
    ↓
Identify target profile/project
    ↓
t3_thread_launch(project=<target>, workspaceStrategy=worktree)
  OR t3_thread_send(thread=<existing>) to resume
    ↓
Target project thread inherits project's:
  - .claude/settings.json (hooks)
  - .claude/modes/ (available modes)
  - .active-mode (current mode)
  - .mcp.json (available servers)
  - CLAUDE.md (project instructions)
```

### 6.3 Routing Table Evolution

Current `project-routes.yaml` maps repo keys to modes. Post-scaffold, it maps
intent to T3 projects:

```yaml
# Future: project-routes.yaml v2
projects:
  range:
    t3_project_id: "..."
    default_mode: red-team
    modes: [platform-ops, green-dev, red-team, red-dev, purple]
  ctf:
    t3_project_id: "..."
    default_mode: red-team
    modes: [platform-ops, red-dev, red-team]
  # ...

# Repo routing still works for delegate_task
repos:
  "github.com/moon-knight13/tuoni-plugins": range
  "github.com/moon-knight13/homelab_planning": homelab
```

### 6.4 Cross-Project Messaging

Hub dispatches to project threads via `t3_thread_send`. Project threads
do NOT message each other directly — all routing through hub.

Star topology: hub at center, project threads at edges. Prevents:
- Uncontrolled lateral context sharing
- Mode confusion from cross-project state
- Audit trail gaps (hub logs all routing decisions)

## 7. Security Implications

### 7.1 Improvements Over Current State

| Risk | Current | Post-Scaffold |
|------|---------|---------------|
| Mode state collision | Shared `.active-mode` — two threads can stomp | Per-project `.active-mode` — isolated |
| Context bleed | Long session accumulates cross-mode rules | Project threads start clean per-project CLAUDE.md |
| Tool policy bypass | Correct mode needed in shared file | Each project only has its profile's modes |
| MCP exposure | All servers visible regardless of mode | `.mcp.json` filtered per profile |
| Credential scope | Single `.env` has all credentials | Per-profile `.env` has only relevant creds |

### 7.2 New Risks

| Risk | Mitigation |
|------|-----------|
| Symlink tampering (hooks) | Hooks in my_claude_dev are git-tracked. Tampered symlink = broken hook = fail-closed (exit 2). |
| Stale mode copies | `--check` command diffs against template. CI can enforce. |
| Hub bypass (direct project access) | Hooks enforce regardless of entry point. Hub routing is convenience, not security boundary. |
| Cross-thread messaging | Star topology + existing defense-in-depth (all hooks fire on all threads in a project). |
| Scaffold script injection | Script reads only `.env` files from known paths. No user-supplied code execution. |

### 7.3 Invariants (must hold post-migration)

1. **Every project has guard hooks** — scaffold never produces a project without hooks
2. **Hooks are symlinks** — no copied hooks that can silently diverge
3. **Fail-closed** — broken symlink = hook fails = exit 2 = tool call blocked
4. **Mode-tool-gate runs on every MCP call** — enforced by `settings.json` wiring
5. **No project has modes outside its profile** — scaffold filters mode dirs by `PROFILE_MODES`
6. **Credentials never in repo** — `.env` in `.gitignore`, scaffold validates this

## 8. Automation vs Manual Setup

### 8.1 Scaffold Automates

- T3 project creation (`t3_project_create`)
- `.claude/` directory population (hooks, modes, settings)
- `.mcp.json` generation from profile's `PROFILE_MCPS`
- `.active-mode` initialization to profile default
- `CLAUDE.md` generation with profile metadata
- Template version stamping
- Drift detection (`--check`)
- Config update from template (`--update`)

### 8.2 Requires Manual Setup

| Step | Why manual |
|------|-----------|
| `~/.claude-profiles/<profile>.env` credential fill | Secrets must not be automated or stored in repo |
| Spoke SSH key distribution | Per-machine, per-operator |
| MCP server installation | Machine-level, some require Docker/binary install |
| T3 project environment linking | Operator confirms machine-to-project binding |
| Hub thread initial configuration | One-time routing table setup |
| Obsidian vault creation | Per-operator note structure |

### 8.3 Semi-Automated (scaffold prompts, operator confirms)

- Profile selection (scaffold lists available, operator picks)
- Mode validation (scaffold checks `PROFILE_MODES` against available modes)
- MCP connectivity check (scaffold pings expected servers from `PROFILE_MCPS`)
- Spoke connectivity check (scaffold tests SSH if profile has spoke vars)

## 9. Interface with Existing Systems

### 9.1 Environment Profiles (PR #270)
Scaffold **consumes** profiles. `PROFILE_MODES` and `PROFILE_MCPS` drive
what goes into the T3 project. `switch-profile.sh` still works for
single-project mode; scaffold is the multi-project evolution.

### 9.2 Mode System (`.claude/modes/`)
Scaffold **copies** mode directories filtered by profile. Mode definitions
stay in my_claude_dev as source of truth. Project gets a subset.

### 9.3 Hook System (`.claude/settings.json`)
Scaffold **generates** settings.json with hook entries pointing at
**symlinked** guard scripts. Same hooks, different wiring paths.

### 9.4 day0-check / spoke-health
Should gain a `--project <name>` flag to validate a specific project's
config instead of just the current working directory.

## 10. Open Questions

1. **Hub project identity.** Is my_claude_dev the hub project forever, or
   does scaffold create a dedicated lightweight hub project?
   *Leaning:* my_claude_dev stays hub. It's where skills, hooks, and
   templates live. Separate hub project adds indirection for no gain.

2. **Mode override per engagement.** Pentest project may need a custom
   tool-policy for a specific engagement (client allows X but not Y).
   *Leaning:* Support a `local-overrides/` dir in project that scaffold
   ignores during `--check` and `--update`.

3. **Profile evolution.** When a new mode is added to my_claude_dev,
   how do existing projects pick it up?
   *Leaning:* `--update` re-runs scaffold logic. Operator adds new mode
   to profile's `PROFILE_MODES`, runs update.

4. **T3 project creation API.** Does `t3_project_create` support
   programmatic `.claude/` population, or does scaffold need to write
   files post-creation?
   *Action:* Test during Phase 1 implementation.

---

*Design only. Implementation tracked in #256.*
