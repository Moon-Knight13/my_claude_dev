---
hostname: "{{hostname}}"
ip: "{{ip}}"
os: "{{os}}"
domain: "{{domain}}"
role: "{{role}}"
team: "{{team}}"
source: engagement
tags: [target, intake]
created: "{{date}}"
engagement: "{{engagement_id}}"
---

# {{hostname}}

## Host Profile

| Field | Value |
|-------|-------|
| Hostname | {{hostname}} |
| IP | {{ip}} |
| OS | {{os}} |
| Domain | {{domain}} |
| Role | {{role}} |
| Team Assignment | {{team}} |

## Services

<!-- Populate from Providentia range_host data -->

## Findings

<!-- Append findings as discovered. Each entry:
### Finding: <technique_name> — <date>
- **Technique**: <MITRE T-ID>
- **Result**: success | partial | failed | blocked
- **Agent**: <agent_id>
- **Notes**: <details>
-->

## Credentials

<!-- REFS ONLY — no plaintext passwords, hashes, keys, or tokens.
### Cred Ref: <ref_id>
- **Username**: <user>
- **Type**: password | hash | ticket | key | token
- **Tuoni Cred ID**: <id>
- **Source Technique**: <technique>
-->

## Persistence

<!-- Record persistence mechanisms deployed on this host.
### Persist: <mechanism> — <date>
- **Type**: cron | systemd | authorized_keys | registry | service
- **Beacon**: operational (short) | sleeper (long)
- **Agent ID**: <id>
-->

## Network Position

<!-- Routing, segments, adjacencies discovered during engagement -->
