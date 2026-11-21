# HQ Phase 0: Safety Hooks Cross-Repo — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy safety gates, dispatch discipline, and behavioral rules
to `~/.claude/` (user-level) so every Claude Code session in every repo
gets protection — not just my_claude_dev.

**Architecture:** Copy 3 existing safety hooks (rewritten for `$HOME`
paths with project-level double-fire detection) + 1 new hook to
`~/.claude/hooks/`. A `deploy-hq.sh` script automates the deploy.
Caveman is already global (plugin). No files moved from project-level.

**Tech Stack:** Bash hooks, JSON (settings.json), YAML (issue templates),
Markdown (system prompt additions). No new dependencies.

**Spec:** `docs/superpowers/specs/2026-11-20-hq-restructure-design.md`
— Phase 0 section + security prerequisites.

## Global Constraints

- Hooks must work with `$CLAUDE_PROJECT_DIR` unset (user-level hooks
  outside any project). Fall back to `$PWD` or skip gracefully.
- Hooks must NOT double-fire when project-level equivalent exists.
  Detection: check `$CLAUDE_PROJECT_DIR/.claude/hooks/<hook-name>` exists.
- No secrets in deployed files. All hooks use `$HOME` paths, never
  hardcoded absolute paths.
- `chmod 700 ~/.claude/hooks/` and `chmod 755` on each hook file.
- Existing CI tests must remain green. No project-level files modified
  except S2 fix and behavioral rule additions to system prompts.
- Public repo: no IPs, hostnames, usernames in committed code.

## Review Focus

1. **Hook without CLAUDE_PROJECT_DIR:** User-level hook runs in a repo
   with no `.claude/` dir. Must not crash on missing path. Expect: hook
   skips gracefully or uses `$HOME` fallback.
2. **Double-fire in my_claude_dev:** Both user-level and project-level
   hook fire. Expect: user-level detects project-level and exits early
   (zero output).
3. **deploy-hq.sh on fresh machine:** `~/.claude/hooks/` doesn't exist.
   Expect: script creates directory, sets permissions, deploys hooks.
4. **Stale deploy:** Hook updated in repo but not re-deployed. Expect:
   `--verify-only` detects version mismatch and reports.
5. **CTP guard-stack at user level:** `pretooluse-ctp.sh` sources
   `load-env.sh` relative to itself. At `~/.claude/hooks/`, path breaks.
   Expect: fallback chain resolves to `$HOME/.local/lib/ctp-bridge/`
   or degrades with warning, never crashes.

---

### Task 1: Security prerequisites

**Files:**
- Modify: `.claude/hooks/session-end-sync.sh:65` (S2 hardcoded path fix)
- Audit: `.mcp.json`, `.mcp-platform-ops.json` (S5 wrapper check)

**Interfaces:**
- Consumes: nothing
- Produces: clean repo state for remaining tasks

- [ ] **Step 1: Fix hardcoded path in session-end-sync.sh**

Replace line 65:
```bash
# BEFORE:
MEMORY_DIR="$HOME/.claude/projects/-home-chris-Documents-my-claude-dev/memory"
# AFTER:
MEMORY_DIR="$HOME/.claude/projects/-$(echo "${CLAUDE_PROJECT_DIR:-$PWD}" | tr '/' '-' | sed 's/^-//')/memory"
```

- [ ] **Step 2: Verify no other hardcoded user paths exist**

Run:
```bash
grep -rn '/home/chris\|/Users/' .claude/ scripts/ --include="*.sh" --include="*.json" | grep -v '.git/' | grep -v 'node_modules'
```
Expected: only the line just fixed (now gone) or test fixtures.

- [ ] **Step 3: Audit MCP wrapper usage (S5)**

```bash
# Check every MCP server command in .mcp.json and .mcp-platform-ops.json
# Verify each routes through scripts/mcp-wrapper.sh
python3 -I -c "
import json
for f in ['.mcp.json', '.mcp-platform-ops.json']:
    with open(f) as fh:
        cfg = json.load(fh)
    servers = cfg.get('mcpServers', {})
    for name, s in servers.items():
        cmd = ' '.join(s.get('command', []) + s.get('args', [])[:2])
        wrapper = 'mcp-wrapper' in cmd
        print(f'{f}: {name}: wrapper={wrapper} cmd={cmd[:80]}')
"
```
Expected: all servers route through `mcp-wrapper.sh`. Document any exceptions.

- [ ] **Step 4: Commit**

```bash
git add .claude/hooks/session-end-sync.sh
git commit -m "$(cat <<'EOF'
fix(security): remove hardcoded user path from session-end-sync (S2)

Derive memory directory dynamically from CLAUDE_PROJECT_DIR instead of
hardcoding absolute path that leaks operator username in public repo.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Verify user-level hook environment

**Files:**
- Create: `scripts/tests/test-user-level-hooks.sh`

**Interfaces:**
- Consumes: nothing
- Produces: verified knowledge of which env vars user-level hooks receive
  (gates Task 3-4 implementation)

- [ ] **Step 1: Write env var probe test**

```bash
#!/usr/bin/env bash
# test-user-level-hooks.sh — verify which env vars user-level hooks receive
set -euo pipefail
PASS=0; FAIL=0
ok()   { echo "  PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

# Simulate user-level hook environment (no CLAUDE_PROJECT_DIR)
_run_without_project_dir() {
    local hook="$1"
    env -u CLAUDE_PROJECT_DIR bash -c "echo '{}' | bash '$hook' 2>/dev/null; echo EXIT:\$?"
}

# Test: hooks must not crash without CLAUDE_PROJECT_DIR
for hook in master-dispatch-guard.sh pretooluse-ctp.sh tuoni-secret-guard.sh; do
    HOOK_PATH="$PROJECT_DIR/.claude/hooks/$hook"
    [[ -x "$HOOK_PATH" ]] || { fail "$hook not found"; continue; }
    result="$(_run_without_project_dir "$HOOK_PATH")"
    if echo "$result" | grep -q "EXIT:0\|EXIT:2"; then
        ok "$hook survives without CLAUDE_PROJECT_DIR"
    else
        fail "$hook crashes without CLAUDE_PROJECT_DIR: $result"
    fi
done
```

- [ ] **Step 2: Run test to establish baseline**

```bash
bash scripts/tests/test-user-level-hooks.sh
```
Expected: identifies which hooks crash without `$CLAUDE_PROJECT_DIR`.
This informs how much rewriting Task 3 needs.

- [ ] **Step 3: Add CTP guard-stack resolution test**

```bash
# Append to test-user-level-hooks.sh:
# Test: pretooluse-ctp.sh resolves guard-stack at user level
# When deployed to ~/.claude/hooks/, the hook can no longer source
# load-env.sh relative to itself. It must resolve via:
#   1. $HOME/.local/lib/ctp-bridge/guard-stack.sh
#   2. $CLAUDE_PROJECT_DIR/scripts/lib/ (if set)
#   3. Degrade with warning (never crash)
_test_ctp_guardstack_resolution() {
    local hook="$PROJECT_DIR/.claude/hooks/pretooluse-ctp.sh"
    # Run without project dir — must not crash
    result="$(env -u CLAUDE_PROJECT_DIR bash -c "echo '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls\"}}' | bash '$hook' 2>&1; echo EXIT:\$?")"
    exit_code="$(echo "$result" | grep -o 'EXIT:[0-9]*' | cut -d: -f2)"
    if [[ "$exit_code" == "0" || "$exit_code" == "2" ]]; then
        ok "pretooluse-ctp.sh guard-stack resolves or degrades gracefully"
    else
        fail "pretooluse-ctp.sh crashes on guard-stack resolution: exit $exit_code"
    fi
}
_test_ctp_guardstack_resolution
```

- [ ] **Step 4: Commit**

```bash
git add scripts/tests/test-user-level-hooks.sh
git commit -m "$(cat <<'EOF'
test: add user-level hook environment verification

Tests which hooks survive without CLAUDE_PROJECT_DIR, establishing
baseline for HQ Phase 0 user-level hook deployment. Includes explicit
CTP guard-stack path resolution test (S4).

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Rewrite safety hooks for user-level deployment

**Files:**
- Create: `scripts/deploy/hooks/master-dispatch-guard.sh`
- Create: `scripts/deploy/hooks/pretooluse-ctp.sh`
- Create: `scripts/deploy/hooks/tuoni-secret-guard.sh`

User-level copies live in `scripts/deploy/hooks/` (source of truth in
repo, deployed to `~/.claude/hooks/` by deploy-hq.sh). Project-level
originals in `.claude/hooks/` remain unchanged.

**Interfaces:**
- Consumes: Task 2 results (which env vars are available)
- Produces: 3 hook scripts ready for user-level deployment

- [ ] **Step 1: Write test for double-fire prevention**

```bash
#!/usr/bin/env bash
# test-double-fire-prevention.sh
set -euo pipefail
PASS=0; FAIL=0
ok()   { echo "  PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Simulate: project-level hook exists at CLAUDE_PROJECT_DIR
mkdir -p "$TMP/project/.claude/hooks"
touch "$TMP/project/.claude/hooks/master-dispatch-guard.sh"

# User-level hook should detect project-level and exit early (no output)
_test_double_fire() {
    local hook="$1"
    result="$(CLAUDE_PROJECT_DIR="$TMP/project" \
        echo '{"tool_name":"Agent","tool_input":{"subagent_type":"general"}}' | \
        bash "$hook" 2>/dev/null)" || true
    if [[ -z "$result" ]]; then
        ok "$hook exits early when project-level exists (no output)"
    else
        fail "$hook produces output despite project-level existing: $result"
    fi
}
```

- [ ] **Step 2: Run test to verify it fails (hooks don't exist yet)**

```bash
bash scripts/tests/test-double-fire-prevention.sh
```
Expected: FAIL — hooks not found.

- [ ] **Step 3: Implement user-level master-dispatch-guard.sh**

Rewrite `.claude/hooks/master-dispatch-guard.sh` with:
1. Double-fire detection at top:
   ```bash
   HOOK_NAME="$(basename "${BASH_SOURCE[0]}")"
   if [[ -n "${CLAUDE_PROJECT_DIR:-}" && \
         -x "$CLAUDE_PROJECT_DIR/.claude/hooks/$HOOK_NAME" ]]; then
       exit 0  # project-level handles it
   fi
   ```
2. Replace `$CLAUDE_PROJECT_DIR` paths with `$HOME/.claude/` for
   `.active-mode` and `.mode-overrides/` reads.
3. Graceful skip when neither location has `.active-mode`.

- [ ] **Step 4: Implement user-level pretooluse-ctp.sh**

Rewrite `.claude/hooks/pretooluse-ctp.sh` with:
1. Same double-fire detection pattern.
2. Guard-stack resolution chain: try `$HOME/.local/lib/ctp-bridge/`
   then `$CLAUDE_PROJECT_DIR/scripts/lib/` then skip with warning.
3. `.ctp-bridge.conf` read from `$HOME/` when no project-level exists.

- [ ] **Step 5: Implement user-level tuoni-secret-guard.sh**

Rewrite `.claude/hooks/tuoni-secret-guard.sh` with:
1. Same double-fire detection pattern.
2. `$HOME/.claude/` paths for any config reads.
3. Graceful skip when tuoni env vars are unset.

- [ ] **Step 6: Run double-fire prevention test**

```bash
bash scripts/tests/test-double-fire-prevention.sh
```
Expected: all 3 hooks PASS double-fire detection.

- [ ] **Step 7: Run user-level environment test**

```bash
bash scripts/tests/test-user-level-hooks.sh
```
Expected: all 3 user-level hooks survive without `$CLAUDE_PROJECT_DIR`.

- [ ] **Step 8: Run existing test suite to verify no breakage**

```bash
bash scripts/tests/run-all.sh
```
Expected: all existing tests PASS (project-level hooks unchanged).

- [ ] **Step 9: Commit**

```bash
git add scripts/deploy/hooks/ scripts/tests/test-double-fire-prevention.sh
git commit -m "$(cat <<'EOF'
feat(hq): add user-level safety hooks for cross-repo deployment

Three safety hooks rewritten for ~/.claude/hooks/ deployment:
- master-dispatch-guard.sh (dispatch discipline)
- pretooluse-ctp.sh (ctp-bridge safety gate)
- tuoni-secret-guard.sh (secret protection)

Each detects project-level equivalent and exits early to prevent
double-firing. All survive without CLAUDE_PROJECT_DIR.

Part of HQ Phase 0: safety hooks cross-repo.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Create dispatch-wakeup-enforcer hook

**Files:**
- Create: `scripts/deploy/hooks/dispatch-wakeup-enforcer.sh`
- Create: `scripts/tests/test-wakeup-enforcer.sh`

**Interfaces:**
- Consumes: Task 3 double-fire detection pattern
- Produces: PostToolUse hook that nudges master to use ScheduleWakeup

- [ ] **Step 1: Write failing test**

```bash
#!/usr/bin/env bash
# test-wakeup-enforcer.sh
set -euo pipefail
PASS=0; FAIL=0
ok()   { echo "  PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

HOOK="scripts/deploy/hooks/dispatch-wakeup-enforcer.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Test 1: fires after delegate_task in base mode
echo "base" > "$TMP/.active-mode"
result="$(HOME="$TMP" CLAUDE_PROJECT_DIR="" \
    printf '{"tool_name":"mcp__t3-code__delegate_task","tool_input":{}}' | \
    bash "$HOOK" 2>/dev/null)" || true
echo "$result" | grep -q "ScheduleWakeup" && ok "nudge after delegate_task" || fail "no nudge"

# Test 2: does NOT fire in child thread (has mode override)
mkdir -p "$TMP/.claude/.mode-overrides"
echo "red-team" > "$TMP/.claude/.mode-overrides/test-session"
result="$(HOME="$TMP" CLAUDE_CODE_SESSION_ID="test-session" \
    printf '{"tool_name":"mcp__t3-code__delegate_task","tool_input":{}}' | \
    bash "$HOOK" 2>/dev/null)" || true
[[ -z "$result" ]] && ok "silent in child thread" || fail "fires in child thread"

# Test 3: does NOT fire for non-dispatch tools
result="$(HOME="$TMP" CLAUDE_PROJECT_DIR="" \
    printf '{"tool_name":"Bash","tool_input":{}}' | \
    bash "$HOOK" 2>/dev/null)" || true
[[ -z "$result" ]] && ok "silent for non-dispatch tool" || fail "fires for Bash"
```

- [ ] **Step 2: Run test to verify it fails**

```bash
bash scripts/tests/test-wakeup-enforcer.sh
```
Expected: FAIL — hook not found.

- [ ] **Step 3: Implement dispatch-wakeup-enforcer.sh**

PostToolUse hook:
1. Read tool_name from stdin JSON.
2. Only fire for `delegate_task|t3_thread_launch|create_threads`.
3. Check if master session (base mode, no mode-override).
4. Emit notification JSON (not deny):
   ```json
   {"hookSpecificOutput":{"hookEventName":"PostToolUse",
    "notification":"Thread dispatched. Use ScheduleWakeup to monitor completion. Do not wait for user prompt."}}
   ```
5. Same double-fire detection pattern as Task 3.

- [ ] **Step 4: Run test to verify it passes**

```bash
bash scripts/tests/test-wakeup-enforcer.sh
```
Expected: all 3 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/deploy/hooks/dispatch-wakeup-enforcer.sh scripts/tests/test-wakeup-enforcer.sh
git commit -m "$(cat <<'EOF'
feat(hq): add dispatch-wakeup-enforcer PostToolUse hook

Soft nudge after T3 thread dispatch in master sessions: reminds
agent to use ScheduleWakeup for monitoring. Notification only,
not a deny. Silent in child threads.

Part of HQ Phase 0: dispatch discipline cross-repo.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Create deploy-hq.sh and settings.json

**Files:**
- Create: `scripts/deploy-hq.sh`
- Create: `scripts/deploy/settings-phase0.json`
- Create: `scripts/tests/test-deploy-hq.sh`

**Interfaces:**
- Consumes: Task 3 + 4 hooks in `scripts/deploy/hooks/`
- Produces: deploy script that populates `~/.claude/` from repo

- [ ] **Step 1: Write failing test**

```bash
#!/usr/bin/env bash
# test-deploy-hq.sh — test deploy to temp HOME
set -euo pipefail
PASS=0; FAIL=0
ok()   { echo "  PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Deploy to temp HOME
HOME="$TMP" bash scripts/deploy-hq.sh --dry-run 2>/dev/null
# dry-run should report what it would do without changing anything
[[ ! -d "$TMP/.claude/hooks" ]] && ok "dry-run doesn't create dirs" || fail "dry-run created dirs"

# Real deploy
HOME="$TMP" bash scripts/deploy-hq.sh
[[ -d "$TMP/.claude/hooks" ]] && ok "hooks dir created" || fail "hooks dir missing"
[[ "$(stat -c %a "$TMP/.claude/hooks" 2>/dev/null)" == "700" ]] && ok "hooks dir 700" || fail "hooks dir perms wrong"

# All hooks present and executable
for hook in master-dispatch-guard.sh pretooluse-ctp.sh tuoni-secret-guard.sh dispatch-wakeup-enforcer.sh; do
    [[ -x "$TMP/.claude/hooks/$hook" ]] && ok "$hook deployed" || fail "$hook missing"
done

# settings.json valid JSON
python3 -I -c "import json; json.load(open('$TMP/.claude/settings.json'))" 2>/dev/null \
    && ok "settings.json valid JSON" || fail "settings.json invalid"

# No secrets in deployed files
count=$(grep -rl 'TOKEN\|SECRET\|PASSWORD' "$TMP/.claude/hooks/" 2>/dev/null | wc -l)
[[ "$count" -eq 0 ]] && ok "no secrets in hooks" || fail "secrets found in hooks"

# No hardcoded user paths
count=$(grep -rl '/home/chris\|/Users/' "$TMP/.claude/hooks/" 2>/dev/null | wc -l)
[[ "$count" -eq 0 ]] && ok "no hardcoded paths" || fail "hardcoded paths found"

# Caveman flag
[[ -f "$TMP/.claude/.caveman-enabled" ]] && ok "caveman flag created" || fail "caveman flag missing"
```

- [ ] **Step 2: Run test to verify it fails**

```bash
bash scripts/tests/test-deploy-hq.sh
```
Expected: FAIL — deploy-hq.sh not found.

- [ ] **Step 3: Create settings-phase0.json**

Minimal user-level hook wiring. Hooks reference `~/.claude/hooks/` paths:

```json
{
  "_comment": "HQ Phase 0: user-level safety hooks. Deployed by deploy-hq.sh.",
  "hooks": {
    "UserPromptSubmit": [],
    "PreToolUse": [
      {
        "matcher": "Agent",
        "hooks": [{"type": "command", "command": "$HOME/.claude/hooks/master-dispatch-guard.sh"}]
      },
      {
        "matcher": "Bash|Read|Write|Edit",
        "hooks": [{"type": "command", "command": "$HOME/.claude/hooks/pretooluse-ctp.sh"}]
      },
      {
        "matcher": "Bash",
        "hooks": [{"type": "command", "command": "$HOME/.claude/hooks/tuoni-secret-guard.sh"}]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "mcp__t3-code__delegate_task|mcp__t3-code__t3_thread_launch|mcp__t3-code__create_threads",
        "hooks": [{"type": "command", "command": "$HOME/.claude/hooks/dispatch-wakeup-enforcer.sh"}]
      }
    ]
  }
}
```

- [ ] **Step 4: Implement deploy-hq.sh**

```bash
#!/usr/bin/env bash
# deploy-hq.sh — deploy HQ Phase 0 hooks to ~/.claude/
# Usage: deploy-hq.sh [--dry-run] [--verify-only]
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="$HOME/.claude"
HOOKS_SRC="$REPO_DIR/scripts/deploy/hooks"
SETTINGS_SRC="$REPO_DIR/scripts/deploy/settings-phase0.json"
```

Logic:
1. Parse flags (`--dry-run`, `--verify-only`).
2. If `--verify-only`: check deployed state matches source, report.
3. Create `$TARGET/hooks/` with `chmod 700`.
4. Copy each hook from `$HOOKS_SRC/`, `chmod 755`.
5. Merge `settings-phase0.json` into `$TARGET/settings.json`:
   - If no existing settings.json: copy directly.
   - If existing: merge `hooks` key only, preserve all other keys.
   - Use python3 for JSON merge (jq may not be installed).
6. Create `$TARGET/.caveman-enabled` flag.
7. Verify: all hooks executable, settings.json valid JSON.
8. Print summary + kill switch:
   ```
   ✓ Hooks deployed to ~/.claude/hooks/
   Kill switch: rm -rf ~/.claude/hooks/
     Removes ALL user-level hooks. Sessions return to project-level only.
     Re-run deploy-hq.sh to redeploy after fixing.
   ```

- [ ] **Step 5: Run test to verify it passes**

```bash
bash scripts/tests/test-deploy-hq.sh
```
Expected: all tests PASS.

- [ ] **Step 6: Run full test suite**

```bash
bash scripts/tests/run-all.sh
```
Expected: all existing + new tests PASS.

- [ ] **Step 7: Commit**

```bash
git add scripts/deploy-hq.sh scripts/deploy/settings-phase0.json scripts/tests/test-deploy-hq.sh
git commit -m "$(cat <<'EOF'
feat(hq): add deploy-hq.sh for Phase 0 user-level hook deployment

Deploys safety hooks + settings.json to ~/.claude/ with:
- chmod 700 hooks directory
- JSON merge preserving existing user settings
- Caveman enabled flag
- --dry-run and --verify-only modes

Part of HQ Phase 0: safety hooks cross-repo.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Behavioral rules in system prompts

**Files:**
- Modify: `.claude/modes/offensive-base/shared-rules.md`
- Modify: `.claude/modes/base/system-prompt.md`

**Interfaces:**
- Consumes: failure classification spec from design doc
- Produces: behavioral rules injected into every offensive + master session

- [ ] **Step 1: Add failure classification + plan-before-execute to offensive-base**

Append to `.claude/modes/offensive-base/shared-rules.md`:

```markdown
## Failure classification

If you get the same infrastructure error (MCP connection refused, hook
denial, tool schema error) on 2 consecutive attempts: stop working.
Create a GitHub issue with label `harness-failure`. Include: error
message, mode, what you were attempting, which MCP/spoke/hook failed.
Report to master. Do not retry.

If a target rejects your approach: that is normal offensive work. Change
approach. After 3 distinct failed approaches on the same target/vector,
escalate to operator with findings summary: what you tried, what each
attempt returned, your assessment of why.

If you cannot determine whether an error is harness or target, report
both possibilities. Do not guess.

## Engagement planning

Before any offensive execution: produce an engagement plan with scoped
targets (IP + hostname confirmed from intel sources), referenced attack
vectors (linked to source material justifying the approach), and
executable manual steps (literal commands an operator could run without
the model). Present to operator for approval. Do not execute until
approved.
```

- [ ] **Step 2: Add failure classification to base mode**

Append to `.claude/modes/base/system-prompt.md`:

```markdown
## Thread failure handling

If a dispatched thread reports a harness-failure issue: dispatch a
platform-ops thread to fix it. Do not re-dispatch the failed work
until the harness issue is resolved.

If a dispatched thread reports a target-escalation: present findings
to operator for strategic decision. Do not auto-retry with same
approaches.
```

- [ ] **Step 3: Verify system prompts parse correctly**

```bash
bash scripts/tests/test-mode-inject-hook.sh
```
Expected: PASS — mode injection still produces valid JSON with added content.

- [ ] **Step 4: Commit**

```bash
git add .claude/modes/offensive-base/shared-rules.md .claude/modes/base/system-prompt.md
git commit -m "$(cat <<'EOF'
feat(doctrine): add failure classification + engagement planning rules

Offensive modes: 2 consecutive infra errors = stop + create issue.
3 failed target approaches = escalate to operator. Plan before execute.
Base mode: route harness-failures to platform-ops, escalations to operator.

Part of HQ Phase 0: behavioral rules for cross-repo threads.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Mode readiness rules in system prompts

**Files:**
- Modify: `.claude/modes/offensive-base/shared-rules.md`
- Modify: `.claude/modes/base/system-prompt.md`
- Modify: `.claude/modes/platform-ops/system-prompt.md`
- Modify: `.claude/modes/green-dev/system-prompt.md`
- Modify: `.claude/modes/homelab/system-prompt.md`
- Modify: `.claude/modes/dev/system-prompt.md`

**Interfaces:**
- Consumes: mode MCP matrix from design doc (section 1g)
- Produces: every mode has readiness check requirements before work starts

Every mode — not just offensive — benefits from knowing its environment
is functional before spending tokens. The check scope differs by mode.

- [ ] **Step 1: Add readiness check to offensive-base/shared-rules.md**

Append after engagement planning section:

```markdown
## Mode readiness check

Before starting engagement work, verify your capability envelope:
1. Test each required MCP with a lightweight call (list/capabilities).
   Log which are reachable and which are not.
2. Test spoke connectivity (SSH to Kali if needed for this engagement).
3. Report capability envelope to operator as part of engagement plan.
4. If a critical MCP is unreachable (tuoni-mcp for red-team, range-intel
   for range engagements): report as degraded. Do not proceed without
   operator acknowledgement of degraded state.
5. If non-critical MCP is unreachable (e.g., nuclei-mcp): note in plan,
   proceed with alternative approaches.
```

- [ ] **Step 2: Add readiness check to base mode (master/router)**

Append to `.claude/modes/base/system-prompt.md`:

```markdown
## Thread readiness

Before dispatching offensive work, verify the target mode's critical
infrastructure is reachable. Run spoke-health or a quick MCP probe.
If critical spokes are unreachable, do not dispatch — report to operator.

Capability requirements by mode:
- red-team, purple: Kali spoke + tuoni-mcp + range-intel + obsidian-mcp
- ctf: Kali spoke + tuoni-mcp (range-intel only if range-based CTF)
- pentest: Kali spoke + tuoni-mcp + obsidian-mcp
- bounty: obsidian-mcp + technique MCPs (no spokes required)
- green-dev: deploy spoke + range-intel
- red-dev: tuoni-mcp + obsidian-mcp (Kali for test range only)
```

- [ ] **Step 3: Add readiness check to platform-ops**

Append to `.claude/modes/platform-ops/system-prompt.md`:

```markdown
## Readiness self-check

On session start, verify all MCPs are reachable (this mode has full
MCP access for debugging). Report any unreachable MCPs. This is your
mode's core job — know what's healthy and what isn't.
```

- [ ] **Step 4: Add readiness check to green-dev**

Append to `.claude/modes/green-dev/system-prompt.md`:

```markdown
## Readiness check

Before deploying to range: verify deploy spoke SSH reachable, range-intel
responds, and ctp-bridge is functional. If deploy spoke is unreachable,
stop and report — deployment will fail.
```

- [ ] **Step 5: Add readiness check to homelab**

Append to `.claude/modes/homelab/system-prompt.md`:

```markdown
## Readiness check

On session start, verify homelab connectivity. If targeting a specific
host, confirm SSH reachability before making changes. Check obsidian-mcp
for documentation access.
```

- [ ] **Step 6: Add readiness check to dev**

Append to `.claude/modes/dev/system-prompt.md`:

```markdown
## Readiness check

Verify model failover chain: local-ollama reachable (tertiary fallback).
No spoke or MCP infrastructure required for general dev work.
```

- [ ] **Step 7: Run mode injection tests**

```bash
bash scripts/tests/test-mode-inject-hook.sh
```
Expected: PASS — all mode system prompts still produce valid injection.

- [ ] **Step 8: Commit**

```bash
git add .claude/modes/*/system-prompt.md .claude/modes/offensive-base/shared-rules.md
git commit -m "$(cat <<'EOF'
feat(modes): add readiness check rules to all mode system prompts

Every mode now has pre-work readiness requirements:
- Offensive modes: verify MCPs + spokes, report capability envelope
- Base/master: verify target mode infrastructure before dispatch
- Platform-ops: check all MCPs on session start
- Green-dev: verify deploy spoke + range-intel before deploy
- Homelab: verify host connectivity + obsidian
- Dev: verify model failover chain

Prevents threads wasting tokens discovering broken infrastructure.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: GitHub issue templates + mode-readiness template

**Files:**
- Create: `.github/ISSUE_TEMPLATE/harness-failure.yml`
- Create: `.github/ISSUE_TEMPLATE/target-escalation.yml`

**Interfaces:**
- Consumes: template format from design doc
- Produces: structured issue creation for failure triage

- [ ] **Step 1: Create harness-failure template**

```yaml
name: Harness Failure
description: Infrastructure/tooling failure detected by agent thread
labels: ["harness-failure", "platform-ops"]
body:
  - type: input
    id: mode
    attributes:
      label: Mode
      placeholder: "red-team"
    validations:
      required: true
  - type: input
    id: component
    attributes:
      label: Failed component
      placeholder: "tuoni-mcp | hook | spoke | tool"
    validations:
      required: true
  - type: textarea
    id: error
    attributes:
      label: Error message
      description: Exact error from the failed tool call
    validations:
      required: true
  - type: textarea
    id: context
    attributes:
      label: What was attempted
      description: Brief description of the action that triggered the failure
    validations:
      required: true
  - type: input
    id: consecutive
    attributes:
      label: Consecutive failures
      placeholder: "2"
```

- [ ] **Step 2: Create target-escalation template**

```yaml
name: Target Escalation
description: Target resistance requiring operator strategic decision
labels: ["target-escalation"]
body:
  - type: input
    id: mode
    attributes:
      label: Mode
      placeholder: "red-team"
    validations:
      required: true
  - type: input
    id: target
    attributes:
      label: Target identifier
      placeholder: "Host/service being targeted"
    validations:
      required: true
  - type: textarea
    id: approaches
    attributes:
      label: Approaches tried
      description: "List each approach and its result"
    validations:
      required: true
  - type: textarea
    id: assessment
    attributes:
      label: Assessment
      description: Why target is resistant, recommended next steps
    validations:
      required: true
```

- [ ] **Step 3: Verify templates parse correctly**

```bash
# GitHub validates YAML on push, but check locally
for f in .github/ISSUE_TEMPLATE/harness-failure.yml .github/ISSUE_TEMPLATE/target-escalation.yml; do
    python3 -I -c "import yaml; yaml.safe_load(open('$f'))" && echo "OK: $f" || echo "FAIL: $f"
done
```

- [ ] **Step 4: Commit**

```bash
git add .github/ISSUE_TEMPLATE/harness-failure.yml .github/ISSUE_TEMPLATE/target-escalation.yml
git commit -m "$(cat <<'EOF'
feat(triage): add harness-failure and target-escalation issue templates

Structured templates for agent-created issues:
- harness-failure: infrastructure/tooling failures → platform-ops board
- target-escalation: target resistance → operator review

Part of HQ Phase 0: failure classification and auto-triage.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: Integration verification

**Files:**
- None created (manual verification)

**Interfaces:**
- Consumes: all prior tasks
- Produces: verified Phase 0 deployment

- [ ] **Step 1: Deploy to real ~/.claude/**

```bash
bash scripts/deploy-hq.sh
```

- [ ] **Step 2: Verify deploy state**

```bash
bash scripts/deploy-hq.sh --verify-only
```
Expected: all checks pass.

- [ ] **Step 3: Test in my_claude_dev — no double-firing**

Open Claude Code session in my_claude_dev. Set `/mode platform-ops`.
Run any tool. Verify: project-level hooks fire, user-level hooks
are silent (exit early). Check by adding `echo "USER-LEVEL FIRED" >&2`
temporarily to user-level hook, verify it doesn't appear.

- [ ] **Step 4: Test in another repo — safety gates fire**

Open Claude Code session in `tuoni-plugins` (or any non-my_claude_dev
repo). Verify:
- Master-dispatch-guard: attempt Agent subagent → check if guard fires
  (requires `/mode base` first — known Phase 0 limitation)
- CTP guard: attempt to read a guarded path → check if ctp guard fires
- Tuoni secret guard: check if tuoni token protection applies

- [ ] **Step 5: Test caveman cross-repo**

Open session in `homelab_planning`. Verify caveman compression is
active (this should already work — caveman is a plugin, not a hook).

- [ ] **Step 6: Run full CI check**

```bash
bash scripts/tests/run-all.sh
pre-commit run --all-files
```
Expected: all green.

- [ ] **Step 7: Create PR**

```bash
git push origin HEAD
gh pr create --title "feat(hq): Phase 0 — safety hooks cross-repo" --body "$(cat <<'EOF'
## Summary
Deploy safety gates (ctp-bridge, dispatch discipline, secret protection)
to ~/.claude/ so they apply to ALL repos, not just my_claude_dev.

Phase 0 of HQ restructure — purely additive, zero risk to current setup.

## Changes
- 3 safety hooks rewritten for user-level paths (scripts/deploy/hooks/)
- 1 new hook: dispatch-wakeup-enforcer (ScheduleWakeup nudge)
- deploy-hq.sh: deploys hooks + settings.json to ~/.claude/
- Failure classification rules in offensive-base/shared-rules.md
- Engagement planning rule in offensive-base/shared-rules.md
- Thread failure handling in base mode system prompt
- Issue templates: harness-failure, target-escalation
- Security fix: hardcoded path in session-end-sync.sh (S2)
- 4 new test suites

## Test plan
- [ ] CI green
- [ ] deploy-hq.sh deploys to ~/.claude/ correctly
- [ ] In tuoni-plugins: safety gates fire
- [ ] In my_claude_dev: no double-firing
- [ ] Caveman active cross-repo (already works via plugin)
- [ ] --verify-only reports correct state

Closes: [create issue first]

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

**Spec coverage:**
- S2 (hardcoded path): Task 1 ✓
- S5 (MCP wrapper audit): Task 1 ✓
- S3 (hook permissions): Task 5 deploy-hq.sh ✓
- S4 (CTP guard-stack): Task 3 pretooluse-ctp.sh ✓
- Safety hooks cross-repo: Task 3 ✓
- Dispatch discipline: Task 4 ✓
- Caveman cross-repo: Already works (plugin). Verified in Task 9. ✓
- Failure classification rules: Task 6 ✓
- Plan-before-execute rule: Task 6 ✓
- Mode readiness rules (all modes): Task 7 ✓
- Issue templates: Task 8 ✓
- Double-fire prevention: Task 3 ✓
- Env var verification: Task 2 ✓

**Step scan:** Each step is one action. No "handle edge cases" or "add validation" placeholders.

**Type consistency:** Hook names consistent across tasks. `scripts/deploy/hooks/` path used everywhere.

**Review focus items tested:**
1. Hook without CLAUDE_PROJECT_DIR → Task 2 tests this
2. Double-fire → Task 3 tests this
3. Fresh machine deploy → Task 5 tests this
4. Stale deploy → Task 5 --verify-only tests this
5. CTP guard-stack resolution → Task 2 Step 3 (explicit test) + Task 3 Step 4 (implementation)

**Proportion:** Plan is implementation steps, not code transcripts. Test assertions shown for verification; hook bodies described by approach, not full code.
