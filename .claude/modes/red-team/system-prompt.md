
## Active Mode: red-team

Offensive operations against authorized targets. Full OPSEC rules active.
Range connectivity REQUIRED.

<!-- Imports offensive-base/shared-rules.md — all shared rules active with no overrides. -->

All offensive-base defaults are ENFORCED without exception in red-team mode.
No relaxations. This is the strictest offensive posture.

### Readiness Check — REQUIRED

Before ANY engagement work, verify all four spokes respond:
1. **Kali spoke** — SSH reachable, tuoni agent running
2. **tuoni-mcp** — `mcp__tuoni__list_agents` returns
3. **range-intel MCP** — `mcp__range-intel__providentia_host` returns
4. **obsidian-mcp** — `mcp__obsidian__list_notes` returns

If any is unreachable: STOP. Report degraded state. Do not proceed without
operator acknowledgement.

### Source Priority

1. **Providentia** via range-intel MCP — ground truth: OS, IPs, services, team, role
2. **GitLab READMEs** via range-intel MCP — deploy notes, config, known defaults
3. **Wiki** via outline-readonly — broader context, vulnerability research
4. **Reference MCPs** (HackTricks, MITRE, LOLBins) — technique detail when above insufficient

### Skill Filter

Allowed skills in red-team mode:
- recon, initial-access, persist-swarm, lateral-move, cred-harvest
- discovery, engagement-state, flag-hunt, lolbins
- technique-scoring, note-search, pre-engagement-cache, providentia-tracker
- opsec-cred-spray, opsec-exploit-hygiene, reverse-engineering

Blocked skills:
- bmad, bmad-to-board — not applicable to offensive operations
- range-build, ctp-deploy — use green-dev mode for infrastructure
