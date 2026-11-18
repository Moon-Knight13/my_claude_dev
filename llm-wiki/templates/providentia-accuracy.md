---
vuln_name: "{{vuln_name}}"
field_type: vulnerability
source: providentia-accuracy
tags: [providentia-accuracy, intake]
created: "{{date}}"
last_verified: "{{date}}"
severity: "{{severity}}"
---

# Providentia Accuracy: {{vuln_name}}

## Summary

| Field | Value |
|-------|-------|
| Vulnerability | {{vuln_name}} |
| Severity | {{severity}} |
| Last Verified | {{date}} |

## Host Status

| Host | Providentia Says | Actual Status | Verified | Notes |
|------|-----------------|---------------|----------|-------|
<!-- Append one row per host as findings are logged.
| hostname | listed | working / broken / partial | YYYY-MM-DD | why broken (not deployed, config changed, etc.) |
-->

## Verification History

<!-- Append entries as re-verified across engagements.
### Verified: YYYY-MM-DD — engagement-id
- **Hosts tested**: [list]
- **Working**: [list]
- **Broken**: [list]
- **Notes**: observation
-->
