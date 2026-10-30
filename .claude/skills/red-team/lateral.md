---
name: lateral
description: "Guided lateral movement between compromised hosts. Usage: /lateral <from-host> <to-host> <method> — validates targets, creds, agent, executes move, then MANDATES persist-swarm on the new target."
---

# Lateral Movement Skill

Execute a lateral move from one compromised host to another, with mandatory
persistence deployment on success.

## Usage

```
/lateral <from-host> <to-host> <method>
```

**Methods:** `wmi`, `psexec`, `ssh-key`, `ssh-pass`, `dcom`, `winrm`, `smbexec`

Active in: **red-team** mode only.

## Critical Rule: persist-on-lateral

**After every successful lateral move, persist-swarm MUST run on the new target
before ANY other action.** This is non-negotiable. A lateral move without
persistence is a wasted move — if the agent dies, the foothold is lost and the
move must be repeated (noisier the second time).

## Pre-flight Validation

All checks MUST pass before execution. Fail fast on the first violation.

### 1. Target Validation (RT-TGT-001)

Both `<from-host>` and `<to-host>` MUST appear in the approved target list
(engagement YAML `approved_targets`). Discovered hosts are NOT automatically
in scope — operator must explicitly approve them first.

- If either host is not approved: **STOP. Report which host is missing.**
- Do not prompt to add — operator must update the approved list separately.

### 2. Source Agent Validation

Confirm an active agent exists on `<from-host>` via tuoni-mcp
(`tuoni_agents_list` or `tuoni_discovery_hosts_list`).

- If no active agent on source: **STOP. Cannot execute lateral move without C2
  on the source host.**
- If agent is stale (last check-in > 5 min): warn operator, ask to proceed.

### 3. Credential Reference Validation

Check engagement YAML `cred_refs` section for a credential entry that matches
the chosen method and target:

| Method     | Required cred_ref fields                       |
|------------|------------------------------------------------|
| `wmi`      | username, password or hash (domain optional)   |
| `psexec`   | username, password or hash (domain optional)   |
| `ssh-key`  | username, key_ref (path to key on source host) |
| `ssh-pass` | username, password                             |
| `dcom`     | username, password or hash (domain optional)   |
| `winrm`    | username, password or hash (domain optional)   |
| `smbexec`  | username, password or hash (domain optional)   |

- If no matching cred_ref: **STOP. No credentials for this method/target.**
- Credential values are NEVER displayed in output or logs — reference by
  `cred_id` only.

### 4. Method-Target OS Compatibility

| Method     | Source OS     | Target OS     |
|------------|---------------|---------------|
| `wmi`      | Windows       | Windows       |
| `psexec`   | Windows/Linux | Windows       |
| `ssh-key`  | Any           | Linux         |
| `ssh-pass` | Any           | Linux         |
| `dcom`     | Windows       | Windows       |
| `winrm`    | Any           | Windows       |
| `smbexec`  | Windows/Linux | Windows       |

- If method incompatible with target OS: **STOP. Suggest compatible methods.**

## Execution

### 1. Prepare

- Select listener for the new implant on `<to-host>`
- Generate unique payload_id (RT-SIG-002 — never reuse across hosts)
- Apply platform-appropriate payload name (RT-SIG-003)
- Size binary appropriately (RT-SIG-004: Linux 1-5 MB, Windows 120-180 MB)

### 2. Execute via C2 (RT-TGT-002)

All execution happens through the existing agent on `<from-host>` via
tuoni-mcp commands. **No tools are uploaded to the target** — the lateral
move technique itself delivers the payload.

**RT-SIG-001:** Use `root` (or the cred_ref identity) for all outbound
movement. MUST NOT use `rt`-prefixed usernames — they are obvious red team
indicators in target logs.

Method-specific execution:

- **wmi**: `wmic /node:<to-host>` process create via agent command
- **psexec**: service-based remote exec via agent command
- **ssh-key**: SSH with key forwarded through agent tunnel
- **ssh-pass**: SSH with password through agent tunnel
- **dcom**: DCOM remote instantiation via agent command
- **winrm**: WinRM session via agent command
- **smbexec**: SMB-based remote exec via agent command

### 3. Verify Connection

- Wait for new agent check-in from `<to-host>` (timeout: 120s)
- Confirm agent OS, hostname, and IP match expected target
- If no check-in within timeout: **report failure, do not retry automatically**

### 4. MANDATORY: Persist-Swarm (persist-on-lateral)

**Immediately** invoke `/persist-swarm <to-host>` on the new target.

- Do NOT proceed to any other action until persist-swarm completes
- Do NOT ask operator whether to persist — it is mandatory
- If persist-swarm fails: warn operator, mark lateral move as UNPERSISTED
  in engagement YAML (high-risk state)

## OPSEC Rules

| Rule       | Requirement                                             |
|------------|--------------------------------------------------------|
| RT-TGT-001 | Both hosts must be in approved target list              |
| RT-TGT-002 | No tools uploaded to target — execute through C2 tunnel |
| RT-SIG-001 | Use root identity, never rt-prefixed usernames          |
| RT-SIG-002 | Unique payload_id per host — never reuse                |
| RT-SIG-003 | Platform-appropriate cover filenames                    |
| RT-SIG-004 | Right-sized binaries (Linux 1-5 MB, Windows 120-180 MB)|

## Engagement YAML Updates

On successful lateral move, add to `lateral_moves` section:

```yaml
lateral_moves:
  - from: <from-host>
    to: <to-host>
    method: <method>
    cred_ref: <cred_id used>
    payload_id: <unique id>
    timestamp: <ISO 8601>
    agent_id: <new agent id on to-host>
    persisted: true|false
    status: success|failed|unpersisted
```

On failure, still record the attempt with `status: failed` and the failure
reason — repeated attempts against the same target are noisier and this
record prevents accidental retries.

## Failure Modes

- **No agent on source**: cannot execute. Operator must re-establish C2 first.
- **Bad credentials**: method fails at auth. Do not retry with same creds.
  Suggest operator verify cred_ref or try different method.
- **Timeout on new agent**: payload may have been caught, or network issue.
  Mark attempt as failed. Operator decides whether to retry with different
  method or investigate detection.
- **Persist-swarm fails after successful move**: mark as UNPERSISTED.
  This is a high-risk state — operator must resolve before continuing.
- **Target not in Providentia**: if `<to-host>` has no Providentia record,
  OS detection is unreliable. Warn operator, require explicit OS override.
