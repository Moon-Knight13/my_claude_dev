# T3 Code v2 — Phased Integration Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add T3 Code v2 as orchestration layer above my_claude_dev. Provider failover, mobile monitoring, multi-project management, sub-agent delegation. Without disrupting current devcontainer workflow.

**Architecture (target state):**

```
Host (Ubuntu 26.06)
├─ T3 Code Desktop (.deb)
│  ├─ Orchestrator (provider switch, delegation, cron)
│  ├─ Tailscale → mobile app
│  └─ Projects: my_claude_dev, tuoni-plugins, others
│
├─ Provider: claude CLI (host install)
│  ├─ ~/.claude/ (modes, hooks, skills — native)
│  └─ MCPs via SSE: range-intel :8101, tuoni :8102, outline :8103
│
├─ Provider: opencode CLI (host install, failover)
│  ├─ Same SSE MCP access
│  └─ OpenRouter / Ollama backend
│
├─ SSE Proxy (supergateway)
│  ├─ :8101 → range-intel (Providentia + GitLab)
│  ├─ :8102 → tuoni-mcp (C2)
│  └─ :8103 → outline-readonly (wiki)
│
├─ VPN → Range (172.21.x.x)
│
└─ Devcontainer (bridge network, #222)
   ├─ Code execution sandbox
   ├─ Untrusted MCPs (rea, hacktricks, mitre, lolbins, obsidian, ollama)
   └─ Egress: SSE ports 8101-8103 to gateway only
```

**Tech Stack:** T3 Code v0.1.7+ (.deb), Claude Code CLI, OpenCode CLI, supergateway (npm), systemd user units

**Spec:** `docs/planning/t3-code-integration-spec.md`

## Global Constraints

- Current devcontainer workflow stays functional throughout. No breaking changes.
- Each phase is independently valuable. Can stop after any phase.
- All host installs are user-level (no root-owned services except .deb).
- Existing `.claude/` config shared via bind mount — host and container see same modes/hooks/skills.
- Host OS: Ubuntu 26.06, Ryzen AI 9 HX 370, 92GB RAM.

## Review Focus

1. **SSE proxy stability:** Range MCPs behind supergateway must handle reconnects, VPN drops, and concurrent requests without losing state.
2. **Hook parity:** Host claude's UserPromptSubmit hooks must fire identically to container claude. Same mode-inject, secret-scan, ctp-bridge behavior.
3. **MCP config divergence:** Host claude uses SSE URLs, container claude uses stdio. Two `.mcp.json` strategies needed — or one config that works for both.
4. **T3 + Tailscale + VPN coexistence:** Tailscale 100.64.0.0/10 range must not conflict with range VPN routing.
5. **Thread state durability:** T3 SQLite survives host reboot, T3 update, and doesn't conflict with engagement YAML.

---

## Phase A: SSE Proxy for Range MCPs (#222)

*This is the critical enabler. Without it, host claude has no range access.
Can be built entirely within current devcontainer workflow — no T3 needed yet.*

### Task A1: Install supergateway on host

**Files:**
- Create: `scripts/host/install-sse-proxy.sh`
- Create: `scripts/host/range-mcp-proxy@.service` (systemd user unit template)

**Interfaces:**
- Consumes: npm (host), range MCP server source code
- Produces: SSE endpoints at :8101, :8102, :8103

- [ ] **Step 1: Research supergateway vs mcp-proxy**

```bash
npm info supergateway version
npm info @anthropic/mcp-proxy version 2>/dev/null
```

Pick one. supergateway is npm, wraps stdio MCP as SSE. Check if it
supports auth tokens on endpoints.

- [ ] **Step 2: Write install script**

Script installs supergateway globally on host, creates systemd user
unit template for each range MCP.

- [ ] **Step 3: Write systemd unit template**

```ini
# range-mcp-proxy@.service
[Unit]
Description=Range MCP SSE Proxy - %i
After=network.target

[Service]
ExecStart=/usr/local/bin/supergateway \
  --stdio "python3 -m %i" \
  --port %I_PORT \
  --auth-token %I_TOKEN
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
```

Actual unit will need per-service port mapping and MCP command.

- [ ] **Step 4: Test one MCP (range-intel) through SSE**

```bash
# Start proxy
supergateway --stdio "python3 -m range_intel_mcp" --port 8101

# Test from another terminal
curl http://127.0.0.1:8101/sse
```

Expected: SSE connection established, MCP handshake works.

- [ ] **Step 5: Test all three MCPs**

Start all three proxies. Verify each responds to SSE connection.

- [ ] **Step 6: Commit**

```bash
git add scripts/host/
git commit -m "feat: SSE proxy scripts for range-facing MCPs (#222)"
```

### Task A2: Configure host claude for SSE MCPs

**Files:**
- Create: `scripts/host/setup-host-claude.sh`

**Interfaces:**
- Consumes: SSE endpoints from A1
- Produces: Host claude with full MCP access via SSE

- [ ] **Step 1: Install claude CLI on host (if not present)**

```bash
npm install -g @anthropic-ai/claude-code
claude auth login
```

- [ ] **Step 2: Create host MCP config**

Host claude needs `.mcp.json` with SSE URLs instead of stdio commands.
Container `.mcp.json` stays unchanged (stdio).

```json
{
  "mcpServers": {
    "range-intel": {
      "type": "sse",
      "url": "http://127.0.0.1:8101/sse"
    },
    "tuoni-mcp": {
      "type": "sse",
      "url": "http://127.0.0.1:8102/sse"
    },
    "outline-readonly": {
      "type": "sse",
      "url": "http://127.0.0.1:8103/sse"
    }
  }
}
```

Determine where this config lives — workspace `.mcp.json` can't have
both SSE and stdio entries. May need environment detection.

- [ ] **Step 3: Test host claude with SSE MCPs**

```bash
cd ~/repos/my_claude_dev
claude
# In session: "Query range-intel for target list"
```

Expected: Host claude reaches range-intel via SSE proxy.

- [ ] **Step 4: Verify hooks fire on host**

Host claude reads same `~/.claude/` and workspace `.claude/` config.
Hooks should fire identically.

```bash
# In claude session: "/mode red-team"
# Verify mode-inject.sh fires
```

- [ ] **Step 5: Commit**

```bash
git add scripts/host/
git commit -m "feat: host claude SSE MCP config for T3 integration"
```

---

## Phase B: T3 Code Install + Basic Validation

*Only after Phase A proves host claude works with SSE MCPs.*

### Task B1: Install T3 Code desktop on host

**Files:**
- Create: `scripts/host/install-t3.sh`

- [ ] **Step 1: Download and install .deb**

```bash
# Download latest from GitHub releases
wget https://github.com/pingdotgg/t3code/releases/latest/download/T3-Code-amd64.deb
sudo apt install ./T3-Code-amd64.deb
```

- [ ] **Step 2: Verify T3 starts**

```bash
t3 --version
t3
```

Expected: T3 server starts, desktop app opens or web UI accessible.

- [ ] **Step 3: Configure providers**

In T3 Settings → Providers:
- Enable Claude Code, set binary path if needed
- Enable OpenCode, set binary path if needed
- Verify both show as available

- [ ] **Step 4: Create first thread**

In T3 UI:
1. Add my_claude_dev as project (workspace path)
2. Create thread with Claude Code provider
3. Send: "What mode is active? List available MCP tools."

Expected: Claude Code runs, hooks fire, MCPs accessible via SSE.

- [ ] **Step 5: Commit installer**

```bash
git add scripts/host/install-t3.sh
git commit -m "feat: T3 Code desktop installer for host"
```

### Task B2: Provider switch validation

**Interfaces:**
- Consumes: Running T3 thread from B1
- Produces: Go/no-go on provider switching

- [ ] **Step 1: Build context (3-4 turns on Claude Code)**

Send messages that build conversational context about a real task.

- [ ] **Step 2: Switch to OpenCode**

Use T3 provider switcher. Observe:
- Context handoff generation (time, content)
- OpenCode session start
- Whether OpenCode understands prior context

- [ ] **Step 3: Switch back to Claude Code**

Observe delta summary of OpenCode runs. Verify round-trip.

- [ ] **Step 4: Document results**

Record pass/fail for each gate in results template.

### Task B3: Mobile + Tailscale setup

- [ ] **Step 1: Configure Tailscale HTTPS**

```bash
t3 serve --tailscale-serve
```

Verify laptop appears as environment on tailnet.

- [ ] **Step 2: Install T3 mobile app**

Add environment via pairing link. Verify thread list visible.

- [ ] **Step 3: Send message from phone**

Send a task from mobile, verify it executes on host claude.

- [ ] **Step 4: Monitor from phone**

Start a task from desktop, switch to phone, watch progress.

---

## Phase C: Multi-Project + Delegation

*Only after Phase B proves T3 works for single-project use.*

### Task C1: Add second project to T3

- [ ] Add tuoni-plugins as separate T3 project
- [ ] Create thread, verify independent workspace
- [ ] Verify different `.claude/` config per project (if applicable)

### Task C2: Sub-agent delegation

- [ ] Test `delegate_task` from my_claude_dev thread
- [ ] Verify child thread runs with correct workspace
- [ ] Test cross-provider delegation (Claude parent → OpenCode child)

---

## Non-Disruption Strategy

**How to test without slowing down current work:**

### Principle: Parallel tracks, not sequential blocking

```
Track 1 (unchanged): Devcontainer claude — all current work continues here
Track 2 (new):       Host claude via T3 — validation and gradual adoption
```

### Phase A (SSE proxy): Zero disruption

- SSE proxy runs on host as systemd user service
- Container workflow unchanged — still uses stdio MCPs
- Build proxy scripts in a worktree, test on host separately
- Container doesn't know or care about SSE proxy existence

### Phase B (T3 install): Zero disruption

- T3 desktop app is a separate application on host
- Does not modify container, devcontainer.json, or .claude/ config
- Host claude is a separate CLI install — doesn't affect container claude
- Can use T3 for new tasks while continuing container claude for active work

### Phase C (adoption): Gradual migration

- Start NEW work in T3 threads
- Continue ACTIVE work in container claude
- Migrate when a natural breakpoint occurs (engagement ends, PR merges)
- Container claude stays available as fallback indefinitely

### What runs where during transition

| Work type | Where | Why |
|---|---|---|
| Active red-team engagement | Container claude | Don't disrupt mid-engagement |
| New code review | T3 + host claude | Low-risk validation of T3 |
| tuoni-plugins dev | T3 + host claude | Independent repo, good test |
| Platform-ops maintenance | Either | Pick per-task |
| Urgent range work | Container claude | Known-good path |
| Mobile monitoring | T3 mobile app | New capability, no alternative |

### Time investment

| Phase | Effort | Can parallel with | Blocks |
|---|---|---|---|
| A: SSE proxy | 2-3 hours | Any current work | Phase B MCP access |
| B: T3 + validation | 1-2 hours | Any current work | Phase C |
| C: Multi-project | 1 hour | Any current work | Nothing |

Total: ~5 hours spread across multiple sessions. No session is blocked
waiting for T3 work. Every session can still use container claude for
real work.

---

## Results Template

```markdown
# T3 Code Integration Results

## Phase A: SSE Proxy
| Gate | Result | Notes |
|---|---|---|
| supergateway installs | | |
| range-intel via SSE | | |
| tuoni-mcp via SSE | | |
| outline-readonly via SSE | | |
| Host claude with SSE MCPs | | |
| Hooks fire on host | | |

## Phase B: T3 Code
| Gate | Result | Notes |
|---|---|---|
| T3 desktop installs | | |
| T3 detects claude | | |
| T3 detects opencode | | |
| Thread + task works | | |
| Provider switch works | | |
| Context handoff quality | | |
| Round-trip switch | | |
| Tailscale + mobile | | |

## Phase C: Multi-Project
| Gate | Result | Notes |
|---|---|---|
| Second project works | | |
| delegate_task works | | |
| Cross-provider delegation | | |

## Decision
[ ] ADOPT — T3 as primary interface
[ ] PARTIAL — T3 for orchestration/mobile only, container for ops
[ ] REJECT — lightweight failover script instead
```
