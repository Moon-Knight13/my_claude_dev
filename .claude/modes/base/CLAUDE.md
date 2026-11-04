# Claude Workflow Contract

## Mission
Deliver secure, maintainable software with deterministic quality gates.

## Priority Order
1. Security
2. Correctness
3. Maintainability
4. Delivery speed
5. Token efficiency

## Architecture
Opus 4.6 primary session. MCP servers (tuoni-mcp, range-intel-mcp,
outline-readonly) provide data and execution surfaces. No local model routing.

Backup: OpenCode + OpenRouter with local model if primary unavailable.

## Kanban / Board
*Applies only when `SUBSYSTEM_BOARD=true` in `template.conf`. If it is off, use
plain GitHub issues and ignore this section.*

Work is tracked on a per-repo GitHub Project board (see `docs/KANBAN_WORKFLOW.md`).
- Agents pick up work with `/next-issue`, which claims a card collision-safely
  (`scripts/board.sh claim`: self-assign + `wip` + In Progress + re-check).
- Golden rule: never touch a card that is already assigned or In Progress. One
  branch and one PR (`Closes #<n>`) per story. Orchestrate epics with `/run-epic`.
- All board writes go through `scripts/board.sh` (gh-CLI, no secrets).

## Guardrails
- Never place credentials or tokens in repository files.
- Keep Claude auth in mounted user config outside workspace files.
- Run quality checks before merge: pre-commit, semgrep, gitleaks, CI checks.
- Respect repository protections and required checks.
- Keep `docs/explainer/index.html` in sync with `README.md` and `docs/`. It is a
  hand-authored visual briefing (the README is the source of truth); when the
  architecture, routing, security gates, or component set change, update the explainer in
  the same PR. It is self-contained — no external requests, works offline and via Pages.

## Style
Default response style should be concise and precise.

## Project Instructions
Repository-specific instructions live in `docs/PROJECT.md` — read it as well as
this file. This contract governs security and quality gates; the project file
covers what the repository is and how to operate it.

Deep-dive references (read on demand, not every session):
- `docs/SAFETY_GATES.md` — ctp-bridge, destructive-action gate, git guard, path guard details
- `docs/TROUBLESHOOTING.md` — DNS prereqs, ECONNRESET diagnosis, debug log noise
- `docs/SAFETY_HARNESS.md` — operator/demonstrator view of safety controls

This repository is detached from its template (2026-10-16).
