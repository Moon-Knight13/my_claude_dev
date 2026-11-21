# Glossary

Canonical terms for this repository. Use these exact terms in skills,
docs, hooks, and conversation. When a term has an "Avoid" list, do not
use those synonyms — they create ambiguity.

## Architecture

| Term | Definition | Avoid | See also |
|------|-----------|-------|----------|
| hub | The primary devcontainer that serves as the operating environment for Claude Code sessions. Wires up MCP servers, SSH proxy chains, safety gates, and mode-specific configuration. | "controller", "master node", "orchestrator box" | spoke |
| spoke | A remote system the hub connects to via SSH proxy chain or MCP. Each spoke provides a specific capability (weapons, deployment, research). | "satellite", "node", "remote" | hub, Kali spoke, deploy box |
| Kali spoke | The weapons spoke running Tuoni C2. Primary channel for offensive operations. SSH is fallback. | "attack box", "weapons box" | spoke, C2 |
| deploy box | The spoke hosting the catapult container and ctp-bridge gate. Used for range infrastructure deployment. | "build server" | spoke, ctp-bridge, catapult |
| truth hierarchy | Conflict resolution order for data sources: Providentia > deploy box > Kali state (authoritative); GitLab > Outline wiki > Obsidian vault (reference). | "priority chain" | Providentia |
| proxy chain | The SSH path from container to host to spoke. All spoke access routes through this chain. | "tunnel" | spoke |

## Modes and Routing

| Term | Definition | Avoid | See also |
|------|-----------|-------|----------|
| mode | An operational context that configures OPSEC rules, MCP servers, skill filtering, and system prompt injection. Stored in `.claude/.active-mode`. | "profile", "environment" | mode-inject, skill-mode-gate |
| mode-inject | The UserPromptSubmit hook (`scripts/hooks/mode-inject.sh`) that injects the active mode's system prompt and filtered skill list into every prompt. Soft guidance layer. | | skill-mode-gate |
| skill-mode-gate | The PreToolUse hook (`.claude/hooks/skill-mode-gate.sh`) that denies Skill tool calls when the active mode is not in the skill's `modes:` frontmatter. Hard enforcement layer. | | mode-inject |
| mode override | A per-session mode set via `MODE: <name>` directive in a dispatched thread's first prompt. Stored in `.claude/.mode-overrides/$SESSION_ID`. | | mode |
| dispatch | Sending work to a T3 thread or subagent with explicit mode, model, and workspace configuration. Master session dispatches; threads execute. | "delegate", "spawn" | worktree strategy |
| worktree strategy | The git isolation method for dispatched threads. `workspaceStrategy: worktree` for editing threads; root checkout for read-only tasks. | "branch strategy" | dispatch |

## Skills and Hooks

| Term | Definition | Avoid | See also |
|------|-----------|-------|----------|
| skill | A packaged set of instructions in `.claude/skills/<name>/SKILL.md` with YAML frontmatter. The model invokes skills via the Skill tool. May be mode-gated. | "plugin" (different thing), "prompt" | command |
| command | A user-invoked slash command in `.claude/commands/<name>.md`. Only triggered by operator typing `/<name>`. | "slash skill" | skill |
| hook | A shell script triggered by Claude Code lifecycle events (UserPromptSubmit, PreToolUse). Configured in `.claude/settings.json`. | "callback", "trigger" | guard, gate |
| guard | A hook that validates conditions and blocks actions that violate safety rules. Returns deny JSON on failure. Fail-closed (`exit 2` on error). | "validator" | gate, hook |
| gate | A mandatory checkpoint in a skill's procedure that must pass before proceeding. Defined in skill text, not hooks. | "checkpoint" | guard, research gate |
| research gate | The mandatory checkpoint in initial-access that verifies per-service CVE/technique research exists in Obsidian before any exploitation attempt. | | gate |
| mini variant | A condensed `SKILL.mini.md` alongside the full `SKILL.md`. Retains all safety rules; strips detailed workflows. For subagent dispatch. | "lite", "summary" | skill |

## Safety

| Term | Definition | Avoid | See also |
|------|-----------|-------|----------|
| ctp-bridge | The only authorized path to run catapult (`ctp`) commands. Gates on live inventory query and explicit override. No `ASSUME_YES`. | "deploy script" | catapult, deploy box |
| catapult | The deployment tool (`ctp`) running in a container on the deploy box. All access through ctp-bridge. | "ctp" (use for the CLI itself) | ctp-bridge |
| killswitch | Credential shredding mechanism that activates when no live SSH session exists. Removes tokens and passwords stored outside workspace. | | |
| provenance | Tracking of tool call origins and data lineage. Hook at `.claude/hooks/pretooluse-provenance.sh` logs to `.claude/audit/provenance.jsonl`. | "audit trail" (broader) | |
| pre-flight | A connectivity or readiness check run before switching to an operational mode or starting an engagement. Verifies spoke access, MCP health, DNS. | "health check" (different scope) | exercise zone |

## Engagement

| Term | Definition | Avoid | See also |
|------|-----------|-------|----------|
| engagement | A scoped security-testing operation against authorized targets. State tracked in Obsidian (`llm-wiki/wiki/engagements/<id>.md`) with a thin YAML gate file. | "operation", "campaign" | target |
| target | A host in scope for an engagement. Has a classification lifecycle: candidate → confirmed → compromised/hardened/patched. | "box", "machine", "victim" | target classification |
| target classification | The lifecycle state of a target: `candidate` (nominated), `confirmed` (reachable + approved), `compromised` (access gained), `hardened` (3+ techniques failed), `patched` (CVE confirmed fixed), `unreachable` (no route). | | target |
| foothold | A compromised host with confirmed persistence (operational + sleeper beacons). Used as a pivot point for further operations. | "beachhead" | beacon, persistence round |
| beacon | A Tuoni C2 agent callback on a target. Two types: operational (short interval, ~30s) and sleeper (long interval, ~6h). | "agent" (ambiguous with Claude agent), "implant" | persistence round |
| persistence round | A deployment cycle of dual beacons. Round 1: low-privilege on initial access. Round 2: high-privilege after escalation. Both rounds mandatory. | "persist phase" | beacon, foothold |
| Phase 0 | The initial reachability + service enumeration scan run once per engagement start from Kali. Results go to Obsidian. No subsequent phase re-scans. | "initial scan" | recon |

## Infrastructure

| Term | Definition | Avoid | See also |
|------|-----------|-------|----------|
| MCP | Model Context Protocol server providing tools to Claude Code. Configured in `.mcp.json` files per mode. | "plugin" (different thing) | spoke |
| Providentia | The authoritative CMDB (Configuration Management Database) for range infrastructure. Queried via range-intel MCP. Top of truth hierarchy. | "inventory", "CMDB" (use Providentia specifically) | truth hierarchy |
| range | The authorized network environment used for training and security testing. All operations confined to one range. | "lab", "environment" | exercise zone |
| exercise zone | A specific area within the range designated for active security testing. Pre-flight gateway ping required before operations. | "target zone" | range, pre-flight |
| blind mode | Recon mode activated when Providentia is unavailable or returns empty, or engagement is `type: black-box`. Replaces authoritative data with live scanning. | "dark mode" | degraded mode |
| degraded mode | Operating state when Kali spoke is unavailable (`degraded_mode: router-only`). Limited tooling via router agents only. | "fallback mode" | blind mode |

## Offensive Operations

| Term | Definition | Avoid | See also |
|------|-----------|-------|----------|
| C2 | Command and Control. The Tuoni server on Kali spoke managing agents on targets. All C2 interactions through tuoni-mcp, never direct API. | | beacon, Kali spoke |
| OPSEC | Operational Security. Rules governing detection avoidance: no Metasploit defaults, no tools uploaded to targets, credential testing limits, payload naming conventions. | | |
| LOLBin | Living Off the Land Binary. Native OS binaries usable for offensive purposes without uploading tools. Queried via lolbins-mcp. | "LOLBAS" (Windows-specific subset) | |
| pivot | Using a compromised host to reach network segments not directly accessible from Kali. Classified as OFFENSIVE-PIVOT (can reach targets) or C2-ONLY (callback only). | "hop" | foothold |
