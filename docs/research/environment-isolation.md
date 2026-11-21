# Environment Isolation Design

**Status:** Research / Design  
**Author:** Operator + Claude  
**Date:** 2026-11-21

---

## 1. Environment Definitions

| Environment | Contains | Network | Risk if leaked |
|-------------|----------|---------|----------------|
| **Range (cr14)** | Target data, Providentia intel, offensive tooling output, engagement state, exploit PoCs, harvested creds | Isolated exercise network (172.21.x.x) | Exercise data in public repo; scope violations; range topology exposed |
| **Homelab** | Real credentials, UniFi config, Docker stack state, partner-critical services | Home LAN, internet-facing services | Real credential exposure; home network compromise; partner impact |
| **VPS/Cloud** | API keys, billing data, RunPod/cloud tokens, DNS configs | Public internet | Financial exposure; infrastructure takeover; API key abuse |
| **Public repos** | Open-source code, docs, skills, hook logic | GitHub public | Reputational; offensive content in public; secrets in git history |

### Cross-environment data that MUST NOT flow:

| From | To | Example violation |
|------|-----|-------------------|
| Range | Public repos | Target IP/hostname in commit message or code comment |
| Range | Homelab | Harvested cred reused against home network device |
| Homelab | Range threads | Home router password in engagement thread context |
| Homelab | Public repos | UniFi credentials in `.env` committed |
| VPS/Cloud | Public repos | RunPod API key in git history |
| VPS/Cloud | Range | Cloud billing token in engagement state |
| Any | Claude memory | Credentials stored in memory files (memory is cross-session) |

---

## 2. Current State — What Exists

### 2.1 Mode-based tool isolation (IMPLEMENTED)

**Mechanism:** 12 modes in `.claude/modes/`, each with `tool-policy.yaml` deny lists.

**Enforcement chain:**
1. `mode-tool-gate.sh` (PreToolUse) — denies MCP tool calls matching fnmatch patterns in active mode's deny list
2. `skill-mode-gate.sh` (PreToolUse) — denies skill invocation if active mode not in skill's `modes:` frontmatter
3. `mode-inject.sh` (UserPromptSubmit) — injects mode system prompt, filters visible skill list
4. `start-mode.sh` — launches Claude with `--strict-mcp-config` so only that mode's MCP servers connect

**What it prevents:**
- Homelab mode cannot call tuoni, range-intel, hacktricks, mitre, lolbins MCP tools
- Dev mode has broadest deny (all offensive + range + obsidian)
- Offensive skills (recon, persist-swarm, cred-harvest, etc.) have `modes:` restricting them to red-team/purple/pentest/ctf

**Gaps:**
- Tool deny is MCP-only. Bash commands to offensive tools are not mode-gated (only tuoni-secret-guard covers Bash paths for tuoni specifically)
- Skill mode gate is soft for skills without `modes:` frontmatter — they pass in ALL modes
- Base mode has NO tool-policy.yaml — fully permissive, any MCP callable
- Mode is a single file (`.claude/.active-mode`) — race condition if two sessions write simultaneously

### 2.2 Secret path protection (IMPLEMENTED)

**Mechanisms:**
- `tuoni-secret-guard.sh` — Bash regex for tuoni config/ssl/key/DB paths
- `pretooluse-ctp.sh` — guards ctp-bridge paths, requires approval tokens
- `settings.json` permissions — explicit Write/Edit deny for tuoni-live and /srv/tuoni paths
- `.gitleaks.toml` — custom rules for Anthropic API keys, PII patterns (email, CC, SSN, etc.)
- Secret-read deny in guard-stack — denies reads of `.env`, `~/.ssh/id_*`, `~/.gnupg/**`, configured `CTP_SECRET_PATHS`

**Gaps:**
- No equivalent guard for homelab secrets (UniFi passwords, Docker env files, home network creds)
- No equivalent guard for VPS/cloud API keys beyond `.env` pattern
- Gitleaks runs pre-commit but NOT as a hook that blocks Claude tool calls in real-time
- No content-level scanning of tool OUTPUT for secrets (response-scanner.sh warns but cannot block — PostToolUse limitation)

### 2.3 Provenance and audit (IMPLEMENTED)

**Mechanisms:**
- `pretooluse-provenance.sh` — session registration, freshness check, mode alignment for critical/sensitive tools
- `provenance-policy.yaml` — classifies tools: critical (tuoni commands/agents/listeners/plugins) → offensive modes only; sensitive (tuoni discovery, range-intel, obsidian writes) → offensive + green-dev + platform-ops; monitored (research MCPs) → logged
- `audit-trail.sh` — logs all tool calls
- `session-end-audit.sh` — checks engagement documentation completeness
- `auto-log-finding.sh` — detects creds/access/services in tuoni output (red-team/purple only)

**Gaps:**
- Audit logs are gitignored (good for not leaking, but means no cross-session review without external tooling)
- No automated alert when provenance detects mode mismatch — just deny + log
- No periodic audit of whether mode was correct for session's actual activity

### 2.4 Repo-level separation (IMPLEMENTED)

**Mechanisms:**
- `project-routes.yaml` — maps repos to default modes (my_claude_dev→platform-ops, tuoni-plugins→red-dev, homelab repos→homelab)
- `.gitignore` — comprehensive exclusions: secrets, keys, env files, audit logs, sessions, mode-overrides, engagements, MCP runtime DBs
- Separate repos: tuoni-plugins (private), homelab_planning (private), my_claude_dev (public)
- `mode-inject.sh` checks `T3_PROJECT_REPO_KEY` and emits mismatch warning if repo doesn't match mode

**Gaps:**
- Mismatch detection is a warning, not a hard deny
- No enforcement that thread working in homelab repo CANNOT read range data from sibling worktree
- Engagement state lives in Obsidian vault, which is accessible from any mode (obsidian MCP denied in some modes, but Bash access to vault files is not gated)

### 2.5 Thread isolation (PARTIALLY IMPLEMENTED)

**Mechanisms:**
- Worktree strategy for code-writing threads (CLAUDE.md mandate)
- Per-thread mode override via `.claude/.mode-overrides/$SESSION_ID`
- `master-dispatch-guard.sh` — forces T3 thread dispatch over in-process Agent subagents
- `remote-thread-approval-guard.sh` — requires approval for remote thread launches
- `dispatch-validation-guard.sh` — validates workspace strategy on dispatch

**Gaps:**
- Worktree isolates git state but NOT context — dispatched thread prompt can include data from any environment
- Master session (router) sees all environments' data as it orchestrates
- No mechanism to strip environment-specific context before dispatching to different-environment thread
- Thread inherits parent's MCP connections unless launched with `--strict-mcp-config` via start-mode

### 2.6 AD-13 / Leak prevention (NOT IMPLEMENTED)

**Status:** Designed in `docs/superpowers/plans/2026-11-06-homelab-harness-wiring.md`, not built.

**Planned design:**
- Config-driven deny list of sensitive terms per environment
- Word-boundary matching to avoid false positives
- Mode-gated enforcement (only fires in relevant mode)
- Dry-run mode for tuning

**What it would cover:** Prevent homelab-specific identifiers (device names, IPs, SSIDs) from appearing in range thread output or public commits.

---

## 3. Threat Model

### T1: Range data in public commit
**Path:** Engagement state → engagement thread context → Claude writes code comment with target IP → committed to my_claude_dev → pushed to GitHub.  
**Current mitigation:** .gitignore excludes `engagements/`, gitleaks pre-commit, mode routing (platform-ops mode for my_claude_dev has no range tools).  
**Residual risk:** MEDIUM. If operator manually copies range data into platform-ops thread, no content gate stops it from reaching a commit. Gitleaks catches IPs only if they match a pattern rule (currently no IP-specific rule).

### T2: Homelab creds in range thread
**Path:** Operator asks about home network in master session → switches context to engagement → thread dispatched with master's context → homelab creds in range thread memory/output.  
**Current mitigation:** Mode-based tool deny prevents range tools in homelab mode. Master dispatch forces T3 threads (separate context).  
**Residual risk:** HIGH. Master session context is shared. If operator discusses homelab creds then dispatches engagement thread, master's context (including cred discussion) could leak into dispatch prompt. No content scrubbing on dispatch.

### T3: Offensive skills in homelab mode
**Path:** Skill without `modes:` frontmatter invoked in homelab mode → executes offensive action against home network.  
**Current mitigation:** skill-mode-gate.sh denies skills outside their allowed modes. Tool-policy.yaml denies offensive MCPs in homelab.  
**Residual risk:** LOW. Double gate (skill + tool) catches this. Risk only from skills missing `modes:` frontmatter — these pass everywhere. Audit: verify all 24 skills have `modes:` set.

### T4: VPS API keys in git history
**Path:** Cloud API key in .env → Claude reads it → writes to code or config → committed.  
**Current mitigation:** .env gitignored, secret-read deny for `.env` paths, gitleaks pre-commit with Anthropic API key rule.  
**Residual risk:** MEDIUM. Guard covers `.env` reads, but keys passed via MCP tool output or pasted into chat bypass file-read guards. No content-level scanning that blocks (PostToolUse warns only).

### T5: Mode confusion — thread in wrong environment
**Path:** Thread dispatched without explicit mode → inherits base (fully permissive) → calls range tools while operating on homelab repo.  
**Current mitigation:** project-routes.yaml sets defaults, mode-inject.sh warns on mismatch, dispatch-validation-guard.sh validates.  
**Residual risk:** MEDIUM. Warning is not a hard block. If dispatch skips mode specification and base has no tool-policy, all tools accessible.

### T6: Memory cross-contamination
**Path:** Engagement finding auto-saved to Claude memory → next homelab session loads memory → homelab thread has range target data in context.  
**Current mitigation:** Memory guidelines say not to save credentials. No automated enforcement.  
**Residual risk:** HIGH. Memory is global across all sessions and modes. Any credential, target IP, or engagement detail saved to memory is visible everywhere. Human discipline only.

### T7: Obsidian vault cross-read
**Path:** Engagement state in `llm-wiki` vault → homelab thread queries obsidian MCP → reads engagement target data.  
**Current mitigation:** Homelab tool-policy denies obsidian MCP. Obsidian MCP also denied in dev, platform-ops.  
**Residual risk:** LOW for MCP path. MEDIUM for Bash path — `cat` on vault files is not mode-gated.

---

## 4. Design — Layered Isolation

### Layer 0: Environment Registry (NEW)

Central definition of environments and their boundaries.

**File:** `.claude/environments.yaml`

```yaml
environments:
  range:
    description: "Exercise zone — offensive tools, target data, Providentia intel"
    network: "172.21.0.0/16"
    modes: [red-team, purple, pentest, ctf, green-dev, bounty]
    secret_stores: [tuoni-live, engagements, range-credentials]
    sensitive_patterns:
      - '\b172\.21\.\d{1,3}\.\d{1,3}\b'          # range IPs
      - '\b[a-z]+-?(0[1-9]|[1-5]\d)\b'            # target hostnames (e.g., web01, dc02)
      - '\bcr14\.net\b'                             # range domain
    repos: [tuoni-plugins]

  homelab:
    description: "Production home network — real credentials, partner-critical"
    modes: [homelab]
    secret_stores: [homelab-env, unifi-credentials]
    sensitive_patterns:
      - '\bUDR7?\b'                                 # UniFi device names
      - '<homelab-specific-SSID-patterns>'
      - '<homelab-IP-ranges>'
    repos: [homelab_planning, foundryvtt-docker, medicat-usb]

  cloud:
    description: "VPS/cloud infrastructure — API keys, billing"
    modes: [dev, platform-ops]
    secret_stores: [cloud-env, runpod-credentials]
    sensitive_patterns:
      - '\bsk-[a-zA-Z0-9]{20,}\b'                  # API keys
      - '\brp_[a-zA-Z0-9]{20,}\b'                  # RunPod keys
    repos: []

  public:
    description: "Public repositories — no secrets, no offensive content, no range data"
    modes: [dev, platform-ops, base]
    secret_stores: []
    sensitive_patterns: []
    deny_content_from: [range, homelab, cloud]
    repos: [my_claude_dev]
```

### Layer 1: Context Walls (NEW — extends mode-inject)

**Problem:** Master session and dispatch prompts carry cross-environment data.

**Design:**

#### 1a. Dispatch context scrubber

New hook: `dispatch-context-gate.sh` (PreToolUse on `t3_thread_launch`, `delegate_task`, `create_threads`)

Before thread dispatch, scan the prompt/task field for sensitive patterns from environments OTHER than the target thread's mode's environment. If match found:
- **Hard deny** if target environment is `public`
- **Warn + require confirmation** for other cross-environment dispatch
- Log the violation to audit trail

```
Example: Dispatching thread in homelab mode.
Scan prompt for range patterns (172.21.x.x, cr14.net, target hostnames).
Match found → deny with: "Dispatch prompt contains range data. Strip before dispatching to homelab thread."
```

#### 1b. Master session environment fence

Master (base mode) is the router. It sees all environments. Mitigate by:
- Master MUST NOT store environment-specific data in its own context beyond routing decisions
- Dispatch prompts must reference tasks, not raw credentials or target data
- New lint in `session-end-audit.sh`: flag if master session context grew beyond routing (heuristic: check for IP patterns, credential patterns in master's tool call history)

#### 1c. Memory environment tagging

Extend memory file frontmatter:

```yaml
metadata:
  type: project
  environment: range  # NEW — tag which environment this memory belongs to
```

Memory loader filters: when active mode maps to environment X, suppress loading memories tagged for environment Y (except `environment: all` or untagged).

**Implementation:** Modify memory read logic (if custom) or add advisory section to memory MEMORY.md grouping.

### Layer 2: Secrets Management (EXTEND existing)

#### 2a. Per-environment secret guard (generalize tuoni-secret-guard)

New hook: `environment-secret-guard.sh` (PreToolUse on Bash, Read, Write, Edit)

Loads `environments.yaml`, reads active mode's environment, applies:
- Deny Bash/Read/Write/Edit access to OTHER environments' `secret_stores` paths
- Homelab mode → cannot read tuoni-live paths (already covered), cannot read engagement cred files
- Range modes → cannot read homelab-env, unifi-credentials paths
- All modes → cannot read cloud API key files except cloud-mapped modes

Subsumes `tuoni-secret-guard.sh` (which becomes a special case).

#### 2b. Output content scanner upgrade

Current `response-scanner.sh` is PostToolUse (warn-only). Upgrade path:
- Cannot block PostToolUse (harness limitation). Accept this.
- Add PreToolUse scan on WRITE operations: before Write/Edit commits content, scan for sensitive_patterns from non-current environments
- This catches "Claude read a secret from tool output, now writes it to a file in wrong environment"

#### 2c. Memory secret gate

New validation in memory write path:
- Before writing memory file, scan content against ALL environments' `sensitive_patterns`
- If credential-shaped content detected, deny with: "Credentials must not be stored in memory. Use environment's secret store."
- This addresses T6 (memory cross-contamination)

### Layer 3: Skill Isolation (EXTEND existing)

#### 3a. Mandatory `modes:` frontmatter audit

**Immediate action:** Verify all 24 skills have `modes:` frontmatter. Any without it passes in ALL modes.

Skills that MUST be restricted:
- All `persist-swarm`, `cred-harvest`, `lateral-move`, `initial-access`, `flag-hunt`, `discovery` → offensive modes only
- `range-build`, `ctp-deploy`, `pre-engagement-cache` → green-dev + offensive
- `recon`, `engagement-state`, `technique-scoring` → offensive modes only
- `spoke-health`, `kali-bootstrap` → platform-ops + offensive

#### 3b. Environment tag on skills (NEW)

Add `environment:` to skill frontmatter alongside `modes:`:

```yaml
modes: [red-team, purple, pentest]
environment: range
```

`skill-mode-gate.sh` already checks `modes:`. Extend to also check `environment:` against active mode's environment mapping. Double gate: mode must match AND environment must match.

Benefit: if a new mode is added to range environment, all range skills automatically available without updating each skill's `modes:` list.

### Layer 4: Repo Boundaries (EXTEND existing)

#### 4a. Hard deny on repo-mode mismatch

Current: `mode-inject.sh` warns on mismatch. Change to:
- **Hard deny** for cross-environment mismatches (range mode on homelab repo)
- **Warn** for same-environment mismatches (red-team on green-dev repo — both range)
- Base mode exempt (router needs access to all repos for dispatch)

#### 4b. Commit content gate

New pre-commit hook (or extend gitleaks config):
- Load `environments.yaml`
- Determine repo's environment from `project-routes.yaml`
- Scan staged diff for `sensitive_patterns` from OTHER environments
- Block commit if cross-environment content detected

Example: Committing to my_claude_dev (public environment). Scan for range IPs (172.21.x.x), homelab device names, cloud API keys. Any match → block with specific pattern identified.

#### 4c. Public repo content policy

For repos mapped to `public` environment, additional scanning:
- No offensive tool output (command results, exploit code)
- No engagement references (target names, cred hashes)
- No internal network topology
- Enforced at commit time AND in Write/Edit hook for public repo paths

### Layer 5: Thread Isolation (EXTEND existing)

#### 5a. Environment-scoped dispatch

When master dispatches thread:
1. Thread mode determines environment
2. Dispatch prompt scanned against non-target-environment patterns (Layer 1a)
3. Thread launched with `--strict-mcp-config` for its mode (existing via start-mode.sh)
4. Thread's `.mode-overrides/$SESSION_ID` set (existing)
5. Thread cannot access files outside its environment's repo paths (NEW — path guard in pretooluse-provenance.sh)

#### 5b. Thread-to-thread isolation

Threads in different environments MUST NOT:
- Share worktree (already enforced by worktree mandate)
- Read each other's output files
- Access shared Obsidian vault from non-permitted modes (already gated by tool-policy)

Additional: `t3_thread_send` between threads should validate that sending thread's environment matches receiving thread's environment, or flag for operator review.

### Layer 6: Audit and Breach Detection (EXTEND existing)

#### 6a. Cross-environment access log

Extend `audit-trail.sh` to tag each tool call with:
- Active mode
- Environment (derived from mode)
- Whether tool call touched data from another environment (pattern match on args/paths)

New audit report: `scripts/audit-report.sh` — weekly/on-demand scan of `provenance.jsonl` for cross-environment access patterns.

#### 6b. Session boundary audit

Extend `session-end-audit.sh`:
- Check if session's mode was correct for actual tools used
- Flag if session accessed paths from multiple environments
- Flag if memory was written with cross-environment content

#### 6c. Git history scanner

Periodic scan (or pre-push hook):
- Run gitleaks with environment-aware rules on all commits since last scan
- Check for range IPs, hostnames, creds in public repo commits
- Alert on any match (don't auto-rewrite history — flag for operator)

---

## 5. Implementation Priority

### P0 — Immediate (close highest-risk gaps)

| Item | Addresses | Effort |
|------|-----------|--------|
| Audit all 24 skills for `modes:` frontmatter | T3 | Low — grep + fix |
| Add range IP/hostname patterns to `.gitleaks.toml` | T1 | Low — config |
| Implement `environments.yaml` registry | Foundation | Medium — new file + schema |
| Generalize `tuoni-secret-guard.sh` → `environment-secret-guard.sh` | T2, T4 | Medium — extend existing hook |

### P1 — Next sprint (context wall + dispatch safety)

| Item | Addresses | Effort |
|------|-----------|--------|
| `dispatch-context-gate.sh` — scan dispatch prompts | T2, T5 | Medium — new hook |
| Memory environment tagging | T6 | Medium — frontmatter + loader change |
| Hard deny on cross-environment repo-mode mismatch | T5 | Low — upgrade existing warn |
| Memory secret gate (block cred writes) | T6 | Low — pattern scan on write |

### P2 — Hardening (defense in depth)

| Item | Addresses | Effort |
|------|-----------|--------|
| Commit content gate (environment-aware gitleaks) | T1, T4 | Medium — pre-commit extension |
| PreToolUse write scanner (cross-env pattern check) | T4 | Medium — new hook layer |
| Environment tag on skills | T3 | Low — frontmatter + gate extension |
| Thread-to-thread environment validation | T2 | Low — extend dispatch-validation-guard |

### P3 — Operational maturity

| Item | Addresses | Effort |
|------|-----------|--------|
| Cross-environment audit report | All | Medium — script + log parsing |
| Session boundary audit extension | T5 | Low — extend existing hook |
| Git history scanner (periodic) | T1 | Medium — script + scheduling |
| AD-13 implementation (homelab leak guard) | T2 | Medium — from existing design |

---

## 6. What This Does NOT Solve

1. **OS-level isolation:** Hooks are string classifiers. Obfuscated paths, encoded content, or indirect access bypass them. This is acknowledged in SAFETY_HARNESS.md — "NOT a sandbox."

2. **Shared account:** All modes run as same OS user. File permissions don't help. A determined LLM can read any file via Bash regardless of hook guards (hooks can be slow, race conditions exist).

3. **PostToolUse cannot block:** Tool output containing secrets is already in context once PostToolUse fires. Can warn, log, but not un-read.

4. **Operator context bleed:** When operator pastes data from one environment into chat in another environment's mode, no hook fires (it's user input). The dispatch-context-gate catches this only on DISPATCH, not on input.

5. **MCP server isolation:** MCP servers share host network. A malicious MCP server in one mode could theoretically read files from another environment. Mitigation: `--strict-mcp-config` limits which MCPs load, but loaded MCPs have full host access.

6. **Claude memory is global:** Even with environment tagging, memory is loaded at conversation start. Filtering requires custom loader code, which may not be feasible in all harness configurations.

---

## 7. Relationship to Existing Work

| Existing | This design |
|----------|-------------|
| `mode-tool-gate.sh` | Unchanged. Remains primary MCP deny gate. |
| `skill-mode-gate.sh` | Extended with environment tag validation. |
| `tuoni-secret-guard.sh` | Subsumed by generalized `environment-secret-guard.sh`. |
| `pretooluse-provenance.sh` | Extended with cross-environment path tagging. |
| `mode-inject.sh` | Repo-mode mismatch upgraded from warn to hard deny (cross-env). |
| AD-13 (planned) | Becomes part of `environment-secret-guard.sh` with homelab patterns. |
| `.gitleaks.toml` | Extended with environment-aware patterns. |
| `dispatch-validation-guard.sh` | Extended with dispatch prompt content scanning. |
| `session-end-audit.sh` | Extended with cross-environment access detection. |

---

## Appendix A: Environment-to-Mode Mapping

```
range:    red-team, purple, pentest, ctf, green-dev, bounty
homelab:  homelab
cloud:    dev, platform-ops
public:   dev, platform-ops, base
```

Note: `dev` and `platform-ops` map to both `cloud` and `public`. This is intentional — these modes work on public repos that may reference cloud infrastructure. Tool-policy denies prevent offensive tool access. Content gates (Layer 4) prevent secret leakage.

`base` maps to `public` only. As router mode, it has no tool-policy (permissive for dispatch), but should never directly execute environment-specific work.

`offensive-base` is not a selectable mode — it provides shared rules prepended to offensive modes.

## Appendix B: Hook Execution Order for Isolation

```
UserPromptSubmit:
  1. mode-inject.sh          → inject mode prompt, check repo-mode match
  2. secret-scan.sh          → block secrets in user input

PreToolUse (all tools):
  3. audit-trail.sh          → log call with environment tag
  4. pretooluse-provenance.sh → session + mode verification
  5. mode-tool-gate.sh       → MCP deny per tool-policy.yaml
  6. dispatch-validation-guard.sh → workspace strategy validation

PreToolUse (Bash/Read/Write/Edit):
  7. environment-secret-guard.sh  → cross-environment path deny [NEW]
  8. pretooluse-ctp.sh            → ctp-bridge path guard
  9. write-content-scanner.sh     → cross-env pattern in write content [NEW]

PreToolUse (Skill):
  10. skill-mode-gate.sh     → mode + environment validation

PreToolUse (dispatch tools):
  11. master-dispatch-guard.sh     → force T3 threads
  12. dispatch-context-gate.sh     → scan prompt for cross-env data [NEW]
  13. remote-thread-approval-guard.sh → remote launch approval

PostToolUse:
  14. response-scanner.sh    → warn on secrets in output (cannot block)
  15. auto-log-finding.sh    → engagement finding extraction

Stop:
  16. session-end-audit.sh   → cross-environment access report [EXTENDED]
```
