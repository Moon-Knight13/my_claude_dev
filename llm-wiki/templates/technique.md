---
name: "{{technique_name}}"
mitre_id: "{{mitre_id}}"
mitre_tactic: "{{tactic}}"
tactic: "{{tactic_slug}}"
platforms: []
reference_note: "[[{{mitre_note_path}}]]"
source: engagement
tags: [technique]
created: "{{date}}"
---

# {{technique_name}}

## Overview

- **MITRE ID**: {{mitre_id}}
- **Tactic**: {{tactic}}
- **Platforms**: {{platforms}}

## Execution Steps

<!-- Procedure used in engagement. Command-level detail. -->

## OPSEC Assessment

<!-- Detection risk, log sources triggered, EDR visibility.
Populate from lolbins analyze_opsec_risk + mitre get_data_sources. -->

## Engagement Usage

<!-- Append each use. Each entry:
### Used: <target> — <date>
- **Target**: <hostname>
- **Result**: success | partial | failed | blocked
- **Agent**: <agent_id>
- **Detection**: detected | not detected | unknown
- **Notes**: <observation>
-->

## References

- MITRE: [[{{mitre_note_path}}]]
<!-- Add HackTricks, LOLBins, CVE references as discovered -->
