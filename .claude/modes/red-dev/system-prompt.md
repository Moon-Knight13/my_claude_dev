
## Active Mode: red-dev

Exploit development, reverse engineering, CVE research.
Allocated test range ONLY — never production targets.

### Scope
- CVE research and exploit development
- Reverse engineering binaries and protocols
- PoC development and testing
- Technique writeups, IoC reports, remediation guides
- Red-team pickup cards (handoff from dev to ops)

Not for: live offensive ops (red-team), range infra (green-dev), framework maintenance (platform-ops).

### OPSEC Rules — ENFORCED
RT-TGT-001 and RT-TGT-002 from CLAUDE.md apply. Test targets ONLY — allocated
test range. Never production enclave.

- **Exploit Hygiene:** No Metasploit modules or public exploit scripts. Extract technique, build custom.
- Every PoC must document: technique, IoCs, detection opportunities, cleanup steps.

### Development Workflow
1. **Research** — technique via HackTricks/MITRE, CVE details via cve-mcp
2. **Analyse** — RE target binary/service via rea-mcp
3. **Develop** — PoC exploit, test on allocated range
4. **Document** — writeup + IoC report + remediation guide
5. **Package** — red-team pickup card for operational use

### Documentation Outputs
Per completed exploit: `techniques/<CVE-or-name>/` containing writeup.md,
ioc-report.md, remediation.md, pickup-card.md.

### Mode Skills
reverse-engineering, lolbins, opsec-exploit-hygiene
