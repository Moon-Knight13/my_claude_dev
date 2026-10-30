
## Active Mode: purple

Attack execution with detection validation. Every offensive step is followed
by a detection query to measure SOC visibility.

### What this mode is for
- Combined red + blue testing: attack then verify detection
- Detection gap analysis — what the SOC sees vs misses
- MITRE ATT&CK coverage mapping with detection scores
- Tuning recommendations for SOC rules and alerts

### What this mode is NOT for
- Pure offensive ops without detection checks (use red-team)
- Exploit development (use red-dev)
- Range infra build (use green-dev)

### OPSEC Rules — ENFORCED (inherited from red-team)

All RT-TGT, RT-SIG, RT-DEP rules apply. Purple mode adds detection
validation ON TOP of red-team operations, not instead of OPSEC.

#### Target Discipline (RT-TGT)
- **RT-TGT-001:** Explicit operator approval on exact target list.
- **RT-TGT-002:** No offensive tools on target. Kali via SSH tunnel.

#### Identity and Signature (RT-SIG)
- **RT-SIG-001:** Use `root` agent for C2/lateral. No `rt`-prefixed usernames.
- **RT-SIG-002:** Unique payload ID per target.
- **RT-SIG-003:** Platform-appropriate cover filenames.
- **RT-SIG-004:** Right-sized binary padding.

#### Deployment Order (RT-DEP)
- **RT-DEP-001:** ISPs → routers → firewalls → per-enclave: DCs, proxy, mail, workstations.

### Purple Workflow

Every offensive step follows this pattern:

1. **Execute** — run attack technique (using red-team kill chain skills)
2. **Wait** — configurable detection window (default 60s, adjust per technique)
3. **Query** — check SIEM/EDR for detection of the technique
4. **Score** — rate detection on the scoring rubric
5. **Document** — record technique + detection result

### Detection Query Sources

When SIEM/EDR MCPs become available, detection queries run against:
- Wazuh (wazuh-mcp) — host-based alerts, file integrity, rootcheck
- Velociraptor (velociraptor-mcp) — endpoint telemetry, artifacts
- Elastic (elastic-mcp) — log aggregation, correlation rules

Until those MCPs are built, detection validation is MANUAL:
- Operator checks SIEM dashboard after each technique
- Results entered as structured input to scoring

### Detection Scoring Rubric

Each technique scored on 4 dimensions:

| Dimension | Score | Meaning |
|-----------|-------|---------|
| **Time to detect** | 0-3 | 0=not detected, 1=>10min, 2=1-10min, 3=<1min |
| **Alert fidelity** | 0-3 | 0=no alert, 1=generic, 2=correct category, 3=exact technique |
| **Action completeness** | 0-3 | 0=no response, 1=logged only, 2=alert+ticket, 3=automated block |
| **Payload uniqueness** | 0-3 | 0=known sig, 1=modified known, 2=custom+detected, 3=custom+missed |

Total per technique: 0-12. Engagement total: average across all techniques.

### Engagement Scoring Thresholds

| Range | Rating | Meaning |
|-------|--------|---------|
| 0-3 | Critical | SOC blind to most techniques |
| 4-6 | Poor | Detection exists but slow/incomplete |
| 7-9 | Adequate | Most techniques detected, some gaps |
| 10-12 | Strong | Fast, accurate, automated response |

### Source Priority (same as red-team)
1. Providentia — ground truth
2. GitLab READMEs — deploy notes
3. Wiki repo-docs / vulns-docs
4. Tuoni Discovery — live C2 state
5. Obsidian — tactical notes
6. Reference MCPs (HackTricks, MITRE, GTFOBins, eip-mcp)
7. Web research — last resort

### State Writes

Purple mode extends engagement YAML with detection scores:

```yaml
findings:
  - technique_id: T1059.001
    technique_name: PowerShell Execution
    target: host-a
    detection_score:
      time_to_detect: 2
      alert_fidelity: 3
      action_completeness: 1
      payload_uniqueness: 2
      total: 8
    notes: "Detected by Wazuh rule 92100, no automated response"
```

### Available MCP Servers
- tuoni-mcp — C2 operations
- range-intel — Providentia + GitLab READMEs
- outline-readonly — wiki
- obsidian-mcp — tactical notes
- hacktricks-mcp — attack techniques
- mitre-mcp — ATT&CK mapping
- gtfobins-mcp — Unix binary abuse
- local-ollama — code assistance
