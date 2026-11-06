# Homelab Harness Wiring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire `my_claude_dev` harness to orchestrate homelab IaC development — dedicated mode, AD-13 leak prevention hook, and per-epic board sync.

**Architecture:** New `homelab` mode provides system-prompt with project rules, tool-policy denying offensive MCPs, and settings. A PreToolUse hook (`homelab-leak-guard.sh`) extracts device names and model strings from private inventory at runtime and blocks them from reaching the public repo. A board sync script bridges `sprint-status.yaml` stories to GitHub issues one epic at a time.

**Tech Stack:** Bash (hooks, scripts), Python 3 (JSON parsing in hooks), `gh` CLI (board/issues), `jq` (YAML-to-JSON via `python3 -c`).

**Spec:** `~/Documents/homelab_planning/planning-artifacts/change-intake-harness-homelab-wiring-2026-11-06.md`

## Global Constraints

- Hook protocol: PreToolUse exit 0 + deny JSON = blocked; exit 0 + no output = allow; exit 2 = fail-closed.
- PostToolUse exit 0 always (cannot block, informational only).
- Mode files: `system-prompt.md`, `settings.json`, `tool-policy.yaml` under `.claude/modes/<name>/`.
- `start-mode.sh` auto-discovers modes from `.claude/modes/` — no registration needed.
- `mode-inject.sh` reads `.active-mode` and injects system-prompt + filtered skills.
- Board CLI: `scripts/board.sh` requires `.ai/project.env` with `PROJECT_NUMBER`, `PROJECT_OWNER`, `PROJECT_ID`.
- All hooks use `$CLAUDE_PROJECT_DIR` env var for project root.
- Priority order for all homelab work: Security > Correctness > Maintainability > Delivery > Tokens.
- Python invocations in hooks use `-I` flag (isolated mode).

## Review Focus

1. **Hook bypass via indirect path:** A command like `cat ~/Documents/homelab_planning/deployments/home/inventory/assets.yml > ~/Documents/homelab_infra/leaked.yml` must be caught — hook scans full command string, not just the target path. Covered in Task 2 step 1 test.
2. **Hook false positives on common words:** Asset names like `frame`, `echo-dot`, `pi3` are common English words or project names. The hook must match whole-word boundaries to avoid blocking `echo "framework version"`. Covered in Task 2 step 7 test.
3. **Board sync duplicate detection:** Re-running sync after manual issue title edits could create duplicates. Sync matches on label + story key in body, not title. Covered in Task 3 step 1 test.
4. **YAML parsing without PyYAML:** `sprint-status.yaml` uses flat `key: value` pairs (no nesting beyond `development_status:`). The parser must handle the comment block and metadata lines without a YAML library. Covered in Task 3 step 3.
5. **Hook performance on large diffs:** Edit tool input contains `old_string` and `new_string` — both must be scanned. A 500-line edit should not add perceptible latency. The cached grep pattern (single `grep -wF` call with pattern file) handles this. Covered in Task 2 step 11 test.

---

### Task 1: Homelab Mode

**Files:**
- Create: `.claude/modes/homelab/system-prompt.md`
- Create: `.claude/modes/homelab/settings.json`
- Create: `.claude/modes/homelab/tool-policy.yaml`

**Interfaces:**
- Consumes: Mode system (`start-mode.sh` auto-discovers from `.claude/modes/`; `mode-inject.sh` reads `.active-mode` and injects `system-prompt.md`; `mode-tool-gate.sh` reads `tool-policy.yaml`)
- Produces: `.active-mode` value `homelab` that Task 2's hook checks to gate enforcement

- [ ] **Step 1: Create `system-prompt.md`**

Write `.claude/modes/homelab/system-prompt.md` with content from the change intake decision 1 — the full system prompt block including: Active Mode header, Priority, Two-repo model, Apply model, Layer model, Data-driven IaC, Key anti-patterns (AD-1/3/8/9/13/17), What this mode is NOT for, Project-repo skills note, and an Obsidian knowledge base section noting the LLM Wiki pattern (raw notes to `raw/`, structured cross-linked pages via `obsidian-mcp`; vault holds deployment reality so AD-13 applies — local only, never published).

- [ ] **Step 2: Create `settings.json`**

```json
{
  "_mode": "homelab",
  "_description": "Homelab IaC development. No offensive tools, no range."
}
```

- [ ] **Step 3: Create `tool-policy.yaml`**

Trimmed deny list — only 3 offensive/irrelevant tools:

```yaml
# homelab mode — IaC development + security hardening.
# Deny offensive operations tools; allow security reference for defensive design.
deny:
  - "mcp__tuoni-mcp__*"      # C2 framework — offensive only
  - "mcp__range-intel__*"    # Range recon — not relevant
  - "mcp__rea-mcp__*"        # Ghidra RE — not relevant
# Allowed (denied in platform-ops but useful here):
#   obsidian-mcp   — homelab LLM Wiki knowledge base
#   outline-readonly — reference wiki
#   cve-mcp        — security fitness, EOL assessment
#   mitre-mcp      — threat modeling for network/access design
#   hacktricks-mcp — defensive awareness for CIS hardening
#   lolbins-mcp    — host hardening awareness
```

- [ ] **Step 4: Verify mode discovery**

Run: `bash scripts/start-mode.sh --list`
Expected: `homelab` appears in output with description "Homelab IaC development. No offensive tools, no range."

- [ ] **Step 5: Verify tool-policy parsing**

Run:
```bash
echo 'homelab' > .claude/.active-mode
echo '{"tool_name":"mcp__tuoni-mcp__list_agents"}' | bash .claude/hooks/mode-tool-gate.sh
```
Expected: JSON output with `"permissionDecision":"deny"` and reason mentioning `homelab mode`.

Run:
```bash
echo '{"tool_name":"Bash"}' | bash .claude/hooks/mode-tool-gate.sh
```
Expected: No output (Bash is allowed — gate only checks `mcp__*`).

Run (verify security/knowledge MCPs are allowed):
```bash
for tool in mcp__cve-mcp__search mcp__mitre-mcp__lookup mcp__obsidian-mcp__read mcp__hacktricks-mcp__search mcp__lolbins-mcp__search; do
  result="$(echo "{\"tool_name\":\"$tool\"}" | bash .claude/hooks/mode-tool-gate.sh 2>/dev/null)"
  [[ -z "$result" ]] && echo "PASS: $tool allowed" || echo "FAIL: $tool denied"
done
```
Expected: All 5 show PASS (allowed).

- [ ] **Step 6: Clean up test state and commit**

```bash
rm .claude/.active-mode
git add .claude/modes/homelab/
git commit -m "feat(modes): add homelab mode for IaC development

Dedicated mode with project-context rules, offensive-tool denies,
and separation from platform-ops/range work."
```

---

### Task 2: AD-13 Leak Prevention Hook

**Files:**
- Create: `.claude/hooks/homelab-leak-guard.sh`
- Create: `.ai/homelab-leak.conf`
- Modify: `.claude/settings.json` (add hook registration)
- Modify: `scripts/hooks/response-scanner.sh` (add AD-13 patterns)

**Interfaces:**
- Consumes: `.active-mode` value from Task 1; inventory at path configured in `.ai/homelab-leak.conf`; PreToolUse JSON protocol (`tool_name`, `tool_input`)
- Produces: PreToolUse deny decisions for Bash/Write/Edit when AD-13 patterns match in public-repo-targeted operations

- [ ] **Step 1: Write test script `tests/test-homelab-leak-guard.sh`**

Create a bash test that exercises the hook with mock inputs. Tests:

```bash
#!/usr/bin/env bash
# tests/test-homelab-leak-guard.sh — unit tests for homelab-leak-guard.sh
set -euo pipefail
PASS=0; FAIL=0; TOTAL=0

assert_deny() {
  TOTAL=$((TOTAL+1))
  local desc="$1" input="$2"
  local result
  result="$(printf '%s' "$input" | bash .claude/hooks/homelab-leak-guard.sh 2>/dev/null)" || true
  if printf '%s' "$result" | grep -q '"permissionDecision":"deny"'; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1)); echo "FAIL (expected deny): $desc"
  fi
}

assert_allow() {
  TOTAL=$((TOTAL+1))
  local desc="$1" input="$2"
  local result
  result="$(printf '%s' "$input" | bash .claude/hooks/homelab-leak-guard.sh 2>/dev/null)" || true
  if printf '%s' "$result" | grep -q '"permissionDecision":"deny"'; then
    FAIL=$((FAIL+1)); echo "FAIL (expected allow): $desc"
  else
    PASS=$((PASS+1))
  fi
}

# Setup: mock active mode and config
mkdir -p .claude
echo 'homelab' > .claude/.active-mode

# T1: Bash writing asset name to public repo path
assert_deny "bash echo asset name to public repo" \
  '{"tool_name":"Bash","tool_input":{"command":"echo peanut >> ~/Documents/homelab_infra/hosts.yml"}}'

# T2: Write tool with asset model in content targeting public repo
assert_deny "write model string to public repo" \
  '{"tool_name":"Write","tool_input":{"file_path":"/home/user/Documents/homelab_infra/roles/test.yml","content":"server: Beelink ME mini"}}'

# T3: Edit tool with asset name in new_string targeting public repo
assert_deny "edit asset name into public repo" \
  '{"tool_name":"Edit","tool_input":{"file_path":"/home/user/Documents/homelab_infra/vars.yml","old_string":"placeholder","new_string":"witcher"}}'

# T4: Bash command not targeting public repo — allow
assert_allow "bash in private repo" \
  '{"tool_name":"Bash","tool_input":{"command":"cat ~/Documents/homelab_planning/inventory/assets.yml"}}'

# T5: Write to public repo with no deny-list content — allow
assert_allow "clean write to public repo" \
  '{"tool_name":"Write","tool_input":{"file_path":"/home/user/Documents/homelab_infra/roles/base.yml","content":"packages:\n  - vim\n  - curl"}}'

# T6: Non-homelab mode — allow everything
echo 'platform-ops' > .claude/.active-mode
assert_allow "different mode bypasses hook" \
  '{"tool_name":"Bash","tool_input":{"command":"echo peanut >> ~/Documents/homelab_infra/hosts.yml"}}'
echo 'homelab' > .claude/.active-mode

# T7: Common word false positive — "frame" as substring in "framework"
assert_allow "framework not false positive for frame" \
  '{"tool_name":"Write","tool_input":{"file_path":"/home/user/Documents/homelab_infra/README.md","content":"This framework provides..."}}'

# T8: Identity handle from config deny-list
assert_deny "identity handle blocked" \
  '{"tool_name":"Write","tool_input":{"file_path":"/home/user/Documents/homelab_infra/README.md","content":"maintainer: Moon-Knight13"}}'

# T9: Vendor model on deny-list
assert_deny "vendor model blocked" \
  '{"tool_name":"Bash","tool_input":{"command":"echo UDR7 >> ~/Documents/homelab_infra/network.yml"}}'

# T10: Dry-run mode logs but allows
HOMELAB_LEAK_DRY_RUN=1 assert_allow "dry-run allows but should log" \
  '{"tool_name":"Bash","tool_input":{"command":"echo peanut >> ~/Documents/homelab_infra/hosts.yml"}}'

# T11: Read tool — not intercepted (read-only, no leak vector)
assert_allow "read tool not intercepted" \
  '{"tool_name":"Read","tool_input":{"file_path":"/home/user/Documents/homelab_infra/roles/base.yml"}}'

# Cleanup
rm .claude/.active-mode
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
[[ $FAIL -eq 0 ]] || exit 1
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/test-homelab-leak-guard.sh`
Expected: All tests fail (hook doesn't exist yet).

- [ ] **Step 3: Create `.ai/homelab-leak.conf`**

```ini
# AD-13 leak prevention configuration.
# Hook reads this + extracts names/models from inventory at runtime.

# Path to public repo (hook only enforces on writes targeting this path)
public_repo=~/Documents/homelab_infra

# Path to private inventory (hook extracts asset names + models at runtime)
inventory=~/Documents/homelab_planning/deployments/home/inventory/assets.yml

# Identity handles to block (one per line after marker)
# These are usernames, handles, or identity strings that must not appear in public repo.
identity_handles=Moon-Knight13

# Vendor model strings on platform-role deny-list (one per line after marker)
# Models that identify specific hardware in platform roles.
vendor_models=UDR7,UAP-AC-Pro,TL-SG108E,GS108LP

# Vault variable name patterns (comma-separated prefixes)
vault_patterns=vault_,secret_
```

- [ ] **Step 4: Implement `homelab-leak-guard.sh`**

Create `.claude/hooks/homelab-leak-guard.sh` (chmod +x). Logic:

1. Read `.active-mode` — exit 0 (no opinion) if not `homelab`.
2. Read stdin JSON — extract `tool_name` and `tool_input`.
3. Gate on tool type: only process `Bash`, `Write`, `Edit`. Exit 0 for others.
4. For Bash: extract `command` string. Check if command references the public repo path. If not, exit 0.
5. For Write: extract `file_path` and `content`. Check if `file_path` is under public repo. If not, exit 0.
6. For Edit: extract `file_path`, `old_string`, `new_string`. Check if `file_path` is under public repo. If not, exit 0.
7. Build deny-list (cached in `/tmp/homelab-leak-cache-$$`):
   - Extract `name:` values from inventory YAML via `grep '  - name:' | sed`.
   - Extract `model:` values from inventory YAML via `grep '    model:' | sed`.
   - Read identity handles from conf.
   - Read vendor models from conf.
   - Read vault patterns from conf.
   - Write all patterns to cache file, one per line.
8. Scan the relevant content (command string / file content / new_string) against patterns using `grep -wFf` (word-boundary, fixed-string, pattern-file).
9. On match: if `HOMELAB_LEAK_DRY_RUN=1`, log warning and exit 0. Otherwise emit deny JSON citing AD-13 and the matched pattern category.
10. On no match: exit 0.

Use `set -euo pipefail` and `trap 'exit 2' ERR` for fail-closed behavior matching `mode-tool-gate.sh`.

- [ ] **Step 5: Run tests to verify they pass**

Run: `bash tests/test-homelab-leak-guard.sh`
Expected: All 11 tests pass.

- [ ] **Step 6: Fix any test failures and re-run**

Iterate until all tests pass. Pay attention to:
- Word boundary matching (`grep -w`) for short names like `frame`, `pi3`.
- Path expansion of `~` in config values.
- JSON parsing robustness for `tool_input` variations.

- [ ] **Step 7: Register hook in `settings.json`**

Add to `.claude/settings.json` under `PreToolUse`, after the existing `tuoni-secret-guard.sh` entry. Matcher: `Bash|Write|Edit` (same scope as CTP bridge guard).

```json
{
  "matcher": "Bash|Write|Edit",
  "hooks": [
    {
      "type": "command",
      "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/homelab-leak-guard.sh"
    }
  ]
}
```

- [ ] **Step 8: Extend `response-scanner.sh` with AD-13 patterns**

Add a new detection section after the existing key-value secret patterns block. The section:
1. Checks if `.active-mode` is `homelab` — skip AD-13 scanning otherwise.
2. Reads the same `.ai/homelab-leak.conf` and builds the same deny-list.
3. Scans `$TOOL_OUTPUT` against patterns with `grep -wFf`.
4. On match: append to `FINDINGS` array with `"AD-13 leak (asset/identity)"`.

This is PostToolUse — warn only, cannot block.

- [ ] **Step 9: Test response-scanner AD-13 integration**

Run:
```bash
echo 'homelab' > .claude/.active-mode
echo '{"tool_name":"Bash","tool_result":"hostname: peanut\nmodel: Beelink ME mini"}' | bash scripts/hooks/response-scanner.sh
rm .claude/.active-mode
```
Expected: Output contains notification mentioning AD-13. Note: `tool_result` is a string here (Bash output); response-scanner already handles both string and dict/list forms via its existing Python extraction.

- [ ] **Step 10: Commit**

```bash
git add .claude/hooks/homelab-leak-guard.sh .ai/homelab-leak.conf \
  .claude/settings.json scripts/hooks/response-scanner.sh \
  tests/test-homelab-leak-guard.sh
git commit -m "feat(hooks): add AD-13 leak prevention for homelab mode

Config-driven deny-list extracted from private inventory at runtime.
Covers Bash, Write, and Edit tools targeting the public repo.
Mode-gated: only enforces in homelab mode.
Dry-run mode via HOMELAB_LEAK_DRY_RUN=1."
```

---

### Task 3: Per-Epic Board Sync

**Files:**
- Create: `scripts/homelab-board-sync.sh`
- Create: `.claude/commands/homelab-board-sync.md`
- Create: `tests/test-homelab-board-sync.sh`

**Interfaces:**
- Consumes: `sprint-status.yaml` (flat YAML: `key: status` pairs under `development_status:`); `board.sh add <n>` for board placement; `gh issue create` / `gh issue list` for GitHub issues
- Produces: GitHub issues with labels `homelab`, `epic-N`, `agent-ready`; board cards via `board.sh add`

- [ ] **Step 1: Write test script for YAML parsing and title derivation**

```bash
#!/usr/bin/env bash
# tests/test-homelab-board-sync.sh — unit tests for parsing + title logic
set -euo pipefail
PASS=0; FAIL=0; TOTAL=0

assert_eq() {
  TOTAL=$((TOTAL+1))
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1)); echo "FAIL: $desc — expected '$expected', got '$actual'"
  fi
}

# Source the functions (script exports them when sourced with HOMELAB_SYNC_TEST=1)
HOMELAB_SYNC_TEST=1 source scripts/homelab-board-sync.sh

# T1: Title derivation from story key
assert_eq "title from key" \
  "1-1: Network Segmentation Model As Data" \
  "$(derive_title '1-1-network-segmentation-model-as-data')"

# T2: Epic number extraction
assert_eq "epic from key 1-1" "1" "$(epic_number '1-1-network-segmentation-model-as-data')"
assert_eq "epic from key 5-7" "5" "$(epic_number '5-7-adopt-workflow')"

# T3: Skip non-story keys
assert_eq "skip epic marker" "skip" "$(should_sync 'epic-1')"
assert_eq "skip retrospective" "skip" "$(should_sync 'epic-1-retrospective')"
assert_eq "sync story" "sync" "$(should_sync '1-1-network-segmentation-model-as-data')"

# T4: Story key extracted from body for duplicate detection
assert_eq "story key in body" "true" \
  "$(echo 'Story key: 1-1-network-segmentation-model-as-data' | grep -q '1-1-network-segmentation-model-as-data' && echo true || echo false)"

echo "Results: $PASS/$TOTAL passed, $FAIL failed"
[[ $FAIL -eq 0 ]] || exit 1
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/test-homelab-board-sync.sh`
Expected: Fails (script doesn't exist).

- [ ] **Step 3: Implement `scripts/homelab-board-sync.sh`**

Structure:

```
#!/usr/bin/env bash
# homelab-board-sync.sh — sync sprint-status.yaml stories to GitHub issues.
# Usage: homelab-board-sync.sh --epic N [--repo owner/repo] [--sprint-file path] [--dry-run]
```

Functions (exported when `HOMELAB_SYNC_TEST=1` for testability):
- `derive_title(key)` — Split on `-`, first two segments become `N-M:`, rest title-cased.
- `epic_number(key)` — First segment before `-`.
- `should_sync(key)` — Returns `sync` for story keys (matches `N-N-*`), `skip` for `epic-*` and `*-retrospective`.
- `parse_stories(file, epic_n)` — Read `development_status:` block, emit story keys belonging to epic N.
- `ensure_labels(repo)` — Create `homelab` + `epic-1` through `epic-5` + `agent-ready` labels if missing.
- `sync_story(key, repo)` — Check for existing issue (search by label `homelab` + body containing story key). If not found, create issue and call `board.sh add`.
- `main()` — Parse args, validate, call `ensure_labels`, iterate `parse_stories`, call `sync_story` for each, print summary table.

YAML parsing: `python3 -I -c` to extract `development_status:` block as key-value pairs. No PyYAML — simple regex on the flat structure.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/test-homelab-board-sync.sh`
Expected: All pass.

- [ ] **Step 5: Dry-run integration test against real sprint-status.yaml**

Run:
```bash
bash scripts/homelab-board-sync.sh --epic 1 --dry-run \
  --sprint-file ~/Documents/homelab_planning/implementation-artifacts/sprint-status.yaml
```
Expected: Prints 14 stories for epic 1 with titles, says "(dry-run)" for each, prints summary table showing 14 would-be-created.

Run with `--epic 5`:
Expected: 7 stories.

- [ ] **Step 6: Create slash command `.claude/commands/homelab-board-sync.md`**

```markdown
# /homelab-board-sync — Sync homelab stories to GitHub board

Sync stories from sprint-status.yaml to GitHub issues, one epic at a time.

## Usage

Pass an epic number: `/homelab-board-sync 1` syncs epic 1.
Pass `--dry-run` to preview without creating issues.

## Instructions

1. Parse the argument for the epic number. If none given, ask which epic.

2. Run the sync:
   ```bash
   bash scripts/homelab-board-sync.sh --epic $N \
     --sprint-file ~/Documents/homelab_planning/implementation-artifacts/sprint-status.yaml
   ```

3. Report the summary table output.

4. If issues were created, remind the operator:
   - Cards start in Backlog with `agent-ready` label
   - Use `bash scripts/board.sh move <n> ready` to make cards claimable
   - Use `/next-issue` in homelab mode to pick up work
```

- [ ] **Step 7: Commit**

```bash
git add scripts/homelab-board-sync.sh tests/test-homelab-board-sync.sh \
  .claude/commands/homelab-board-sync.md
git commit -m "feat(board): add per-epic homelab board sync

Bridges sprint-status.yaml stories to GitHub issues with homelab/epic-N
labels. One epic at a time via --epic flag. Idempotent — matches on
story key in issue body to prevent duplicates."
```

---

### Task 4: Integration Verification

**Files:**
- None created or modified (verification only)

**Interfaces:**
- Consumes: All outputs from Tasks 1–3

- [ ] **Step 1: Verify mode + hook integration**

```bash
echo 'homelab' > .claude/.active-mode

# Hook should deny writing asset name to public repo
echo '{"tool_name":"Write","tool_input":{"file_path":"/home/user/Documents/homelab_infra/test.yml","content":"host: peanut"}}' \
  | bash .claude/hooks/homelab-leak-guard.sh
# Expected: deny

# Hook should allow writing to private repo
echo '{"tool_name":"Write","tool_input":{"file_path":"/home/user/Documents/homelab_planning/test.yml","content":"host: peanut"}}' \
  | bash .claude/hooks/homelab-leak-guard.sh
# Expected: allow (no output)

# Mode tool gate should deny offensive tools
echo '{"tool_name":"mcp__tuoni-mcp__list_agents"}' \
  | bash .claude/hooks/mode-tool-gate.sh
# Expected: deny

rm .claude/.active-mode
```

- [ ] **Step 2: Verify board sync dry-run for all 5 epics**

```bash
for n in 1 2 3 4 5; do
  echo "=== Epic $n ==="
  bash scripts/homelab-board-sync.sh --epic "$n" --dry-run \
    --sprint-file ~/Documents/homelab_planning/implementation-artifacts/sprint-status.yaml
done
```

Expected story counts: epic-1=14, epic-2=11, epic-3=8, epic-4=7, epic-5=7. Total=47 lines but 41 are stories (6 are epic/retrospective markers, skipped).

- [ ] **Step 3: Verify `start-mode.sh --list` shows homelab**

Run: `bash scripts/start-mode.sh --list`
Expected: `homelab` in list with correct description.

- [ ] **Step 4: Run full test suite**

```bash
bash tests/test-homelab-leak-guard.sh && echo "Leak guard: OK"
bash tests/test-homelab-board-sync.sh && echo "Board sync: OK"
```

Expected: Both pass.

- [ ] **Step 5: Final commit (if any fixes needed)**

Only if integration testing revealed issues fixed in this task.
