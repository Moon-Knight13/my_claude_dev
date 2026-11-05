# T3 Code v2 Phase 0 Validation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Validate that T3 Code v2 can orchestrate Claude Code and OpenCode in our devcontainer setup, with working provider switching and context handoff.

**Architecture:** T3 Code server runs inside the devcontainer (not on host) because provider CLIs live there. Container already uses `--network=host`, so T3's web UI is accessible from host browser at `127.0.0.1:<port>`. T3 wraps providers; our `.claude/` config (modes, hooks, skills, MCPs) is unchanged — providers read it as usual.

**Tech Stack:** T3 Code v0.1.7+, Claude Code CLI 2.x, OpenCode CLI, Node.js 24

**Spec:** `docs/planning/t3-code-integration-spec.md`

## Global Constraints

- Phase 0 only. No production integration. All work is reversible.
- T3 Code installed in container, not baked into Dockerfile. Removable with `npm uninstall -g t3`.
- No changes to existing `.claude/` config, hooks, or skills.
- No changes to devcontainer.json.
- Host OS: Ubuntu 26.06, Ryzen AI 9 HX 370, 92GB RAM.

## Review Focus

1. **Provider visibility:** T3 must detect both `claude` and `opencode` CLIs in container PATH — if not, entire integration is blocked.
2. **Hook survival:** UserPromptSubmit hooks (mode-inject, secret-scan) must fire when T3 wraps Claude Code session — if not, mode system breaks.
3. **MCP conflict:** T3 injects its `t3-code` MCP endpoint into providers. Must not collide with our existing MCP servers in `.mcp.json`.
4. **Network assumption:** `--network=host` means T3's ports are directly accessible from host. If container networking changes to bridge (#222), T3 ports need forwarding.
5. **State isolation:** T3's SQLite thread store must not interfere with engagement YAML, `.active-mode`, or `.claude/` config.

---

### Task 1: Install T3 Code in Container

**Files:**
- Create: `scripts/install-t3.sh` (reversible installer)

**Interfaces:**
- Consumes: Node.js 24, npm (already in container)
- Produces: `t3` CLI in PATH, T3 server runnable

- [ ] **Step 1: Write installer script**

```bash
#!/usr/bin/env bash
# scripts/install-t3.sh — reversible T3 Code install for validation
set -euo pipefail

echo "Installing T3 Code..."
npm install -g t3@latest

echo "Verifying..."
t3 --version

echo "T3 Code installed. Run 't3' to start server."
echo "Uninstall: npm uninstall -g t3"
```

- [ ] **Step 2: Run installer on host terminal**

The user runs this from host terminal inside the devcontainer:

```bash
bash scripts/install-t3.sh
```

Expected: `t3 --version` prints version >= 0.1.7.

- [ ] **Step 3: Verify T3 starts**

```bash
t3 --help
```

Expected: Help output showing available commands including `service`, `update`.

- [ ] **Step 4: Commit**

```bash
git add scripts/install-t3.sh
git commit -m "feat: add reversible T3 Code installer for Phase 0 validation"
```

---

### Task 2: Install OpenCode in Container

**Files:**
- Modify: `scripts/install-t3.sh` (add OpenCode install)

**Interfaces:**
- Consumes: npm or standalone installer
- Produces: `opencode` CLI in PATH, authenticated or auth-ready

- [ ] **Step 1: Check OpenCode install method**

```bash
# Try npm
npm info opencode version 2>/dev/null
# Or check if standalone installer exists
curl -fsSL https://opencode.ai/install.sh --head 2>/dev/null
```

Determine correct install method. OpenCode may need OpenRouter API key
for model access.

- [ ] **Step 2: Install OpenCode**

```bash
npm install -g opencode
# or
curl -fsSL https://opencode.ai/install.sh | bash
```

Expected: `opencode --version` prints version.

- [ ] **Step 3: Configure OpenCode auth**

```bash
opencode auth login
# or set OPENROUTER_API_KEY in .env
```

Expected: OpenCode can reach at least one model (local Ollama or OpenRouter).

- [ ] **Step 4: Verify OpenCode runs basic task**

```bash
echo "What is 2+2?" | opencode --no-interactive 2>/dev/null
```

Expected: Response from model. Confirms provider works standalone.

- [ ] **Step 5: Commit updated installer**

```bash
git add scripts/install-t3.sh
git commit -m "feat: add OpenCode to T3 validation installer"
```

---

### Task 3: T3 Server + Provider Discovery

**Files:**
- Create: `scripts/t3-validate.sh` (validation gate script)

**Interfaces:**
- Consumes: `t3` CLI, `claude` CLI, `opencode` CLI
- Produces: Validation report — PASS/FAIL per gate

- [ ] **Step 1: Start T3 server**

```bash
t3
```

Expected: Server starts, prints URL (likely `http://127.0.0.1:3000`).
Web UI accessible from host browser at that URL.

- [ ] **Step 2: Check provider discovery**

In T3 web UI or via CLI:
- Claude Code should appear as available provider
- OpenCode should appear as available provider

If either is missing: check PATH visibility, check T3 provider detection
docs. This is the primary gate — if T3 can't see providers, Phase 0 fails.

- [ ] **Step 3: Create thread with Claude Code provider**

In T3 UI:
1. Create new thread
2. Select Claude Code as provider
3. Set project workspace to `/workspace`
4. Send: "Read CLAUDE.md and tell me what mode is active"

Expected: Claude Code runs, reads `.claude/.active-mode`, reports mode.
This confirms T3 wraps Claude Code and our config is visible.

- [ ] **Step 4: Verify hooks fire**

Check that mode-inject.sh fired during step 3:

```bash
# Look for hook evidence in Claude Code output
# The response should include mode context if hook fired
# Also check for secret-scan hook evidence
```

Expected: Response includes mode awareness (system-prompt.md content
was injected). If not, hooks broke under T3 wrapper.

- [ ] **Step 5: Verify MCP servers accessible**

In T3 thread, send: "List available MCP tools from range-intel"

Expected: Claude Code can reach range-intel MCP (if range connected).
If not connected, send: "What MCP servers are configured in .mcp.json?"
and verify it reads the config.

- [ ] **Step 6: Write validation gate script**

```bash
#!/usr/bin/env bash
# scripts/t3-validate.sh — Phase 0 validation gates
set -euo pipefail

PASS=0; FAIL=0
gate() {
  if "$@" >/dev/null 2>&1; then
    echo "PASS: $1"; ((PASS++))
  else
    echo "FAIL: $1"; ((FAIL++))
  fi
}

gate t3 --version
gate claude --version
gate opencode --version
gate test -f /workspace/.claude/.active-mode
gate test -d /workspace/.claude/modes/base

echo "---"
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ] && echo "ALL GATES PASSED" || echo "GATES FAILED — check output"
```

- [ ] **Step 7: Commit**

```bash
git add scripts/t3-validate.sh
git commit -m "feat: add T3 Phase 0 validation gate script"
```

---

### Task 4: Provider Switch — Claude to OpenCode

**Files:**
- None (manual validation in T3 UI)

**Interfaces:**
- Consumes: Running T3 thread from Task 3
- Produces: Validation evidence — context handoff worked or failed

- [ ] **Step 1: Run multi-turn conversation on Claude Code**

In T3 thread from Task 3, send 3-4 messages building context:

1. "Read docs/planning/t3-code-integration-spec.md and summarize the open questions"
2. "Which open question is highest risk?"
3. "What would we need to change in devcontainer.json if we switch to bridge networking?"

Expected: Claude Code maintains conversation context across turns.

- [ ] **Step 2: Trigger provider switch to OpenCode**

In T3 UI:
1. Find provider switch control (model switcher or thread settings)
2. Switch from Claude Code to OpenCode
3. T3 should generate context handoff summary

Expected: T3 shows handoff being generated. Note what's in the summary:
does it capture goals, decisions, files discussed?

- [ ] **Step 3: Continue conversation on OpenCode**

Send: "Based on our prior discussion, what was the highest risk open question?"

Expected: OpenCode has context from handoff summary and can answer
coherently. Quality will be lower than Claude, but context should
be preserved.

- [ ] **Step 4: Switch back to Claude Code**

1. Switch provider back to Claude Code
2. Send: "What did we discuss while on the other provider?"

Expected: Claude Code gets delta summary of OpenCode runs.
Context preserved across round-trip.

- [ ] **Step 5: Document findings**

Record in validation notes:
- Did provider switch work? (Y/N)
- Was context handoff generated? (Y/N)
- What was in the handoff? (list contents)
- Did destination provider understand context? (Y/N)
- How long did switch take? (seconds)
- Did hooks fire on resumed Claude Code session? (Y/N)
- Any errors or warnings? (exact text)

---

### Task 5: Evaluate and Document Results

**Files:**
- Create: `docs/planning/t3-code-phase0-results.md`

**Interfaces:**
- Consumes: Results from Tasks 1-4
- Produces: Go/no-go decision for Phase 1

- [ ] **Step 1: Fill results template**

```markdown
# T3 Code Phase 0 Results

Date: 2026-11-XX
T3 Version: X.X.X
Claude Code Version: X.X.X
OpenCode Version: X.X.X

## Gate Results

| Gate | Result | Notes |
|---|---|---|
| T3 installs in container | | |
| T3 detects Claude Code | | |
| T3 detects OpenCode | | |
| Thread creation works | | |
| .claude/ config visible | | |
| Hooks fire under T3 | | |
| MCP servers accessible | | |
| Provider switch works | | |
| Context handoff generated | | |
| Destination understands context | | |
| Round-trip switch works | | |
| Switch time acceptable | | |

## Open Questions Answered

1. T3 + devcontainer: [answer]
2. MCP passthrough: [answer]
3. Hook compatibility: [answer]
4. Config isolation: [answer]
5. OpenCode skill gap: [answer]
6. Provider switch API: [answer]

## Decision

[ ] GO — proceed to Phase 1 (manual failover)
[ ] NO-GO — reason: ___
[ ] PIVOT — alternative approach: ___
```

- [ ] **Step 2: Write decision rationale**

Based on gate results, write 3-5 sentences on whether T3 Code v2
adds enough value over a lightweight failover script to justify
the dependency and UX change.

- [ ] **Step 3: Commit results**

```bash
git add docs/planning/t3-code-phase0-results.md
git commit -m "docs: T3 Code Phase 0 validation results"
```

---

## Execution Notes

**What operator does on host:**
- Open host browser to T3 web UI after Task 3 Step 1
- Interact with T3 UI for Tasks 3-4 (thread creation, provider switching)
- Approve any auth prompts for providers

**What can be scripted from container:**
- Tasks 1-2 (install T3, install OpenCode)
- Task 3 Step 6 (validation gate script)
- Task 5 (results document)

**What needs manual interaction:**
- Task 3 Steps 1-5 (T3 UI interaction, verifying visual output)
- Task 4 all steps (provider switching is UI-driven)

**Estimated time:** 1-2 hours for full validation including install.

**Abort criteria:** If Task 3 Step 2 fails (T3 can't see providers), stop. Research T3 provider detection for containerized CLIs before retrying.
