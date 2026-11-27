# Dispatch Templates

Generalized thread dispatch parameters for master-orchestrator and
mode-specific orchestration skills. Extracted from engagement-orchestration
patterns with three Sandcastle-inspired conventions (#403, Epic F).

## Files

| File | Purpose |
|------|---------|
| `dispatch-template.yaml` | Base template with all fields documented |
| `presets.yaml` | Thread-type presets (deploy, dev, investigation, etc.) |

## Three Sandcastle Patterns

### 1. Iteration Limit (`max_iterations`)

Prevents runaway agent loops. Each preset defines an appropriate ceiling:

| Thread type | Default | Rationale |
|-------------|---------|-----------|
| Deploy | 1 | Single atomic operation |
| Investigation | 5 | Bounded exploration |
| Dev | 10 | Multi-step feature work |
| Engagement | 15 | Multi-phase with gates |

Set to 0 for unlimited (not recommended outside CTF mode).

### 2. Early Stop Signal (`early_stop_signal`)

Agents emit a structured completion signal in their final message:

```
DISPATCH_COMPLETE: { status: "success", artifact: "PR #123" }
DISPATCH_COMPLETE: { status: "failure", artifact: "none" }
DISPATCH_COMPLETE: { status: "handover", artifact: "obsidian://target01" }
```

Coordinator matches `^DISPATCH_COMPLETE:` in thread output. This replaces
polling — the coordinator uses `t3_thread_wait` and reads the signal from
the thread's final output.

The `handover` status triggers continuation dispatch when Epic E chain
management is implemented.

### 3. Commit-Scope Convention (`commit_scope`)

Tags each dispatch prompt with commit expectations:

| Value | Meaning | Thread types |
|-------|---------|-------------|
| `atomic` | Single commit, one logical change | Deploy, hotfix |
| `minimal` | Fewest buildable commits | Dev, refactor |
| `none` | No commits expected | Investigation, review, engagement |

Agents include this in their opening context to scope git operations.

## Usage

Orchestration skills reference these templates when dispatching threads.
The merge order is:

```
dispatch-template.yaml (defaults)
  → presets.yaml[type] (thread-type overrides)
    → per-dispatch overrides (skill or operator)
```

### Prompt injection example

When dispatching a dev thread, the coordinator injects:

```
## Dispatch Parameters
- max_iterations: 10
- commit_scope: minimal
- early_stop_signal: DISPATCH_COMPLETE
- Signal format: DISPATCH_COMPLETE: { status: "success"|"failure"|"handover", artifact: "<ref>" }
```

### Workspace strategy decision

From CLAUDE.md and engagement-orchestration:

- **worktree**: Any thread that writes files (dev, deploy, refactor)
- **root**: Read-only threads (review, investigation, engagement execution)

Engagement threads use `root` because they execute on remote targets via
Kali — they don't modify the local repo.

## Dependency Chaining

The `depends_on` field lists thread IDs that must complete before launch.
Coordinator enforces via `t3_thread_wait`. Example:

```yaml
# Phase 2 exploit depends on Phase 1 recon
- thread_name: exploit-target01
  depends_on: ["recon-target01"]
```

## Error Handling

| Strategy | Behavior |
|----------|----------|
| `report` | Log failure, continue other threads |
| `retry` | Re-dispatch up to `max_retries` times |
| `skip` | Silently continue (reviews, non-critical) |
| `stop_all` | Halt all threads (persist failure = non-negotiable) |
