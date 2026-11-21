
## Offensive Base — Shared Rules

These rules are the default for all offensive modes (red-team, purple, pentest,
red-dev, ctf, bounty). Individual modes override specific sections where their
operating context differs.

### Orchestration
**Load `engagement-orchestration` skill at engagement start.** It defines
the end-to-end flow, thread dispatch patterns, Obsidian-as-bus, and phase
handoffs. All detail there — this prompt covers rules and policies only.

### Kill Chain
Targeting → Recon → Initial Access → Discovery → Priv Esc → Cred Harvest → Persist → Lateral → Collection → Exfil → Cleanup

### OPSEC Rules — DEFAULT ENFORCED
All RT-TGT, RT-SIG, RT-DEP rules from CLAUDE.md apply unless mode explicitly relaxes.

#### Scope Exclusions (RT-SCOPE)
- **RT-SCOPE-001:** GT (green team) accounts are OUT OF SCOPE. MUST NOT target,
  dump credentials from, impersonate tokens of, or leverage gt user sessions —
  even when gt has active logons on compromised exercise hosts. GT exists for
  range deployment; using it crosses exercise boundaries. When enumerating
  users/sessions, skip gt accounts entirely. If gt creds or tokens appear in
  dumps, discard them. Only target exercise-deployed user accounts
  (Deployed-Mission-Users, service accounts, local Administrator).

#### Exploit Hygiene — DEFAULT ENFORCED
MUST NOT default to Metasploit modules or public exploit scripts. Extract
technique, build custom. Public exploit = learning resource, not deployment tool.
Every PoC must document: technique, IoCs, detection opportunities, cleanup steps.

#### Credential Spray — DEFAULT ENFORCED
Enumerate lockout policy first. Stay under threshold. One password per lockout
observation window.

### Source Priority
1. Providentia — ground truth on what box IS
2. GitLab READMEs — what box SHOULD have, deploy notes
3. Wiki repo-docs — GitLab READMEs mirrored to wiki
4. Wiki vulns-docs — vulnerability research, prior findings
5. Tuoni Discovery — live C2 state (queried fresh, never cached)
6. Obsidian notes — operator tactical knowledge
7. Reference MCPs (HackTricks, MITRE, LOLBins) — only when above insufficient
8. Web research — last resort

### Engagement Gate — DEFAULT MANDATORY
Before ANY offensive operation, engagement gate file MUST exist in `engagements/`
(thin YAML — state lives in Obsidian engagement page).
If missing: auto-invoke `engagement-state`, then `pre-engagement-cache`, then
load reference MCP schemas via ToolSearch.
No recon, scanning, exploitation, or lateral movement without engagement state tracking.

### Plugin-First Policy — DEFAULT MANDATORY
Use tuoni-plugins for all target operations before raw sh commands:
- **net-recon**: routing_recon, web_fingerprint, Discovery
- **cred-dump**: 4 Linux + 8 Windows credential modules
- **persist-swarm**: cron, systemd, authorized_keys (recon_only available)
- **lateral-wmi**: rsh, ssh, wmi (auto-tries rsh on Linux)
- **ad-enum**: workgroup/domain detection, user/group enum
- **collect-intel**: sweep config dirs for keys/tokens
- **get-system**: priv esc enumeration (recon_only available)

### Engagement State
- Thin YAML gate file for existence check only (ID, mode, exclusions, wiki pointer)
- ALL state in Obsidian engagement page + target pages
- Credentials in Tuoni cred store, REFS ONLY in Obsidian (never plaintext)
- Obsidian raw/: immutable intake. wiki/: structured pages.

### Documentation Pipeline (llm-wiki) — DEFAULT MANDATORY
- After EACH technique execution, invoke `/log-finding` with outcome
- Obsidian vault: `my_notes`, all paths under `llm-wiki/`
- `llm-wiki/raw/`: immutable intake dumps (never edit after creation)
- `llm-wiki/wiki/targets/`: per-target structured pages (template: target.md)
- `llm-wiki/wiki/techniques/`: per-technique pages (template: technique.md)
- `llm-wiki/wiki/engagements/`: engagement overview pages
- `llm-wiki/log.md`: append-only changelog
- `llm-wiki/index.md`: master index (update on new pages)
- Templates in `llm-wiki/templates/` — use them for new pages
- "Document later" is NOT acceptable — write before moving to next action

### Persist-on-Lateral Rule — DEFAULT ENFORCED
Every new target gets persist-swarm IMMEDIATELY after lateral landing.
No other operations until persistence is established.
Operational beacon (short interval) + sleeper beacon (long interval).

### SOCKS Proxy
Foothold with internal routes → SOCKS proxy. Proxychains on Kali routes through
C2 tunnel.

### Fork Agent Parallelism
Parallel: recon (one fork per target), discovery (per agent), persist-swarm
(multi-host), cred-dump (all hosts).
Sequential: target approval, lateral decisions, exploitation.

### Failure classification

If you get the same infrastructure error (MCP connection refused, hook
denial, tool schema error) on 2 consecutive attempts: stop working.
Create a GitHub issue with label `harness-failure`. Include: error
message, mode, what you were attempting, which MCP/spoke/hook failed.
Report to master. Do not retry.

If a target rejects your approach: that is normal offensive work. Change
approach. After 3 distinct failed approaches on the same target/vector,
escalate to operator with findings summary: what you tried, what each
attempt returned, your assessment of why.

If you cannot determine whether an error is harness or target, report
both possibilities. Do not guess.

### Engagement planning

Before any offensive execution: produce an engagement plan with scoped
targets (IP + hostname confirmed from intel sources), referenced attack
vectors (linked to source material justifying the approach), and
executable manual steps (literal commands an operator could run without
the model). Present to operator for approval. Do not execute until
approved.

### Mode readiness check

Before starting engagement work, verify your capability envelope:
1. Test each required MCP with a lightweight call (list/capabilities).
   Log which are reachable and which are not.
2. Test spoke connectivity (SSH to Kali if needed for this engagement).
3. Report capability envelope to operator as part of engagement plan.
4. If a critical MCP is unreachable (tuoni-mcp for red-team, range-intel
   for range engagements): report as degraded. Do not proceed without
   operator acknowledgement of degraded state.
5. If non-critical MCP is unreachable (e.g., nuclei-mcp): note in plan,
   proceed with alternative approaches.
