---
name: recon
description: "Enumerate a target. Usage: /recon <hostname> — queries sources in priority order, writes structured recon report."
---

# Recon Skill

Enumerate a target host using the source priority chain. Requires red-team mode active.

## Procedure

When operator invokes `/recon <hostname>`:

### 1. Validate
- Check engagement YAML loaded (or warn operator to create one)
- Confirm target is in approved target list (RT-TGT-001)
- If target not approved, STOP and ask operator to approve

### 2. Query Sources (in order)

#### Source 1: Providentia (range-intel MCP)
- `providentia_get_host` for host record: OS, IP, services, tags
- `providentia_get_networks` for connected network segments

#### Source 2: GitLab READMEs (range-intel MCP)
- `gitlab_get_readme` for deploy notes, installed services, config details

#### Source 3: Wiki repo-docs (outline-readonly MCP)
- `outline_search` in repo-docs collection for host documentation
- Extract: services, versions, known configs

#### Source 4: Wiki vulns-docs (outline-readonly MCP)
- `outline_search` in vulns-docs collection for known vulnerabilities
- Extract: CVEs, exploit availability, prior findings

#### Source 5: Tuoni Discovery (tuoni-mcp, if agents active)
- `tuoni_list_agents` to check for existing agents on target
- If agent exists: `tuoni_run_command` for basic enum (whoami, hostname, ip addr)

#### Source 6: Obsidian (obsidian-mcp)
- Search vault for prior notes on target
- Check for tactical observations from previous sessions

#### Source 7: Reference MCPs (only if gaps remain)
- HackTricks: search for service-specific attack techniques
- MITRE: map identified services to ATT&CK techniques
- GTFOBins: check for SUID/capability abuse paths (Linux targets)

### 3. Compile Report
Output structured recon report with sections:
- **Target Summary**: hostname, IP, OS, role
- **Services**: port, service, version (from Providentia + README)
- **Attack Surface**: known vulns, exploit availability, prior findings
- **Existing Access**: any active agents or sessions
- **Recommended Next Steps**: prioritized attack paths based on findings
- **Gaps**: what we don't know yet, suggested manual enum

### 4. Update Engagement YAML
If engagement file exists, update its findings section with recon results.

## OPSEC Reminders
- RT-TGT-001: target must be approved before ANY enumeration
- RT-TGT-002: do NOT upload tools to target — all enum runs from Kali or through C2
- Source priority is mandatory — don't skip to web research
