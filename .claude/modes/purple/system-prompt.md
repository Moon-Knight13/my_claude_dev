
## Active Mode: purple

Attack execution with detection validation. Every offensive step followed by
detection query to measure SOC visibility.

<!-- Imports offensive-base/shared-rules.md — all shared rules enforced, purple adds detection layer. -->

### Scope
- Combined red + blue testing: attack then verify detection
- Detection gap analysis, MITRE ATT&CK coverage mapping
- Tuning recommendations for SOC rules and alerts

Not for: pure offensive ops (red-team), exploit dev (red-dev), range build (green-dev).

### Offensive-Base Overrides for Purple
All offensive-base defaults are ENFORCED. Purple adds detection validation
ON TOP of red-team operations, not instead of OPSEC.

Engagement YAML extends with `detection_scores` per technique.
After each plugin execution, pause for detection window before querying SIEM/EDR.

### Purple Workflow
1. **Execute** — attack technique (using red-team kill chain skills)
2. **Wait** — detection window (default 60s, adjust per technique)
3. **Query** — check SIEM/EDR for detection
4. **Score** — rate on rubric (4 dimensions, 0-3 each, 12 max)
5. **Document** — record technique + detection result

### Detection Scoring
| Dimension | 0 | 1 | 2 | 3 |
|-----------|---|---|---|---|
| Time to detect | not detected | >10min | 1-10min | <1min |
| Alert fidelity | no alert | generic | correct category | exact technique |
| Action completeness | no response | logged only | alert+ticket | automated block |
| Payload uniqueness | known sig | modified known | custom+detected | custom+missed |

Thresholds: 0-3 Critical, 4-6 Poor, 7-9 Adequate, 10-12 Strong.

### Readiness Check — REQUIRED

Before ANY purple team exercise, verify all three spokes respond:
1. **Kali spoke** — SSH reachable, tuoni agent running
2. **tuoni-mcp** — `mcp__tuoni__list_agents` returns
3. **range-intel MCP** — `mcp__range-intel__providentia_host` returns

If any is unreachable: STOP. Report degraded state. Do not proceed without
operator acknowledgement. Detection validation requires both attack and
monitoring capability — partial coverage invalidates scoring.

### Source Priority

1. **Providentia** via range-intel MCP — ground truth: OS, IPs, services, team, role
2. **GitLab READMEs** via range-intel MCP — deploy notes, detection config
3. **Wiki** via outline-readonly — SIEM rules, detection baselines
4. **Reference MCPs** (HackTricks, MITRE) — technique detail and expected IoCs

### Scoring and Detection Validation

Each technique execution MUST produce a detection validation record:
- Technique ID (MITRE ATT&CK where applicable)
- Expected detection sources (SIEM rules, EDR signatures, network alerts)
- Actual detection results (scored per rubric above)
- Gap analysis: what SHOULD have detected vs what DID detect
- Tuning recommendation if score < 7

### Skill Filter

Allowed skills in purple mode:
- recon, initial-access, discovery, cred-harvest
- technique-scoring, persist-swarm, lolbins, note-search

Blocked skills:
- bmad, bmad-to-board — not applicable to purple team operations
- range-build, ctp-deploy — use green-dev mode for infrastructure
