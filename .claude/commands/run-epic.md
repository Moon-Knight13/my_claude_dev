---
name: run-epic
description: "/run-epic — Orchestrate an epic's stories across T3 threads"
modes: [platform-ops, dev]
---

# /run-epic — Orchestrate an epic's stories across T3 threads

Take ownership of an epic and drive its child stories to completion, fanning work
out to T3 threads (one per story, each in its own worktree) without collisions.

## Preconditions

- Board subsystem is enabled: check `source scripts/lib/subsystems.sh && subsystem_enabled BOARD`.
  If disabled (`SUBSYSTEM_BOARD=false` in `template.conf`), stop and tell the user
  the board subsystem is off — use plain GitHub issues instead.

## Usage

`/run-epic <epic-issue#>`

## Instructions

1. Take epic ownership (so two sessions don't fan out the same epic):
   `bash scripts/board.sh claim <epic#>` on the epic issue. If it returns exit
   code 3, someone already owns it — stop and report who.

2. Read the epic (`gh issue view <epic#>`) and collect its child stories from the
   checklist / linked issues. For each child, read its board **Route** and skip
   any that are already assigned, `wip`, or not `Ready` + `agent-ready`.

3. Decide concurrency:
   - **Parallel** (default when stories are independent): launch one T3 thread
     per ready story using `t3_thread_launch` with worktree isolation so each
     works in its own git worktree and they cannot clobber each other's files.
   - **Sequential**: if stories share files or have ordering dependencies, hand
     back the claimed list and work them one at a time via `/next-issue`.

4. **Dispatching a story thread** — for each parallel story, call
   `t3_thread_launch` with:
   ```
   title: "Epic #<epic#> — Story #<story#>: <short description>"
   message: |
     MODE: platform-ops

     You are working story #<story#> for epic #<epic#>.
     Follow the /next-issue steps for issue #<story#>:
     claim → branch → implement → PR (Closes #<story#>) → move to In Review.

     Context from epic: <relevant context from parent epic>

     Acceptance criteria: <paste from issue>
   workspaceStrategy:
     type: worktree
     baseRef: origin/main
     startFromOrigin: true
   runtimeMode: full-access
   ```
   Use `runtimeMode: "full-access"` — this repo contains offensive security
   content and `auto` mode classifier blocks writes due to context bleed.

5. Respect Route per story:
   - `Route=Human` stories are surfaced to the user rather than dispatched.
   - `Route=Local` stories are dispatched with instructions to run via
     `scripts/delegate-local.sh`. If delegation returns `VERDICT: ESCALATE`,
     the thread should re-run with normal Claude implementation — the escalation
     reason is already logged to `.ai/route-log.jsonl`.
   - `Route=Claude` — dispatch normally as above.

6. **Monitor dispatched threads** — after launching all story threads, use
   `ScheduleWakeup` to self-monitor. On each wakeup:
   - Check thread status with `t3_thread_read` for each dispatched thread.
   - Report completions and failures to the user.
   - If a thread is stuck or failed, surface it for operator decision.
   - Continue waking until all stories are resolved.

7. As stories reach In Review, keep the epic's checklist updated. When all
   children are Done, move the epic: `bash scripts/board.sh move <epic#> done`
   (or In Review if it needs a final integration PR), and report status.

8. If you claimed the epic but cannot proceed, `bash scripts/board.sh release
   <epic#>` so someone else can take it.

**Golden rule:** each story is claimed exactly once; never touch an assigned or
In-Progress card. The board is the single source of who's on what.

**Dispatch rule:** master session is a router only — never switch modes, never
implement stories directly. All implementation goes through dispatched threads.
