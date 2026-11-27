# Command Queue Preview with OPSEC Ratings

**Issue:** #352
**Status:** Design
**Author:** MoonKnight13
**Date:** 2026-11-27

## Problem

During FORGE CTF, 437 commands executed via tuoni-mcp with zero
pre-execution operator review. The harness fires commands as fast as it
plans them through the `commands_search → command_describe →
command_prepare → operation_execute` pipeline. No gate exists between
"harness decides to run a command" and "command reaches the target."

Impact: operator cannot assess cumulative OPSEC risk of a batch, cannot
veto high-noise commands before they fire, cannot see what is about to
happen.

## Goals

1. Operator sees every queued command with its OPSEC rating before execution.
2. Batch summary shows aggregate noise level.
3. Operator can approve all, review individually, skip by rating, or abort.
4. Zero change to single-command interactive flow (operator already sees
   tool calls in real time).
5. Integrates with existing `config/opsec-classifier.yaml` (16 commands
   mapped) and `scripts/opsec-classify.sh`.

## Non-Goals

- Automatic command rewriting or substitution.
- Blocking single interactive commands (existing tool-approval handles that).
- Modifying tuoni-mcp itself.

## Architecture

### Current Flow

```
Skill (discovery/initial-access/etc.)
  → tuoni_commands_search   (find command by name)
  → tuoni_command_describe  (get parameters)
  → tuoni_command_prepare   (build payload, returns operation_id)
  → tuoni_operation_execute (fires on target)
```

Each step is a separate MCP tool call. Skills call them sequentially,
often in loops across multiple commands within a single thread. The
harness shows each tool call to the operator in the approval flow, but
there is no batch-level preview and no OPSEC metadata attached.

### Proposed Flow

```
Skill plans N commands
  → tuoni_command_prepare × N  (each returns operation_id + command metadata)
  ──── NEW: Queue Preview Gate ────
  → PreToolUse hook on tuoni_operation_execute
    1. Collects pending operation_id from tool_input
    2. Looks up command name → opsec-classifier.yaml rating
    3. If batch mode active: accumulates into queue, presents when batch complete
    4. If single mode: shows inline OPSEC card, proceeds per approval
  → Operator decision: execute / skip / abort
  → tuoni_operation_execute (fires approved commands only)
```

### Interception Point: PreToolUse on `tuoni_operation_execute`

The hook fires on every `mcp__tuoni-mcp__tuoni_operation_execute` call.
This is the right interception point because:

- `command_prepare` has already built the payload (operation_id exists).
- The command metadata (name, arguments, target) is known.
- Execution has not happened yet — the hook can deny.
- All skills converge through this single tool call.

Alternative considered: intercepting at `command_prepare`. Rejected
because prepare is non-destructive (creates an operation, does not
execute it) and some workflows prepare multiple commands before executing.

### Batch Detection

The hook needs to distinguish "single interactive command" from "batch
of commands planned by a skill." Detection mechanism:

**Skill-driven batch markers.** Skills that plan multiple commands set an
environment variable or write a marker file before the loop:

```
# Skill sets batch context
OPSEC_BATCH_ID=<uuid>
OPSEC_BATCH_SIZE=<expected count>
OPSEC_BATCH_CONTEXT=<phase name, e.g. "discovery-host-enum">

# Each command_prepare call registers with the queue
# The PreToolUse hook on operation_execute accumulates

# After last prepare, skill signals batch complete
# Hook renders the full queue preview
```

Implementation: batch state lives in a temp file keyed by session ID
(`/tmp/claude-opsec-queue-${SESSION_ID}.json`). The hook accumulates
entries. When accumulated count equals expected batch size, or when a
configurable timeout elapses, the hook renders the preview and blocks
until operator responds.

For single commands outside a batch context, the hook shows an inline
OPSEC card and proceeds through normal tool approval.

## OPSEC Rating System

Ratings reuse `config/opsec-classifier.yaml` definitions exactly:

| Rating | Criteria | Requires Confirmation |
|--------|----------|----------------------|
| **CRITICAL** | Triggers well-known EDR/SIEM signatures. Near-certain detection on monitored hosts. | Yes |
| **HIGH** | Detectable by tuned defences (Sysmon, custom YARA, ETW). | Yes |
| **MEDIUM** | Leaves forensic artefacts (logs, temp files, registry keys). | No (default) |
| **LOW** | Passive or read-only. No new processes, no disk writes. | No |
| **UNKNOWN** | Command not in classifier. | Yes (fail-closed) |

### Unknown Command Handling

Commands not present in `opsec-classifier.yaml` receive UNKNOWN rating
and require confirmation. This ensures new tuoni-plugins commands cannot
bypass review. The queue preview flags them prominently:

```
⚠ UNKNOWN — not in OPSEC classifier: tuoni_new_command
  Action required: add to config/opsec-classifier.yaml before batch approval
```

### Aggregate Noise Score

Batch summary computes an aggregate noise estimate:

```
Noise score = max(individual ratings) weighted by count
  CRITICAL = 10, HIGH = 7, MEDIUM = 4, LOW = 1, UNKNOWN = 10
  Aggregate = (sum of scores) / (count × 10) × 10, clamped to 1-10
```

This produces the summary line from the issue:
`"4 CRITICAL, 1 HIGH — estimated noise 9/10"`

## Queue Display Format

### Batch Preview (terminal output)

```
╔══════════════════════════════════════════════════════════════╗
║  COMMAND QUEUE PREVIEW — discovery-host-enum                ║
║  Target: 10.10.14.5 (agent: abc-123)                       ║
╠══════════════════════════════════════════════════════════════╣
║                                                              ║
║  #  Command              Rating     MITRE        Detection   ║
║  ── ──────────────────── ────────── ──────────── ─────────── ║
║  1  tuoni_net_recon      LOW        TA0007       network     ║
║  2  tuoni_host_id        LOW        TA0007       event_log   ║
║  3  tuoni_ad_enum        MEDIUM     TA0007       event_log   ║
║  4  tuoni_cred_dump      CRITICAL   TA0006       process,etw ║
║  5  tuoni_token_steal    CRITICAL   TA0006       api,token   ║
║                                                              ║
║  Summary: 2 CRITICAL, 1 MEDIUM, 2 LOW                       ║
║  Estimated noise: 7/10                                       ║
║                                                              ║
║  CRITICAL commands:                                          ║
║    #4 tuoni_cred_dump — alternative: nanodump (direct        ║
║       syscalls, no process_name hit)                         ║
║    #5 tuoni_token_steal — alternative: handle duplication    ║
║       (lower API hook signature)                             ║
║                                                              ║
╠══════════════════════════════════════════════════════════════╣
║  [A] Execute all  [R] Review each  [S] Skip CRITICAL        ║
║  [E] Edit queue   [X] Abort batch                            ║
╚══════════════════════════════════════════════════════════════╝
```

### Single Command Card (inline)

```
┌─ OPSEC: tuoni_cred_dump ──────────────────────────────────┐
│ Rating: CRITICAL — near-certain detection on monitored hosts│
│ MITRE: TA0006 / T1003 (Credential Dumping)                 │
│ Detection: process_name, commandline_string, etw_amsi      │
│ Alternative: nanodump (direct syscalls)                     │
│ Requires confirmation: YES                                  │
└────────────────────────────────────────────────────────────┘
```

## Operator Approval Flow

### Batch Mode Options

| Key | Action | Behavior |
|-----|--------|----------|
| **A** | Execute all | Run every command in queue order |
| **R** | Review each | Step through one at a time, approve/skip each |
| **S** | Skip by rating | Skip all commands at or above a chosen rating (e.g., skip CRITICAL) |
| **E** | Edit queue | Remove specific commands by number, then re-preview |
| **X** | Abort | Cancel entire batch, return control to skill |

### Review-Each Sub-flow

When operator selects **R**, each command shows its full OPSEC card.
Operator presses **Y** (execute), **N** (skip), or **X** (abort remaining).
Skipped commands are logged with reason "operator-skipped" in the audit
trail.

### Skill Response to Partial Execution

Skills must handle partial execution gracefully. When commands are
skipped:

1. The queue returns a result set indicating which operation_ids executed
   and which were skipped.
2. Skills check execution results before proceeding. Discovery skill
   already handles individual command failures — same pattern.
3. Skipped-command metadata is written to the engagement page under
   `§ Operator Decisions` for post-engagement review.

## Integration Points

### 1. PreToolUse Hook (`scripts/hooks/opsec-queue-preview.sh`)

New hook registered in `.claude/settings.json` with matcher:
`mcp__tuoni-mcp__tuoni_operation_execute`

Hook reads:
- `tool_input.operation_id` from stdin
- Batch state from `/tmp/claude-opsec-queue-${SESSION_ID}.json`
- Rating from `config/opsec-classifier.yaml` via `scripts/opsec-classify.sh`

Hook outputs:
- In batch mode with batch incomplete: accumulate silently, exit 0
- In batch mode with batch complete: render preview, block for input
- In single mode: render OPSEC card, proceed per rating policy
- Deny JSON when operator aborts or skips a command

### 2. Skill Batch Protocol

Skills opt into batch mode by calling a helper before their command loop:

```bash
# scripts/opsec-queue.sh — batch lifecycle
opsec-queue.sh start --context "discovery-host-enum" --size 5
# ... commands prepare and execute ...
opsec-queue.sh end
```

Or via environment variables that the hook reads:
```
OPSEC_BATCH_ID, OPSEC_BATCH_SIZE, OPSEC_BATCH_CONTEXT
```

Skills that do not set batch context get single-command inline cards.

### 3. OPSEC Classifier (`config/opsec-classifier.yaml`)

No schema changes needed. Existing `commands:` section maps command names
to ratings. The `--batch` and `--summary` modes of `opsec-classify.sh`
already produce the data the queue preview needs.

New requirement: classifier coverage must include ALL tuoni-plugins
commands. CI test `scripts/ci/test-opsec-classifier.sh` should gain a
coverage check: compare classifier keys against tuoni-plugins dist/ and
fail if any are missing.

### 4. Audit Trail

`scripts/hooks/audit-trail.sh` already logs every tool call. Extend to
capture:
- Queue preview shown (batch ID, commands, ratings)
- Operator decision (execute-all, review-each, skip-critical, edit, abort)
- Per-command decisions in review-each mode
- Skipped commands with reason

Format: append to `.claude/audit/command-queue.jsonl`:
```json
{
  "timestamp": "2026-11-27T14:30:00Z",
  "batch_id": "uuid",
  "context": "discovery-host-enum",
  "commands": [
    {"name": "tuoni_cred_dump", "rating": "critical", "decision": "skipped", "reason": "operator-skip-critical"}
  ],
  "aggregate_noise": 7,
  "operator_action": "skip-critical"
}
```

### 5. Engagement Skills

Skills affected (all use `command_prepare → operation_execute` loops):
- `discovery/SKILL.md` — host enumeration batch (5-15 commands)
- `initial-access/SKILL.md` — exploit execution (1-3 commands)
- `cred-harvest/SKILL.md` — credential dump sequence (2-5 commands)
- `flag-hunt/SKILL.md` — file search commands (3-8 commands)
- `ai-indicator-cleanup/SKILL.md` — cleanup commands (2-6 commands)
- `lateral-move/SKILL.md` — movement + persist (3-7 commands)
- `persist-swarm/SKILL.md` — beacon deployment (2-4 commands)

Each skill needs:
1. Batch start/end markers around command loops.
2. Result checking for skipped commands.
3. Graceful degradation when commands are removed from queue.

### 6. LOLBins Integration

`lolbins-mcp analyze_opsec_risk` already produces risk assessments for
individual techniques. The queue preview can optionally call this for
commands not in the classifier, using the LOLBins rating as a fallback
before defaulting to UNKNOWN.

Priority chain:
1. `opsec-classifier.yaml` — authoritative for tuoni-plugins commands
2. `lolbins-mcp analyze_opsec_risk` — fallback for raw OS commands
3. UNKNOWN — fail-closed default

## Mode Applicability

Queue preview activates in these modes only:
- `red-team` — full enforcement
- `red-dev` — full enforcement
- `purple` — full enforcement
- `engagement-orchestration` — full enforcement (master dispatches threads that use it)

Other modes (green-dev, homelab, etc.) never invoke tuoni-mcp offensive
tools, so the hook is a no-op outside these modes. The hook checks
`.claude/.active-mode` and exits early for non-applicable modes, same
pattern as `mode-tool-gate.sh`.

## Implementation Stories

### Story 1: PreToolUse Hook — Single Command OPSEC Card
**Size:** S
**Depends on:** nothing

New hook `scripts/hooks/opsec-queue-preview.sh` registered on matcher
`mcp__tuoni-mcp__tuoni_operation_execute`. On each call:

1. Extract `operation_id` from tool input.
2. Look up command name from batch state or operation metadata.
3. Call `scripts/opsec-classify.sh --json <command>` for rating.
4. If `requires_confirmation: true` and not already approved, output deny
   JSON with OPSEC card as reason text.
5. If `requires_confirmation: false`, output nothing (allow).
6. Log to audit trail.

Acceptance:
- Hook fires on every `tuoni_operation_execute` call in red-team mode.
- CRITICAL/HIGH commands show OPSEC card and require confirmation.
- MEDIUM/LOW commands pass through.
- UNKNOWN commands require confirmation.
- Hook is no-op outside applicable modes.

### Story 2: Batch Queue State Management
**Size:** M
**Depends on:** Story 1

Batch lifecycle via `scripts/opsec-queue.sh`:

- `start --context <name> --size <n>` — create queue state file
- `add --command <name> --operation-id <id> --args <json>` — append to queue
- `status` — return current queue contents as JSON
- `end` — signal batch complete, trigger preview render
- `clear` — remove state file

State file: `/tmp/claude-opsec-queue-${SESSION_ID}.json`

The PreToolUse hook checks for active batch state. If batch is active
and not yet complete, it accumulates the command and allows `prepare`
but blocks `execute` until batch preview is shown.

Acceptance:
- Batch state file created/destroyed correctly.
- Multiple commands accumulate in order.
- Timeout (configurable, default 60s) auto-renders if batch size not reached.
- State file cleaned up on abort or completion.

### Story 3: Batch Preview Renderer
**Size:** M
**Depends on:** Story 2

Render the batch preview table in terminal output. Input: batch state
JSON. Output: formatted preview with:

- Command table (number, name, rating, MITRE, detection surfaces)
- Aggregate noise score
- CRITICAL command alternatives (from classifier)
- Action menu (A/R/S/E/X)

Implemented as `scripts/opsec-queue-preview-render.sh` called by the
PreToolUse hook when batch is complete.

Acceptance:
- Preview renders correctly for 1-20 command batches.
- Noise score calculation matches spec.
- Alternatives shown for CRITICAL commands.
- Table fits 80-column terminal.

### Story 4: Operator Decision Handler
**Size:** M
**Depends on:** Story 3

Handle operator responses to batch preview:

- **A (Execute all):** mark all commands approved, hook allows each.
- **R (Review each):** step through commands, show individual cards.
- **S (Skip by rating):** prompt for minimum rating to skip, mark those as skipped.
- **E (Edit queue):** prompt for command numbers to remove, re-render preview.
- **X (Abort):** deny all pending executes, return control.

Decision state written back to queue state file. PreToolUse hook reads
approved/skipped status when each `operation_execute` fires.

Acceptance:
- Each action works as specified.
- Partial execution returns correct result set to skill.
- Skipped commands logged with reason.
- Abort stops all pending commands.

### Story 5: Skill Integration — Batch Markers
**Size:** M
**Depends on:** Story 2

Add batch start/end markers to engagement skills:

1. `discovery/SKILL.md` — wrap host-enum command loop
2. `cred-harvest/SKILL.md` — wrap credential dump sequence
3. `flag-hunt/SKILL.md` — wrap search command loop
4. `ai-indicator-cleanup/SKILL.md` — wrap cleanup loop
5. `initial-access/SKILL.md` — wrap exploit execution (may be single)
6. `lateral-move/SKILL.md` — wrap movement sequence
7. `persist-swarm/SKILL.md` — wrap beacon deployment

Each skill documents: batch context name, expected size range, which
commands can be safely skipped without breaking the phase.

Acceptance:
- Each listed skill has batch markers.
- Skills handle partial execution (skipped commands).
- Batch context names are descriptive and unique per phase.

### Story 6: Audit Trail Extension
**Size:** S
**Depends on:** Story 4

Extend `scripts/hooks/audit-trail.sh` to capture queue preview events:

- Batch preview shown (commands, ratings, noise score)
- Operator decision (which action, per-command results)
- Skipped commands with reason

Output: `.claude/audit/command-queue.jsonl` (new file, same directory as
existing audit logs).

Acceptance:
- Every batch preview logged.
- Every operator decision logged.
- Skipped commands traceable.
- JSON format parseable for post-engagement analysis.

### Story 7: Classifier Coverage CI Gate
**Size:** S
**Depends on:** nothing (parallel with Story 1)

Add coverage check to `scripts/ci/test-opsec-classifier.sh`:

1. List all tuoni-plugins command basenames from `dist/` or plugin manifest.
2. List all command keys in `config/opsec-classifier.yaml`.
3. Fail if any plugin command is missing from classifier.
4. Warn if classifier has entries not in plugins (stale entries).

Acceptance:
- CI fails when new tuoni-plugin added without classifier entry.
- Stale entries produce warning, not failure.
- Test runs in existing CI pipeline.

### Story 8: LOLBins Fallback Rating
**Size:** S
**Depends on:** Story 1

When a command is not in `opsec-classifier.yaml`, before defaulting to
UNKNOWN, check if `lolbins-mcp analyze_opsec_risk` can rate it:

1. Hook detects missing classifier entry.
2. Calls `analyze_opsec_risk` with command name and arguments.
3. Maps LOLBins risk assessment to CRITICAL/HIGH/MEDIUM/LOW.
4. Falls through to UNKNOWN only if LOLBins also returns no data.

Acceptance:
- Raw OS commands (not tuoni-plugins) get LOLBins-derived ratings.
- Tuoni-plugins commands still use classifier as authoritative source.
- Fallback chain: classifier → LOLBins → UNKNOWN.

## Dependency Graph

```
Story 7 ──────────────────────────────────────────── (parallel)
Story 1 → Story 2 → Story 3 → Story 4 → Story 5
              │                    │
              └── Story 8          └── Story 6
```

Minimum viable: Stories 1 + 2 + 3 + 4 (batch preview works, skills
not yet instrumented — commands show individual cards).

Full feature: all 8 stories.

## Open Questions

1. **Hook stdin limitations.** PreToolUse hooks receive tool name and
   input as JSON on stdin. The hook cannot prompt the operator
   interactively — it can only deny or allow. The "batch preview with
   menu" may need to work through the deny reason text (operator sees
   the preview in the deny message, then re-invokes with an approval
   flag). Need to prototype this interaction model.

2. **Operation ID to command name mapping.** `tuoni_operation_execute`
   receives an `operation_id` but the hook needs the command name for
   classifier lookup. Options:
   - Batch state file maps operation_id → command name (set during
     `command_prepare` phase)
   - Hook calls tuoni-mcp to look up operation metadata (adds latency)
   - Skill passes command name as extra field (requires tuoni-mcp change)

   Recommended: batch state file approach. The hook for `command_prepare`
   (PostToolUse) captures the mapping.

3. **Thread isolation.** Engagement threads run in worktrees with their
   own session IDs. Queue state files are session-scoped, so parallel
   threads operating on different targets get independent queues. Verify
   this assumption holds for fork agents within a thread.

## Security Considerations

- Queue state files in `/tmp` are session-scoped and short-lived.
  Clean up on batch end, abort, and session exit.
- Deny-by-default for UNKNOWN commands prevents new plugins from
  bypassing review.
- Audit trail captures all operator decisions for post-engagement
  accountability.
- No credentials or command output stored in queue state — only command
  names, operation IDs, and ratings.
