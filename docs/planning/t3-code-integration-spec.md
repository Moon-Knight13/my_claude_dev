---
title: "T3 Code v2 Integration — Orchestration Layer Spec"
status: draft
created: 2026-11-05
parent: prd-v2.md
---

# T3 Code v2 Integration Spec

## 1. Problem

Single provider dependency. If Anthropic API goes down or Opus 4.6 gets
pulled, all sessions stop. No failover, no context preservation, no way to
continue work on another provider without manual re-briefing.

Secondary: no unified view of parallel agent sessions (red-team forks,
background jobs, scheduled tasks) outside terminal scrollback.

## 2. What T3 Code v2 Provides

T3 Code v0.1.7+ ships orchestration-v2 on `main`. Key capabilities:

| Capability | How it helps us |
|---|---|
| Provider switching mid-thread | Manual failover: Claude Code → OpenCode with context handoff |
| Context handoff (delta/full) | Preserves goals, decisions, changed files across provider switch |
| Sub-agent delegation (`delegate_task`) | Dispatch child tasks to different providers from parent thread |
| Scheduled tasks (cron/webhook) | Replace our ScheduleWakeup/CronCreate for recurring ops |
| MCP orchestrator (`t3-code`) | Providers connect to T3's MCP; T3 routes to our MCPs |
| Durable thread state (SQLite) | Sessions survive restarts, crash recovery |
| Remote access (phone/tablet/web) | Monitor range ops from mobile during exercises |

## 3. Architecture

```
┌─ Host Laptop ─────────────────────────────────────────────┐
│                                                           │
│  T3 Code Server (t3 service)                              │
│  ├─ Orchestrator (provider switching, delegation, cron)   │
│  ├─ MCP endpoint: t3-code @ 127.0.0.1:<port>/mcp         │
│  ├─ Web UI @ 127.0.0.1:3000                               │
│  └─ Remote access via T3 Connect / Tailscale              │
│                                                           │
│  ┌─ Devcontainer ──────────────────────────────────────┐  │
│  │                                                     │  │
│  │  Provider: Claude Code CLI                          │  │
│  │  ├─ .claude/modes/ (OPSEC, system-prompt.md)        │  │
│  │  ├─ .claude/skills/ (kill chain, engagement)        │  │
│  │  ├─ hooks (mode-inject, secret-scan, ctp-bridge)    │  │
│  │  └─ MCP servers (range-intel, tuoni, outline, etc.) │  │
│  │                                                     │  │
│  │  Provider: OpenCode CLI (failover)                  │  │
│  │  ├─ reads same .claude/ config where compatible     │  │
│  │  ├─ OpenRouter → local model or cloud fallback      │  │
│  │  └─ MCP servers (same set, stdio)                   │  │
│  │                                                     │  │
│  └─────────────────────────────────────────────────────┘  │
│                                                           │
│  VPN → Range (172.21.x.x)                                 │
└───────────────────────────────────────────────────────────┘
```

### Layer Responsibilities

| Layer | Owns | Does NOT own |
|---|---|---|
| **T3 Code** | Provider lifecycle, thread state, context handoff, sub-agent dispatch, scheduling, remote UI | Mode rules, OPSEC, engagement state, MCP server config |
| **my_claude_dev** | Mode switching, OPSEC injection, engagement YAML, skills, hook chain, MCP routing | Provider selection, failover trigger, thread persistence |
| **Provider CLI** | Execution, tool calls, file I/O, git | Everything above |

## 4. Failover Design

### 4.1 Health Check

Script on host polls Anthropic API status:

```bash
# scripts/provider-health.sh
# Runs every 60s via T3 scheduled task or systemd timer
ANTHROPIC_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  https://api.anthropic.com/v1/messages \
  -H "x-api-key: $ANTHROPIC_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -d '{"model":"claude-opus-4-6","max_tokens":1,"messages":[{"role":"user","content":"ping"}]}')

if [ "$ANTHROPIC_STATUS" -ge 500 ] || [ "$ANTHROPIC_STATUS" -eq 0 ]; then
  echo "DEGRADED"
  # Trigger T3 provider switch via MCP or notification
else
  echo "HEALTHY"
fi
```

### 4.2 Failover Trigger

Two modes:

**Automatic (v1):** Health check detects outage → sends notification to
operator via T3 remote UI → operator confirms provider switch in T3 web/mobile.
Human-in-the-loop, but fast (phone notification + one tap).

**Semi-automatic (v2):** Health check detects outage → calls T3 MCP
`t3_thread_send` to active thread with provider switch instruction → T3
generates context handoff → OpenCode picks up with delta summary. Requires
T3 API for programmatic provider switch (check if `t3_thread_send` supports
provider targeting).

### 4.3 Context Handoff Content

T3 generates handoff summary automatically. We augment with:

- Current `.claude/.active-mode` (which OPSEC rules apply)
- Engagement YAML path and status
- Last 3 tool calls and results (operational continuity)
- Active targets list (if red-team mode)

Custom handoff via T3's "manual context" strategy or injected into delta
summary.

### 4.4 Provider Capability Matrix

| Capability | Claude Code | OpenCode |
|---|---|---|
| MCP servers (stdio) | Yes | Yes |
| Hooks (UserPromptSubmit) | Yes | Check |
| Skills (.claude/skills/) | Yes | No (different format) |
| Mode injection | Via hook | Via config file |
| Range MCP access | Yes | Yes (same stdio) |
| Model quality | Opus 4.6 | OpenRouter (varies) |
| Local model fallback | No | Yes (Ollama) |

**Gap:** OpenCode doesn't read `.claude/skills/`. Failover loses skill
library. Mitigation: critical skills (engagement-state, mode) get
OpenCode-compatible equivalents, or we inject skill content into system
prompt at handoff time.

## 5. Sub-Agent Delegation Patterns

### 5.1 Parallel Recon (red-team mode)

Parent thread (Claude Code) delegates target recon to child threads:

```
Parent: "Recon 5 targets"
  → delegate_task("Recon target A", provider: claude)
  → delegate_task("Recon target B", provider: claude)
  → delegate_task("Recon target C", provider: opencode)  # load balance
  → task_status(A), task_status(B), task_status(C)
  → Merge results into engagement YAML
```

### 5.2 Failover with Active Work

```
Thread running on Claude Code (run 1-15)
  → Anthropic API goes down
  → T3 provider switch to OpenCode
  → Context handoff: delta summary of runs 1-15
  → OpenCode continues (run 16+) with degraded capability
  → Anthropic recovers
  → T3 provider switch back to Claude Code
  → Context handoff: delta summary of runs 16-20
  → Claude Code resumes (run 21+) with full capability
```

### 5.3 Scheduled Health Checks

```
T3 scheduled task: every 60s
  → Run provider-health.sh
  → If DEGRADED for 3 consecutive checks:
      → Notify operator via T3 remote UI
      → Optionally auto-switch provider
```

## 6. Installation Plan

### 6.1 Host Setup

```bash
# Install T3 Code
curl -fsSL https://t3.chat/install.sh | bash
t3 service install  # background service

# Providers authenticated in devcontainer are visible to T3
# via shared Docker socket or host CLI installations
```

### 6.2 Open Questions

1. **T3 + devcontainer:** Does T3 server see provider CLIs inside container?
   Likely needs host-level Claude Code + OpenCode installs, or T3 runs
   inside container alongside providers.

2. **MCP passthrough:** T3's `t3-code` MCP endpoint injects into providers.
   Our range MCPs (range-intel, tuoni, outline) are stdio in container.
   T3 doesn't need to route to them — providers connect directly. Confirm
   no conflict.

3. **Hook compatibility:** T3 manages provider lifecycle. Do our
   UserPromptSubmit hooks still fire? They should — T3 wraps the CLI,
   doesn't replace it. Verify.

4. **Config isolation:** T3 stores thread state in SQLite. Our engagement
   YAML and mode state are filesystem. No overlap expected. Verify.

5. **OpenCode skill gap:** OpenCode uses different skill format. Options:
   (a) port critical skills, (b) inject as system prompt, (c) accept
   degraded capability on failover.

6. **Provider switch API:** Can `t3_thread_send` trigger a provider switch
   programmatically, or is it UI-only? Determines whether automatic
   failover is possible.

## 7. Implementation Phases

### Phase 0: Validate (1 session)

- Install T3 Code on host
- Verify it sees Claude Code in devcontainer
- Create thread, run basic task
- Test provider switch Claude → OpenCode manually
- Verify hooks still fire after T3 wraps session

### Phase 1: Manual Failover (1-2 sessions)

- Configure both providers (Claude Code + OpenCode)
- Document provider switch procedure for operator
- Test context handoff quality (does delta summary capture enough?)
- Test mode preservation across switch
- Add health check script as T3 scheduled task

### Phase 2: Delegation (2-3 sessions)

- Test `delegate_task` for parallel recon pattern
- Verify child threads inherit MCP access
- Test child approval surfacing in parent thread
- Build delegation wrapper skill for red-team mode

### Phase 3: Semi-Automatic Failover (1-2 sessions)

- Programmatic provider switch via T3 API/MCP (if supported)
- Health check → notification → auto-switch pipeline
- Custom context handoff augmentation (mode, engagement state)
- Failback procedure (return to primary when recovered)

## 8. Security Requirements

### Mandatory Mitigations (implement at Phase A/B)

1. **`supergateway --apiKey <token>`** on all SSE proxy endpoints. Tokens in `.env`, never in repo.
2. **`--host 127.0.0.1`** binding on supergateway — never `0.0.0.0`.
3. **Tailscale HTTPS** for mobile remote access — not T3 Connect (avoids Ping.gg cloud relay).
4. **T3 permission mode: Auto** as default for new threads, never Full Access.
5. **Scoped device pairing** — `--scope` flag on `t3 up`, never default admin grant.
6. **No range secrets through OpenRouter** — red-team failover uses local Ollama only.

### Secrets Architecture (6 layers)

| Layer | Status | Component |
|---|---|---|
| 1. Environment variables | EXISTS | `.env`, systemd units — tokens never in repo |
| 2. Prompt-side scanning | EXISTS (extend) | `secret-scan.sh` — add SSE token + T3 pairing patterns |
| 3. MCP response filtering | NEW (build) | supergateway proxy — regex redact before model sees responses |
| 4. Handoff sanitization | NEW (build) | Strip raw tool output from T3 provider switch summaries |
| 5. Provider classification | NEW (policy) | Anthropic/Ollama=full context; OpenRouter=sanitized only |
| 6. Credential store refs | EXISTS (enforce) | `tuoni://cred/<id>` format in engagement YAML |

Layer 3 is critical path — SSE proxy is the only interception point for MCP
response content before it reaches model context. No `PostMcpResponse` hook
exists in Claude Code today.

### Threat Matrix Summary

| Risk | Threat | Mitigation |
|---|---|---|
| HIGH | Host claude full filesystem access (no container sandbox) | T3 permission mode: Supervised/Auto |
| HIGH | SSE proxy unauthenticated = any local process gets Tuoni C2 access | `--apiKey` + localhost bind + bridge firewall |
| MEDIUM | T3 MCP escalation (compromised MCP reads other threads) | T3 scopes MCP sessions to parent thread |
| MEDIUM | OpenRouter data exfil (engagement context to cloud proxy) | Local Ollama for red-team failover only |
| MEDIUM | Default device pairing grants admin (terminal + orchestration) | Scoped `--scope` pairing |

## 8.5 Scope and Ownership

### What lives where

| Component | Location | Reason |
|---|---|---|
| Mode system, hooks, skills | my_claude_dev | Configures AI behavior |
| SSE proxy install + systemd units | my_claude_dev `scripts/host/` | Bootstrap scripts, run once |
| Response filter patterns | my_claude_dev `scripts/host/` | Travels with secret-scan patterns |
| T3 install script | my_claude_dev `scripts/host/` | Bootstrap script |
| Provider classification policy | Mode system-prompts | Policy = mode concern |
| T3 runtime config | `~/.config/t3code/` (T3-owned) | T3 manages itself |
| SSE proxy runtime config | `~/.config/range-mcp-proxy/` | Host-level, persists across containers |
| Plan/spec docs | my_claude_dev `docs/planning/` | Architecture docs |

All host scripts in `scripts/host/` are bootstrap-only. Runtime config lives
on host outside repo. Future: extract to `homelab_infra` Ansible role when
that overhaul lands.

## 9. Risk Assessment

| Risk | Impact | Mitigation |
|---|---|---|
| T3 Code "very very early" — breaking changes | High | Pin version, test nightly before upgrade |
| Provider switch loses skill context | Medium | Inject critical skills into handoff summary |
| T3 can't see container providers | High (blocks all) | Phase 0 validates this first |
| Hook chain breaks under T3 wrapper | Medium | Phase 0 validates; fall back to non-T3 if broken |
| OpenCode model quality insufficient | Low | OpenRouter has Claude API access as fallback |
| T3 thread state conflicts with engagement YAML | Low | Different concerns, different storage |
| Triple-VPN coexistence (Proton + Range VPN + Tailscale) | High | Tailscale userspace networking avoids route/kill-switch conflicts. Fallback: LAN-only T3 (no mobile) |
| systemd-resolved restart wipes DNS split | Medium | Document recovery sequence; avoid resolved restarts while VPN chain active |

## 9. Success Criteria

- [ ] Provider switch completes in < 30 seconds with context preserved
- [ ] Operator can trigger failover from phone during range exercise
- [ ] Parallel recon via delegation runs 3+ targets concurrently
- [ ] Mode rules (OPSEC, engagement gate) survive provider switch
- [ ] Health check detects outage within 2 minutes
- [ ] Failback to primary provider preserves full thread history

## 10. PRD Updates Required

- Section 4: Update T3 Code reference from v0.0.40 to v0.1.7+
- Section 4: Update three-layer description with orchestration-v2 capabilities
- Addendum: Replace T3 Code section (line 105-116) with current assessment
- Add FR-H10: Provider failover via T3 Code orchestration (v1.5 scope)
- Add FR-H11: Sub-agent delegation via T3 Code (v2 scope)
