# DCM27 Cyber Range — Developer Rules (User-Level)

This file is deployed to `~/.claude/CLAUDE.md` by `setup-day0.sh` and applies
to all Claude sessions on this machine. Rules are sourced from the Outline wiki
at wiki.crp.cr14.net — DCM27 Range Development collection. Full rule text is
available via the `outline-readonly` MCP server tools.

## Architecture Principles

The DCM Cyber Range has two zones. **The security of the Control Zone is paramount.**

- **Control Zone** ("clean"): CRP systems, domain `crp.cr14.net`, out-of-game.
  vCenter folders `DCM_Core` / `DCM_Core_Networks`.
- **Exercise Zone** ("dirty"): live-fire exercise systems, domain `dcm.ex`, in-game.
  vCenter folders `DCM` / `DCM_Networks`.

Bridging between zones SHOULD be avoided. Exceptions MUST go through change
management (MOC). The virtual router `r-edge` is the demarcation point.

Requirement terms (MUST, SHOULD, MAY, etc.) follow RFC 2119.

## Cross-Cutting Rules — Always Apply

### Segmentation (SEG)
- **SEG-001:** R-Edge SHALL be the interconnection point between Control and Exercise zones.
- **SEG-002:** Endpoints SHOULD NOT bridge Control and Exercise zones.
- **SEG-004:** Exceptions to bridge zones MUST be approved through change management.
- **SEG-005:** Exercise Zone systems MUST NOT be domain joined to or authenticate against CRP AD DCs.
- **SEG-006:** Cross-boundary interactions MUST be approved through change management.
- **SEG-010:** Control Zone — consider host-based micro-segmentation where lateral compromise is credible.

### Development General (DEV)
- **DEV-001:** MUST NOT access or interfere with a deploy box not assigned to you.
- **DEV-002:** Providentia is the single source of truth for networks, compute, IP allocation.
- **DEV-004:** MUST have Tech Lead approval before developing a production system.
- **DEV-005:** Requirement MUST be documented as a GitLab issue before development begins.
- **DEV-006:** Code and artefacts MUST be committed to GitLab branches and merged.
- **DEV-007:** Merge Requests MUST NOT be approved without functional and deployment test confirmation.

### Management of Change (MOC)
- **MOC-001:** Changes managed in GitLab via `change_mgmt` folder in `core/dcm-catapult`.
- **MOC-006:** Developers MUST discuss change requirement with Tech Lead before requesting.
- **MOC-007:** Changes MUST NOT be implemented until the associated MR is approved.

### Networks (NET)
- **NET-001:** vCenter network segment changes MUST be approved through change management.
- **NET-003:** All multi-homed endpoints MUST be approved through change management.
- **NET-006/007:** DNS changes for dcm.cr14.net, crp.cr14.net, DCM.ex root MUST go through change management.

### Automation and API (API)
- **API-001:** vCenter API/PowerCLI MUST NOT be used for custom automation unless authorised by CR14 via Dev Tech Lead.
- **API-002:** Providentia API MUST NOT be used for custom automation unless authorised by Dev Tech Lead.
- **API-003:** Automated polling SHALL apply request chunking, caching, and retry backoff.

## Red Team OPSEC — Always Apply During Offensive Operations

### Target Discipline (RT-TGT)
- **RT-TGT-001:** MUST get explicit operator approval on exact target list before any scan, exploit, or offensive command. Discovered hosts are NOT automatically in scope.
- **RT-TGT-002:** MUST NOT upload offensive tools (nmap, hydra, sshpass, expect) to target systems. Run tools from Kali through SSH tunnels or proxychains.

### Identity and Signature (RT-SIG)
- **RT-SIG-001:** Use `root` agent for all outbound C2 and lateral movement. MUST NOT use `rt`-prefixed usernames — obvious red team indicator in target logs.
- **RT-SIG-002:** Unique payload ID per target. MUST NOT reuse payload identifiers across hosts.
- **RT-SIG-003:** Platform-appropriate cover filenames (e.g. `svchost.exe` on Windows, `crond` on Linux). MUST NOT use generic names like `payload` or `agent`.
- **RT-SIG-004:** Right-sized binary padding: Linux 1–5 MB, Windows 120–180 MB. Match expected binary sizes for the platform.
- **RT-SIG-005:** `rsh` default user is `root` — do not override without reason.

### Deployment Order (RT-DEP)
- **RT-DEP-001:** DCM deploy sequence: ISPs first, then routers, then firewalls, then per-enclave: DCs, proxy, mail, workstations.

## Commit Attribution

- **GitLab / catapult remotes:** End commit messages with `DCM27-Chris.M #UseTheRobotsToDestroyTheRobots`. No Claude attribution.
- **GitHub / my_claude_dev:** Standard Claude `Co-Authored-By` attribution line.

## Domain-Specific Rules — Use MCP When Relevant

For full rules in these domains, use `outline_search` or `outline_read_document`
via the outline-readonly MCP server:

| Domain | Outline Doc ID | When to check |
|--------|---------------|---------------|
| IDAM / Active Directory | `db339cf0-875c-466c-b5f5-d77adb96f7c3` | Auth, SSO, AD, MFA, user/group changes |
| Out-of-Bounds (OOB) | `30e37c39-02e8-40a2-a2d9-be45fc9108c5` | BT network endpoints, greynet, back-end networks |
| AI/ML (AIML) | `c8563ecb-614b-44b4-b552-0975f9b1ce78` | Any AI/ML model use, GPU, API proxy, AWS Bedrock |
| External Interconnections (ECON) | `2072e510-e6af-439e-a7c5-681eaaaa36ba` | VPN, cloud hosting, external integrations |
| External Dependencies (EDEP) | `5fb3c7ee-b447-4ada-9c43-68fb26bb08e1` | Internet access, third-party dependencies |
| Monitoring (MON) | `0d2f9034-2e21-4f6a-a499-6953ac558b6f` | SOC monitoring, Elastic Agent, logging |
| Providentia (PROV) | `8eba620d-cdf0-426c-b133-b9ca8625abb6` | CMDB entries, host records, tags, network definitions |
| Architecture Principles | `e162cc54-ae8e-488f-97f5-4eeea6369072` | Design decisions, zone model questions |
