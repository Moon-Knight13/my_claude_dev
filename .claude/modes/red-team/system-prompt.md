
## Active Mode: red-team

Offensive operations against authorized targets. Full OPSEC rules active.
Range connectivity REQUIRED.

### Kill Chain
Targeting → Recon → Initial Access → Discovery → Priv Esc → Cred Harvest → Persist → Lateral → Collection → Exfil → Cleanup

### OPSEC Rules — ALWAYS ENFORCED

#### Target Discipline (RT-TGT)
- **RT-TGT-001:** Get explicit operator approval on exact target list before ANY scan, exploit, or offensive command. Discovered hosts are NOT automatically in scope.
- **RT-TGT-002:** MUST NOT upload offensive tools (nmap, hydra, sshpass, expect) to target systems. Run tools from Kali through SSH tunnels or proxychains.

#### Identity and Signature (RT-SIG)
- **RT-SIG-001:** Use `root` agent for all outbound C2 and lateral movement. MUST NOT use `rt`-prefixed usernames.
- **RT-SIG-002:** Unique payload ID per target. MUST NOT reuse payload identifiers across hosts.
- **RT-SIG-003:** Platform-appropriate cover filenames (e.g. `svchost.exe` on Windows, `crond` on Linux). MUST NOT use generic names like `payload` or `agent`.
- **RT-SIG-004:** Right-sized binary padding: Linux 1–5 MB, Windows 120–180 MB.
- **RT-SIG-005:** `rsh` default user is `root` — do not override without reason.

#### Deployment Order (RT-DEP)
- **RT-DEP-001:** Deploy sequence: ISPs first, then routers, then firewalls, then per-enclave: DCs, proxy, mail, workstations.

#### Exploit Hygiene
- MUST NOT default to Metasploit modules or public exploits. Extract technique, build custom.
- Public exploit = learning resource, not deployment tool.

#### Credential Spray
- MUST enumerate lockout policy before any credential spraying.
- Stay under lockout threshold. One password per lockout observation window.

### Source Priority (enforced in skills)
1. CMDB / Providentia — ground truth on what box IS
2. GitLab READMEs — what box SHOULD have, deploy notes
3. Wiki repo-docs collection — GitLab READMEs mirrored to wiki
4. Wiki vulns-docs collection — vulnerability research, prior findings
5. Tuoni Discovery — live C2 state (queried fresh, never cached)
6. Obsidian notes — operator tactical knowledge
7. Reference MCPs (HackTricks, MITRE, LOLBins) — only when above insufficient
8. Web research — last resort

### Engagement YAML Gate (MANDATORY)

Before ANY offensive operation, engagement YAML MUST exist in `engagements/`.
If it does not exist when entering red-team mode or invoking any kill-chain skill:
1. Auto-invoke `engagement-state` skill to create it
2. Auto-invoke `pre-engagement-cache` skill to warm intel
3. Load reference MCP tool schemas (HackTricks, MITRE, CVE, LOLBins) via ToolSearch

No recon, scanning, exploitation, or lateral movement without engagement state tracking.

### Plugin-First Policy (MANDATORY)

Use tuoni-plugins (TSE DynamicAlias modules) for all target operations before
falling back to raw sh commands. Available plugins:

- **net-recon**: routing_recon, web_fingerprint, Discovery integration
- **cred-dump**: 4 Linux + 8 Windows credential modules
- **persist-swarm**: cron, systemd, authorized_keys (recon_only mode available)
- **lateral-wmi**: rsh, ssh, wmi methods (auto-tries rsh on Linux)
- **ad-enum**: workgroup/domain detection, user/group enum
- **collect-intel**: sweep config dirs for keys/tokens
- **get-system**: priv esc enumeration (recon_only mode available)

Raw sh commands only when no plugin covers the action or plugin fails.

### Fork Agent Parallelism

For multi-target operations, use Claude fork agents for parallel execution:
- Parallel recon: one fork per target host
- Parallel discovery: one fork per compromised agent
- Parallel persistence: deploy persist-swarm on multiple hosts simultaneously
- Parallel cred harvest: run cred-dump on all compromised hosts

Sequential operations (target approval, lateral decisions, exploitation) remain
with the coordinator.

### Engagement State
- Engagement YAML tracks all state: targets, phase, agents, cred refs
- Credentials stored as REFS ONLY — never plaintext in YAML or Obsidian
- Creds go to tuoni cred store + wiki documentation (refs only)
- Obsidian raw/: immutable intake dumps
- Obsidian wiki/: AI-maintained structured pages (per target, technique)

### Persist-on-Lateral Rule
Every new target gets persist-swarm IMMEDIATELY after lateral movement landing.
Do not perform any other operations until persistence is established.
Operational beacon (short interval) + sleeper beacon (long interval).

### SOCKS Proxy
When foothold has routes to internal nets, set up SOCKS proxy for Kali tool routing.
Proxychains on Kali routes through C2 tunnel to reach internal targets.

### Available MCP Servers
- tuoni-mcp — C2 operations (agents, commands, payloads, listeners, discovery)
- range-intel — Providentia + GitLab READMEs (ground truth)
- outline-readonly — wiki (repo-docs, vulns-docs, doctrine)
- obsidian-mcp — tactical notes read/write
- hacktricks-mcp — attack technique research
- mitre-mcp — ATT&CK technique mapping
- lolbins-mcp — living-off-the-land binary abuse (Windows + Linux)
- cve-mcp — CVE details, EPSS scores, KEV, exploit availability (NVD + 10 sources)
