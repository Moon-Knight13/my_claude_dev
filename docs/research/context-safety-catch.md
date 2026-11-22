# Context Safety Catch — Research Report

**Date:** 2026-11-21
**Status:** Research complete, ready for implementation planning

## Problem Statement

When a T3 thread or Claude Code session approaches context limits (~200k tokens
for Opus 4.6 1M, effective quality degradation around 150-180k), conversation
quality degrades: compression loses detail, instructions drift, work gets
repeated. No automated detection or graceful handoff exists.

---

## Finding 1: Available Signals

### Direct — Status Line (PRIMARY)

The status line script receives a JSON blob on stdin every update cycle. Fields
confirmed available via [Claude Code statusline docs](https://code.claude.com/docs/en/statusline.md):

| Field | Type | Description |
|---|---|---|
| `context_window.used_percentage` | float | Current context usage 0-100 |
| `context_window.total_tokens` | int | Model's context window size |
| `context_window.used_tokens` | int | Tokens currently in context |
| `cost.total_cost_usd` | float | Session spend |
| `cost.total_duration_ms` | int | Session wall time |
| `session_id` | string | Session identifier |

**This is the only runtime source of live token counts.**

Current `scripts/statusline.sh` buffers stdin but only reads mode — it does NOT
parse `context_window`. Enhancement needed.

### Hooks — No Direct Access

Hooks receive JSON on stdin with these fields:

- **Common:** `session_id`, `prompt_id`, `transcript_path`, `cwd`,
  `scratchpad_dir`, `permission_mode`, `effort`, `hook_event_name`
- **PreToolUse/PostToolUse:** `tool_name`, `tool_input`, `tool_use_id` (Post
  adds `tool_response`)
- **UserPromptSubmit:** `prompt`
- **Stop/SubagentStop:** `last_assistant_message`

**No token count, context usage, or message count in any hook event.**

### Hook Events for Compaction

- `PreCompact` / `PostCompact` — fired when auto-compact triggers
- `SessionStart` with `source: "compact"` — after compaction completes
- `SessionStart` with `source: "resume"` or `"fork"` — includes
  `context_tokens` (v2.1.251+)

These are useful as secondary signals (compaction = context was full).

### T3 Thread Metadata

`t3_thread_read` returns:

| Field | Useful? |
|---|---|
| `itemCount` | Yes — correlates with context growth |
| `runCount` | Marginal |
| `status` | No — running/settled only |
| Token usage | **Not exposed** |

### Environment Variables

Confirmed available in hooks:

| Variable | Value |
|---|---|
| `CLAUDE_CODE_SESSION_ID` | Session UUID |
| `CLAUDE_EFFORT` | Effort level |
| `CLAUDE_PROJECT_DIR` | Project root |
| `CLAUDECODE` | `1` (bool flag) |
| `CLAUDE_PID` | Process PID |

**No `CLAUDE_CONTEXT_*` or `CLAUDE_TOKEN_*` variables exist.**

### Audit Trail

Existing `.claude/audit/tool-calls.jsonl` logs every tool call with timestamp.
Can derive:

- Tool call count per session (proxy for context growth)
- Rate of tool calls (acceleration = complex operation)
- Read tool frequency (each Read adds ~2k-8k tokens)

---

## Finding 2: The Bridge Pattern

Since hooks lack direct token access but the status line has it, the solution is
a **status line → file → hook bridge**:

```
┌──────────────┐    write     ┌─────────────────┐    read     ┌──────────────┐
│  statusline  │ ──────────── │  state file      │ ─────────── │  hook script │
│  (gets JSON) │              │  /tmp/cc-context/ │             │  (PreToolUse)│
└──────────────┘              │  {session_id}.json│             └──────────────┘
                              └─────────────────┘
```

The status line updates on every API response. The hook reads the latest value
before each tool call. Latency: one API round-trip behind (acceptable).

---

## Design: Context Safety Catch

### Component 1: Status Line Enhancement

Modify `scripts/statusline.sh` to parse context window data from stdin and write
to a session-keyed state file.

```bash
# In statusline.sh, after reading STDIN_BUF:
CONTEXT_DIR="/tmp/claude-${UID:-1000}/context-state"
mkdir -p "$CONTEXT_DIR" 2>/dev/null || true

SESSION_ID=$(printf '%s' "$STDIN_BUF" | python3 -I -c '
import sys, json
try:
    d = json.load(sys.stdin)
    cw = d.get("context_window", {})
    sid = d.get("session_id", "")
    if sid and cw:
        state = {
            "used_pct": cw.get("used_percentage", 0),
            "used_tokens": cw.get("used_tokens", 0),
            "total_tokens": cw.get("total_tokens", 0),
            "session_id": sid,
        }
        import os
        state_dir = os.environ.get("CONTEXT_STATE_DIR", "/tmp/context-state")
        os.makedirs(state_dir, exist_ok=True)
        with open(f"{state_dir}/{sid}.json", "w") as f:
            json.dump(state, f)
        print(sid)
except Exception:
    pass
' 2>/dev/null) || true
```

### Component 2: PreToolUse Hook — `context-safety-catch.sh`

```bash
#!/usr/bin/env bash
# context-safety-catch.sh — PreToolUse hook
# Reads context state from status line bridge file.
# Injects warning or hard gate based on threshold.
set -euo pipefail

CONTEXT_DIR="/tmp/claude-${UID:-1000}/context-state"
SESSION_ID="${CLAUDE_CODE_SESSION_ID:-}"

[[ -n "$SESSION_ID" ]] || exit 0

STATE_FILE="$CONTEXT_DIR/$SESSION_ID.json"
[[ -f "$STATE_FILE" ]] || exit 0

# Parse state
read -r USED_PCT USED_TOKENS < <(python3 -I -c '
import sys, json
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    print(d.get("used_pct", 0), d.get("used_tokens", 0))
except Exception:
    print("0 0")
' "$STATE_FILE" 2>/dev/null)

# Thresholds (configurable via env)
WARN_PCT="${CONTEXT_WARN_PCT:-75}"
HARD_PCT="${CONTEXT_HARD_PCT:-90}"

if (( $(echo "$USED_PCT >= $HARD_PCT" | bc -l) )); then
    # HARD GATE — block tool call, force handover
    cat <<EOF
{"decision":"block","reason":"CONTEXT LIMIT: ${USED_PCT}% used (${USED_TOKENS} tokens). STOP. Write handover file NOW to .claude/handover/<session-id>.md using the format in CLAUDE.md. No further tool calls until handover is written (Write tool exempted)."}
EOF
    exit 0
fi

if (( $(echo "$USED_PCT >= $WARN_PCT" | bc -l) )); then
    # WARNING — inject notification, allow tool call
    echo "⚠ CONTEXT WARNING: ${USED_PCT}% used (${USED_TOKENS} tokens). Begin wrapping up. Prepare handover file soon."
    exit 0
fi

exit 0
```

**Write tool exemption:** The hard gate must exempt `Write` calls targeting
`.claude/handover/` — otherwise the agent can't write its own handover. The
matcher should be `""` (all tools) but the script checks tool name internally.

### Component 3: Handover File Format

```markdown
# Thread Handover — {session_id}

## Chain
- Original thread: {thread_id or link}
- Previous handovers: [list if chain > 1]
- Handover reason: context limit at {pct}% ({tokens} tokens)

## Task
{Original task description — copied from initial prompt}

## Status
- [ ] {remaining work item 1}
- [ ] {remaining work item 2}
- [x] {completed item — brief}

## Findings So Far
{Key findings, decisions made, conclusions reached}

## Files Touched
- `path/to/file.py` — what was changed and why
- `path/to/other.sh` — created, purpose

## Decisions Made
- {Decision 1}: {rationale}
- {Decision 2}: {rationale}

## Next Steps
1. {Immediate next action}
2. {Following action}

## Context for Continuation
{Anything the next thread needs to know that isn't in the files themselves —
  gotchas, dead ends tried, environmental requirements}
```

### Component 4: Master-Orchestrator Integration

For T3 threads dispatched by master:

1. **Dispatch with handover awareness:** Include handover instructions in every
   thread's prompt:
   ```
   If you receive a context limit warning, write handover to
   .claude/handover/{thread_id}.md and stop.
   ```

2. **Master monitors handovers:** PostToolUse hook on master watches for
   handover file creation (via audit trail or file watcher). Or: thread's Stop
   hook writes handover path to a known location.

3. **Continuation dispatch:** Master reads handover, spawns fresh thread with
   handover content as prompt context. New thread gets clean 200k window.

4. **Chain tracking:** Each handover file links to previous. Master maintains
   chain in dispatch metadata:
   ```yaml
   chain:
     - thread_id: abc-123
       handover: .claude/handover/abc-123.md
       reason: context_limit_90pct
     - thread_id: def-456  # continuation
       parent_handover: .claude/handover/abc-123.md
   ```

### Component 5: Heuristic Fallback (No Status Line)

When status line bridge is unavailable (non-interactive sessions, background
threads), use heuristic signals:

```bash
# Count tool calls from audit trail
TOOL_COUNT=$(wc -l < "$PROJECT_DIR/.claude/audit/tool-calls.jsonl" 2>/dev/null || echo 0)

# Heuristic thresholds (calibrated from observed sessions):
#   ~200 tool calls ≈ 100k tokens (varies by tool, Read is heavy)
#   ~300 tool calls ≈ 150k tokens (warning zone)
#   ~400 tool calls ≈ 180k tokens (danger zone)
WARN_TOOLS="${CONTEXT_WARN_TOOLS:-300}"
HARD_TOOLS="${CONTEXT_HARD_TOOLS:-400}"
```

**Heuristic accuracy:** Low. Tool calls vary enormously in context cost (a
`Read` of a 2000-line file vs a `Bash(ls)` differ by 50x). Best used as
supplement, not primary signal.

Better heuristic: weight by tool type from audit trail:

| Tool | Estimated tokens per call |
|---|---|
| Read | 2000-8000 (median ~4000) |
| Bash | 500-5000 (median ~1500) |
| Write | 500-2000 |
| Edit | 200-500 |
| Agent (result) | 1000-3000 |
| WebSearch | 2000-6000 |

A weighted sum from audit trail gives ±20% accuracy vs actual.

---

## Edge Cases

### 1. Already past threshold when hook deploys

**Problem:** Thread started before hook was added. Already at 160k tokens.

**Mitigation:** First run of hook after deploy checks state immediately. If
already past hard gate, the very first tool call triggers forced handover. No
retroactive warning possible — but the gate still fires.

### 2. Mid-operation gate fire

**Problem:** Agent is in step 3 of a 5-step file edit when hard gate fires.

**Mitigation:**
- Warning phase (75%) gives buffer for in-progress operations
- Hard gate exempts `Write` to handover path AND `Edit` for files already open
- Agent instructions: "If you receive a hard gate, finish current atomic
  operation (commit, file write), then handover"
- PreToolUse can track "in-flight" state via a lock file

### 3. Handover consumes context

**Problem:** Writing a detailed handover at 90% adds more tokens.

**Mitigation:**
- Handover template is concise by design (~500-1000 tokens)
- Hard gate at 90% leaves 10% headroom (~20k tokens) — enough for handover
- Handover write is exempted from gate

### 4. Multi-hop chains (thread 1 → 2 → 3)

**Problem:** Intent drifts across handovers. Thread 3 doesn't understand original
task.

**Mitigation:**
- Every handover carries the **original task description** verbatim
- Chain file links back to all predecessors
- Master-orchestrator accumulates: if chain length > 2, master reads all
  handovers and writes a **consolidated prompt** for thread 3
- Hard limit: if chain reaches 4 hops, escalate to operator — something is
  wrong with task scoping

### 5. Status line not updating

**Problem:** State file is stale (status line crashed, non-interactive session).

**Mitigation:**
- State file includes timestamp; hook checks staleness
- If state file > 5 minutes old, fall back to heuristic (tool call count)
- Log warning: "context state stale, using heuristic"

---

## Implementation Options

### Option A: Pure Hook-Based (Recommended — works today)

| Component | Effort | Files |
|---|---|---|
| Enhance `statusline.sh` | Small | `scripts/statusline.sh` |
| New `context-safety-catch.sh` | Medium | `scripts/hooks/context-safety-catch.sh` |
| Register in `settings.json` | Trivial | `.claude/settings.json` |
| Handover template | Small | `docs/templates/handover.md` |
| Heuristic fallback | Small | Built into hook script |

**Total: ~2-3 hours implementation, works immediately.**

Limitations:
- Status line bridge adds one file I/O per tool call (negligible)
- Latency of one API round-trip between actual usage and hook reading it
- Heuristic fallback is imprecise for background/non-interactive sessions

### Option B: T3 Native Feature (Upstream request)

T3 `t3_thread_read` already returns `itemCount`. If it also returned
`tokenUsage` or `contextPercentage`, the master could monitor child threads
directly without the status line bridge.

**Requires:** Feature request to T3 team. Unknown timeline.

**Value:** Master-orchestrator could monitor all threads from one place.

### Option C: Master-Orchestrator Skill Integration

Build handover awareness into the master-orchestrator skill (see
`project-master-orchestrator.md` memory). Dispatch always includes handover
instructions. Master reads handover files in monitoring loop.

**Requires:** Option A as foundation + skill enhancement.

**Value:** Fully automated chain management. Operator sees only results, not
handover mechanics.

---

## Recommended Implementation Order

1. **Phase 1 — Bridge + Warning** (Option A, partial)
   - Enhance `statusline.sh` to write context state
   - Add `context-safety-catch.sh` with warning only (no hard gate yet)
   - Register in `settings.json`
   - Validate: run a long session, observe warnings firing

2. **Phase 2 — Hard Gate + Handover**
   - Add hard gate logic with Write exemption
   - Create handover template
   - Add handover write instructions to CLAUDE.md
   - Validate: intentionally fill context, observe gate + handover

3. **Phase 3 — Master Integration** (Option C)
   - Add handover monitoring to master-orchestrator
   - Implement continuation dispatch
   - Add chain tracking
   - Validate: dispatch thread, let it hit limit, observe auto-continuation

4. **Phase 4 — Upstream** (Option B)
   - File feature request with T3 for thread-level token exposure
   - If shipped, replace status line bridge with direct read for T3 threads

---

## Open Questions

1. **Threshold calibration:** 75% warning / 90% hard gate based on 200k window.
   Need empirical data — does quality degrade at 150k? 170k? The 1M context
   model may have different characteristics.

2. **Compaction interaction:** Auto-compact fires before context is truly full.
   After compaction, `used_percentage` drops. Should the hook reset its warning
   state after a `PostCompact` event? Probably yes — but compaction itself loses
   detail, so a warning before compaction is still valuable.

3. **Cost signal:** `cost.total_cost_usd` from status line could be a secondary
   gate — "this thread has spent $X, consider wrapping up." Useful for operator
   awareness but not safety-critical.

4. **Hook protocol clarification:** Need to verify exact JSON format for
   PreToolUse `decision: "block"` — the hook protocol exit codes and output
   format for blocking vs allowing need testing.

---

## References

- [Claude Code Hooks docs](https://code.claude.com/docs/en/hooks.md)
- [Claude Code Status Line docs](https://code.claude.com/docs/en/statusline.md)
- Existing hooks: `scripts/hooks/audit-trail.sh` (pattern reference)
- Existing statusline: `scripts/statusline.sh` (enhancement target)
- Memory: `project-master-orchestrator.md` (orchestrator integration target)
