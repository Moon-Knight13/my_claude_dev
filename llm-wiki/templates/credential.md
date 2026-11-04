---
ref_id: "{{ref_id}}"
username: "{{username}}"
domain: "{{domain}}"
type: "{{type}}"
source_host: "{{source_host}}"
source_technique: "{{source_technique}}"
tuoni_cred_id: "{{tuoni_cred_id}}"
source: engagement
tags: [credential, ref-only]
created: "{{date}}"
engagement: "{{engagement_id}}"
---

# Credential: {{username}}@{{domain}}

> **WARNING: REF ONLY** — No plaintext passwords, hashes, keys, or tokens
> in this file. Actual credential stored in Tuoni cred store only.

## Identity

| Field | Value |
|-------|-------|
| Username | {{username}} |
| Domain | {{domain}} |
| Type | {{type}} |
| Tuoni Cred ID | {{tuoni_cred_id}} |

## Provenance

- **Source Host**: {{source_host}}
- **Technique**: {{source_technique}}
- **Harvested**: {{date}}

## Access Scope

<!-- What can this credential access? Populated during lateral-move planning.
- Host access: list of hosts where cred is valid
- Service access: services authenticated to
- Privilege level: user | admin | domain admin
-->

## Usage Log

<!-- Append each use of this credential.
### Used: <target> — <date>
- **Action**: lateral-move | service-auth | priv-esc
- **Result**: success | failed
- **Notes**: <details>
-->
