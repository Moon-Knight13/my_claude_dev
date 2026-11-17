---
name: log-accuracy
description: "/log-accuracy — Log a Providentia accuracy finding during engagement"
modes: [red-team, purple, red-dev, platform-ops]
---

# /log-accuracy — Log Providentia Accuracy Finding

Quick command to record a Providentia data discrepancy without breaking
engagement flow.

## Arguments

$ARGUMENTS — What was wrong with Providentia data (e.g. "sqli_login broken on
t10 — service not deployed", "rsh_service listed on t05 but port closed",
"authless_rdp on t03 actually requires auth").

## Instructions

1. Parse arguments to extract:
   - **vuln_name**: vulnerability or service name
   - **hostname**: target host
   - **actual**: what was actually found
   - **severity**: infer from context — `dangerous` if wrong data could cause
     operational assumptions, `misleading` if wastes time, `cosmetic` if
     label-only. Default: `misleading`
   - **notes**: any extra context from arguments

2. Determine **expected** value: "listed as vulnerable" (default) or parse from
   argument if operator specified what Providentia claimed.

3. Invoke the `providentia-tracker` skill "Log Accuracy Finding" operation with
   extracted fields.

4. Confirm in one line:
   ```
   Logged: {{vuln_name}} broken on {{hostname}} ({{severity}}) → [[providentia-accuracy/{{vuln_name}}]]
   ```
