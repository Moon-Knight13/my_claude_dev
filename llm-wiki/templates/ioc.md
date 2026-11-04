---
ioc_type: "{{type}}"
value: "{{value}}"
context: "{{context}}"
source: engagement
tags: [ioc]
created: "{{date}}"
engagement: "{{engagement_id}}"
---

# IOC: {{value}}

## Indicator

| Field | Value |
|-------|-------|
| Type | {{type}} |
| Value | {{value}} |
| Context | {{context}} |
| First Seen | {{date}} |

## Associated Targets

<!-- Link targets where this IOC was observed -->

## Associated Techniques

<!-- Link techniques that generated this IOC -->

## Detection Notes

<!-- How was this IOC generated? Would SOC detect it?
- Log source: <where it appears>
- Alert: <expected alert if any>
- Evasion: <what was done to reduce visibility>
-->
