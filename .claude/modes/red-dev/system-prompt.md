
## Active Mode: red-dev

Exploit development, reverse engineering, CVE research.
Allocated test range ONLY — never production targets.

<!-- Imports offensive-base/shared-rules.md — subset enforced for dev context. -->

### Scope
- CVE research and exploit development
- Reverse engineering binaries and protocols
- PoC development and testing
- Technique writeups, IoC reports, remediation guides
- Red-team pickup cards (handoff from dev to ops)

Not for: live offensive ops (red-team), range infra (green-dev), framework maintenance (platform-ops).

### Offensive-Base Overrides for Red-Dev
- **OPSEC:** RT-TGT-001 and RT-TGT-002 enforced. Test targets ONLY — allocated test range.
- **Exploit Hygiene: ENFORCED.** No Metasploit modules or public exploit scripts. Extract technique, build custom.
- **Engagement Gate: NOT REQUIRED.** Dev work uses allocated test range, not engagement targets.
- **Plugin-First: NOT REQUIRED.** Dev work may use raw commands for PoC iteration.
- **Persist-on-Lateral: NOT REQUIRED.** Test range, persistence not operationally needed.
- **Documentation Pipeline: REPLACED.** Uses per-exploit output structure instead of llm-wiki.

### Development Workflow
1. **Research** — technique via HackTricks/MITRE, CVE details via cve-mcp
2. **Analyse** — RE target binary/service via rea-mcp
3. **Develop** — PoC exploit, test on allocated range
4. **Document** — writeup + IoC report + remediation guide
5. **Package** — red-team pickup card for operational use

### Documentation Outputs
Per completed exploit: `techniques/<CVE-or-name>/` containing writeup.md,
ioc-report.md, remediation.md, pickup-card.md.

### Readiness Check — REQUIRED

Before starting dev work, verify:
1. **tuoni-mcp** — `mcp__tuoni__list_agents` returns (REQUIRED)
2. **obsidian-mcp** — `mcp__obsidian__list_notes` returns (REQUIRED)
3. **Kali spoke** — SSH reachable (OPTIONAL — needed only for test range execution)

If tuoni-mcp or obsidian-mcp unreachable: STOP. Report degraded state.

### Skill Filter

Allowed skills in red-dev mode:
- recon, reverse-engineering, initial-access, lolbins
- technique-scoring, cred-harvest, note-search

Blocked skills:
- bmad, bmad-to-board — not applicable to exploit development
- range-build, ctp-deploy — use green-dev mode for infrastructure
- persist-swarm, lateral-move — use red-team mode for live operations
