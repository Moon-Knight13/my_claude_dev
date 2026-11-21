<!-- Mini variant for subagent dispatch. Full version: SKILL.md -->
---
name: discovery
description: "Post-compromise host and network enumeration skill. Runs after persistence is established. Compares actual state against Providentia expected state. Feeds cred-harvest and lateral-move skills."
modes: [red-team, purple]
---

# Discovery — Mini

## Entry criteria

- Persistence confirmed (operational + sleeper beacons active)
- Host in engagement YAML with `phase: initial_access` or `lateral_move`

## OPSEC Rules — ENFORCED

- **RT-TGT-002:** No tools uploaded. Use native OS commands via tuoni agent.
- All enumeration through tuoni-mcp agent commands.
- Minimize command volume — defenders monitor for enumeration bursts.
- **RT-SCOPE-001:** GT (green team) accounts OUT OF SCOPE. Skip gt-prefixed entries in all user/session/process lists. NEVER include in lateral movement targets or credential source maps.

## Thread Orchestration

Discovery runs INLINE within post-access thread (same thread as initial-access Phase 4 or lateral-move post-landing). Reads and writes Obsidian target page.

## Plugin-First Policy (ENFORCED)

Use tuoni-plugins before raw sh commands:

| Action | Plugin | Instead of |
|--------|--------|------------|
| Full host enumeration | host-id | Manual whoami/uname/ip |
| Routing dump | net-recon routing_recon | vtysh commands |
| Web fingerprint | net-recon web_fingerprint | curl/nmap |
| Domain detect | ad-enum | Manual net user /domain |
| Config sweep | collect-intel | Manual find/grep |

**Run host-id first**, then ad-enum, then net-recon routing_recon. Raw sh only when plugin fails.

## Procedure

### Step 1: Host Enumeration

Via tuoni plugins (preferred) or native commands: identity, users/groups, network config, services, security products (AV/EDR), filesystem.

### Step 1.5: LOLBins Environment Analysis (ENFORCED)

After enumeration, pipe output to lolbins-mcp: `analyze_environment` → `discover_chains` → `find_escalation_paths` → `find_persistence_paths` → `analyze_opsec_risk`. Creates environment context for all subsequent lolbins calls.

### Step 1.7: Tuoni/Providentia Reconciliation

Compare `tuoni_hosts_list` against `range_targets` for this network segment. Hosts Tuoni sees but Providentia doesn't = rogue systems (high-value finding).

### Step 2: Compare Against Providentia

Query range-intel for expected host state. Document discrepancies: unexpected services, missing services, extra connections, extra users.

### Step 3: Credential Source Identification

Map credential storage locations (DO NOT harvest yet): hashes (SAM/shadow), cached creds (lsass/ssh-agent), config files (.env/web.config), keys (SSH/SSL), browser stores, history files. Report to operator. Handoff to cred-harvest.

CTF/exercise: also invoke `flag-hunt` after discovery.

### Step 4: Lateral Movement Opportunity Mapping

Identify paths: reachable segments, trust relationships, shared resources, service accounts. Cross-reference with Providentia network topology.

### Step 5: Document and Update State

**Engagement YAML — lean:**
```yaml
targets:
  - hostname: <target>
    phase: discovery
    status: complete
    wiki_page: llm-wiki/wiki/targets/<hostname>.md
```

**Obsidian (ENFORCED):** invoke `/log-finding` for each result. Write: `llm-wiki/raw/<hostname>-discovery-<date>.md`, update `llm-wiki/wiki/targets/<hostname>.md`, append `llm-wiki/log.md`.

RT-SCOPE-001: exclude gt-prefixed accounts from all written output.

## Failure modes

- Agent dies: use sleeper beacon to re-establish, resume from where stopped
- Commands blocked by AV/EDR: use `lolbins analyze_opsec_risk` for alternatives
- Host not in Providentia: flag as unknown, report to operator
