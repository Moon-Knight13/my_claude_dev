# Spoke Connectivity Redesign — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make red-team mode independent of deploybox by adding spoke IPs to container firewall allow-list for direct TCP connectivity. Tuoni self-agent on Kali handles C2 + tool execution.

**Architecture:** `spoke-firewall.sh` reads `.env` spoke IPs and adds them to existing `allowed-domains` ipset. Docker bridge NAT routes container traffic through host VPN to range. MCP servers connect to spoke services at native addresses — no port mapping, no tunnels. SSH retained for shell access only.

**Tech Stack:** Bash (firewall script, tests), YAML (skill frontmatter), JSON (settings.json — no changes needed), `curl` health checks.

**Spec:** `docs/superpowers/specs/2026-11-01-spoke-connectivity-redesign.md`

## Global Constraints

- No credentials in repo files — env vars and mounted secrets only
- Container firewall is deny-by-default; only ipset members + host:22 + host:11434 allowed
- MCP servers are STDIO transport (outbound HTTPS is app-level, not transport)
- Base hooks in `.claude/modes/base/settings.json` must survive all merges
- Tests are bash, live in `scripts/tests/`, use `ok()/bad()` pattern
- Skills use YAML frontmatter `---` format in `.claude/skills/<name>/SKILL.md`
- `.env.example` documents vars; `.env` is gitignored and parsed (never sourced)
- Commit messages end with `DCM27-Chris.M #UseTheRobotsToDestroyTheRobots` for catapult remotes, standard Claude attribution for GitHub

## Review Focus

1. **ipset persistence across container restart** — `init-firewall.sh` rebuilds ipset from scratch on each start. `spoke-firewall.sh` must run AFTER `init-firewall.sh`, not during it, since the ipset is destroyed and recreated. Call it from `project-setup.sh` or `postStartCommand`.
2. **DNS vs IP in .env** — spoke vars may contain hostnames instead of IPs. `spoke-firewall.sh` must handle DNS resolution (ipset requires IPs, not hostnames). Fail gracefully if resolution fails (spoke unreachable, not container broken).
3. **TUONI_URL derivation** — MCP config uses `${TUONI_URL}`. This must be set to `https://<SPOKE_KALI_HOST>:8443` in container env. Document derivation in `.env.example`. Consider adding `TUONI_URL` as derived var in `load-env.sh`.
4. **Engagement YAML `kali_agent_id` stale** — Tuoni agent IDs change if Kali is redeployed. Bootstrap skill must update engagement YAML, and skills that consume it must handle "agent not found" gracefully.

---

### Task 1: `spoke-firewall.sh` — Firewall IP Allow Script

**Files:**
- Create: `scripts/spoke-firewall.sh`
- Create: `scripts/tests/test-spoke-firewall.sh`

**Interfaces:**
- Consumes: `.env` vars via `scripts/lib/load-env.sh` (`SPOKE_KALI_HOST`, `SPOKE_DEPLOYBOX_HOST`, `RANGE_GIT_HOST`, `PROVIDENTIA_HOST`, `OUTLINE_HOST`)
- Produces: spoke IPs added to `allowed-domains` ipset; exit 0 with count of IPs added

- [ ] **Step 1: Write failing tests for `spoke-firewall.sh`**

Tests in `scripts/tests/test-spoke-firewall.sh`. No real ipset — test argument parsing, IP validation, DNS resolution fallback, env var handling. Tests:

```bash
# test: script succeeds with no spoke vars set (adds 0)
# test: valid IP format accepted
# test: invalid IP format triggers DNS resolution attempt
# test: empty var skipped silently
# test: reports count of IPs added
# test: idempotent — running twice produces same result
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash scripts/tests/test-spoke-firewall.sh`
Expected: all FAIL (script does not exist)

- [ ] **Step 3: Implement `spoke-firewall.sh`**

Structure (~30 lines):
```
load_env()        — source load-env.sh
for each spoke var (SPOKE_DEPLOYBOX_HOST, SPOKE_KALI_HOST, RANGE_GIT_HOST, PROVIDENTIA_HOST, OUTLINE_HOST):
  skip if empty
  validate IP format
  if hostname: resolve via dig, fail gracefully
  ipset add -exist allowed-domains "$ip"
  echo status
report count
```

Key details:
- Uses `ipset add -exist` (no-op for duplicates, idempotent)
- Handles both IP and hostname inputs
- Exits 0 even if some vars unset (partial connectivity is fine)
- Exits non-zero only on script errors (bad load-env, etc.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash scripts/tests/test-spoke-firewall.sh`
Expected: all PASS

- [ ] **Step 5: Commit**

```bash
git add scripts/spoke-firewall.sh scripts/tests/test-spoke-firewall.sh
git commit -m "feat: spoke-firewall.sh — add spoke IPs to container allow-list

Reads SPOKE_DEPLOYBOX_HOST, SPOKE_KALI_HOST, RANGE_GIT_HOST from .env
and adds each to allowed-domains ipset. Handles DNS resolution for
hostname values. Idempotent via ipset add -exist.

DCM27-Chris.M #UseTheRobotsToDestroyTheRobots"
```

---

### Task 2: Firewall Integration + Health Check Update

**Files:**
- Modify: `.devcontainer/init-firewall.sh` (add spoke-firewall call)
- Modify: `scripts/check-health.sh` (spoke section)
- Modify: `.env.example` (add `PROVIDENTIA_HOST`, `OUTLINE_HOST`; document spoke IP requirements)
- Create or modify: `scripts/tests/test-spoke-firewall-integration.sh`

**Interfaces:**
- Consumes: `spoke-firewall.sh` from Task 1; existing `init-firewall.sh` ipset
- Produces: spoke IPs allowed on container startup; health check reports spoke reachability

- [ ] **Step 1: Update `init-firewall.sh`**

Add at end of file, after firewall verification:
```bash
# Add spoke IPs if .env exists (spoke connectivity)
SPOKE_FW="$(dirname "$0")/../scripts/spoke-firewall.sh"
if [[ -x "$SPOKE_FW" ]] && [[ -f "$(dirname "$0")/../.env" ]]; then
    echo "Adding spoke IPs to allow-list..."
    bash "$SPOKE_FW" || echo "WARNING: spoke-firewall.sh failed — spoke connectivity may be unavailable"
fi
```

Note: runs AFTER ipset creation and firewall rules — Review Focus #1 satisfied.

- [ ] **Step 2: Update spoke section in `scripts/check-health.sh`**

Replace tunnel checks with direct connectivity probes:
```bash
# Spoke connectivity — direct IP check
for var in SPOKE_DEPLOYBOX_HOST SPOKE_KALI_HOST RANGE_GIT_HOST PROVIDENTIA_HOST OUTLINE_HOST; do
    ip="${!var:-}"
    [[ -z "$ip" ]] && continue
    if ipset test allowed-domains "$ip" 2>/dev/null; then
        # Try TCP connect to verify reachability (port 443 for services, 22 for spokes)
        probe_port=443
        [[ "$var" == SPOKE_* ]] && probe_port=22
        if timeout 3 bash -c "echo >/dev/tcp/$ip/$probe_port" 2>/dev/null; then
            ok "Spoke $var ($ip) reachable"
        else
            warn "Spoke $var ($ip) in firewall but unreachable" "Check VPN"
        fi
    else
        warn "Spoke $var ($ip) NOT in firewall allow-list" "Run spoke-firewall.sh"
    fi
done
```

- [ ] **Step 3: Update `.env.example` spoke section**

Add comments about IP requirement for firewall:
```
# IMPORTANT: Spoke hosts must be IPs (not hostnames) for firewall allow-list.
# spoke-firewall.sh resolves hostnames via DNS, but IPs are preferred.
# spoke-firewall.sh runs at container startup and on /mode switch.
```

- [ ] **Step 4: Run tests**

Run: `bash scripts/tests/test-check-health.sh`
Expected: all PASS

- [ ] **Step 5: Commit**

```bash
git add .devcontainer/init-firewall.sh scripts/check-health.sh .env.example
git commit -m "feat: integrate spoke-firewall with container startup + health

init-firewall.sh calls spoke-firewall.sh after ipset creation.
Health check probes spoke IPs for direct reachability.
Documents IP requirement in .env.example.

DCM27-Chris.M #UseTheRobotsToDestroyTheRobots"
```

---

### Task 3: Kali Bootstrap + Pre-Engagement Cache Skills

**Files:**
- Create: `.claude/skills/kali-bootstrap/SKILL.md`
- Create: `.claude/skills/pre-engagement-cache/SKILL.md`

**Interfaces:**
- kali-bootstrap consumes: tuoni-mcp tools, engagement YAML schema
- kali-bootstrap produces: verified Kali self-agent with plugins, `kali_agent_id` in engagement YAML
- pre-engagement-cache consumes: range-intel MCP, outline-readonly MCP, obsidian-mcp, engagement YAML
- pre-engagement-cache produces: Obsidian notes with timestamps, `cache_timestamp` in engagement YAML

- [ ] **Step 1: Write kali-bootstrap skill**

`.claude/skills/kali-bootstrap/SKILL.md` with frontmatter:
```yaml
---
name: kali-bootstrap
description: "Verify Tuoni self-agent on Kali + deploy plugins. Run before engagement, during green-dev phase. Use when operator says 'bootstrap kali', 'check kali', or before first red-team mode switch."
---
```

Skill body — procedural steps:

1. **Check Tuoni API** — `tuoni_status` or health endpoint. If unreachable, verify spoke IP in firewall (`ipset test allowed-domains <kali-ip>`) and VPN connectivity.
2. **List agents** — `tuoni_agents_list`. Look for agent with hostname matching Kali.
3. **If no self-agent:**
   - List listeners — `tuoni_listeners_list`. Find or create localhost listener.
   - Generate payload for Kali (Linux, matching arch).
   - Deploy payload on Kali. Use SSH to Kali (direct, IP in firewall) to deploy.
4. **Verify self-agent** — `tuoni_send_command` to Kali agent: `whoami`, `ip addr`.
5. **Deploy plugins** — `tuoni_upload_file` to upload plugin JARs if not present.
6. **Record agent ID** — update engagement YAML `kali_agent_id` field.

- [ ] **Step 2: Write pre-engagement-cache skill**

`.claude/skills/pre-engagement-cache/SKILL.md` with frontmatter:
```yaml
---
name: pre-engagement-cache
description: "Cache Providentia, GitLab, and wiki intel into Obsidian before red-team engagement. Run in green-dev mode when range-intel and outline MCPs are connected."
---
```

Skill body — procedural steps:

1. **Verify prerequisites** — green-dev mode, range-intel responding, outline responding, obsidian-mcp responding, engagement YAML with targets.
2. **Cache Providentia per target** — write to `raw/providentia/<hostname>.md`
3. **Cache GitLab READMEs per target** — write to `raw/gitlab/<hostname>.md`
4. **Cache wiki vulns-docs** — write to `wiki/vulnerabilities/<topic>.md`
5. **Cache wiki doctrine** — write to `wiki/doctrine/<topic>.md`
6. **Update engagement YAML** — set `cache_timestamp: <ISO timestamp>`
7. **Report** — list cached items, warn if any target had no data.

- [ ] **Step 3: Validate skills load**

```bash
for skill in kali-bootstrap pre-engagement-cache; do
    head -4 ".claude/skills/$skill/SKILL.md" | grep -q "^name:" && echo "OK: $skill" || echo "FAIL: $skill"
done
```

- [ ] **Step 4: Commit**

```bash
git add .claude/skills/kali-bootstrap/SKILL.md .claude/skills/pre-engagement-cache/SKILL.md
git commit -m "feat: kali-bootstrap + pre-engagement-cache skills

kali-bootstrap: verify Tuoni self-agent, deploy plugins, record agent ID.
pre-engagement-cache: cache Providentia/GitLab/wiki intel into Obsidian.

DCM27-Chris.M #UseTheRobotsToDestroyTheRobots"
```

---

### Task 4: Engagement YAML + PRD Amendments + Addendum Update

**Files:**
- Modify: `scripts/validate-engagement.sh`
- Modify: `scripts/tests/test-engagement-yaml.sh`
- Modify: `docs/planning/prd-v2.md`
- Modify: `docs/planning/prd-v2-addendum.md`

**Interfaces:**
- Consumes: engagement YAML validator, PRD, addendum
- Produces: `kali_agent_id` and `cache_timestamp` fields in schema; PRD FR-K2 amended, FR-K5 added, NFR-O5 amended; addendum updated

- [ ] **Step 1: Write failing tests — new engagement YAML fields**

Add to `scripts/tests/test-engagement-yaml.sh`:
```bash
# test: kali_agent_id field accepted (optional, string)
# test: cache_timestamp field accepted (optional, ISO timestamp string)
# test: validator warns if cache_timestamp older than 24 hours
```

- [ ] **Step 2: Update `scripts/validate-engagement.sh`**

Add after existing field validation:
```bash
# Optional: kali_agent_id (Tuoni self-agent on Kali)
kali_id="$(_yq '.kali_agent_id // ""' "$FILE")"
if [[ -n "$kali_id" ]]; then
    ok "kali_agent_id: $kali_id"
fi

# Optional: cache_timestamp (pre-engagement intel cache)
cache_ts="$(_yq '.cache_timestamp // ""' "$FILE")"
if [[ -n "$cache_ts" ]]; then
    cache_epoch=$(date -d "$cache_ts" +%s 2>/dev/null || echo 0)
    now_epoch=$(date +%s)
    age_hours=$(( (now_epoch - cache_epoch) / 3600 ))
    if [[ $age_hours -gt 24 ]]; then
        warn "cache_timestamp is ${age_hours}h old — consider refreshing"
    else
        ok "cache_timestamp: $cache_ts (${age_hours}h ago)"
    fi
fi
```

- [ ] **Step 3: Amend PRD**

In `docs/planning/prd-v2.md`:

**FR-K1:** Append: "Deploy box IP added to container firewall allow-list
(`allowed-domains` ipset) for direct TCP access. SSH ProxyJump retained
for interactive shell operations."

**FR-K2:** Append: "Tuoni self-agent on Kali enables tool execution through
tuoni-mcp. Container reaches Tuoni API directly — spoke IP in container
firewall allow-list. No SSH tunnel required for API access. SSH to Kali
retained for interactive shell fallback only."

**FR-K5 (new):** After FR-K4: "Engagement resilience — red-team mode
operates with zero dependency on deploy box. Critical intel pre-cached in
Obsidian before engagement start (via `/pre-engagement-cache` skill).
Tuoni MCP + Obsidian MCP are the only hard dependencies during live
engagement."

**NFR-O5:** Replace with: "Spoke connectivity failure degrades gracefully.
Mechanisms: VPN reconnect for range access; SSH to Kali for Tuoni server
restart; Obsidian cache for offline intel; `spoke-firewall.sh` re-run for
IP changes. Mode still usable for local work."

- [ ] **Step 4: Update addendum**

In `docs/planning/prd-v2-addendum.md`, update "Spoke Connectivity" section:

Replace SSH tunnel decision with:
```markdown
**Solution (revised):** Specific-IP firewall allow. `spoke-firewall.sh`
reads spoke IPs from `.env` and adds them to `allowed-domains` ipset.
Docker bridge NAT routes container traffic through host to VPN-connected
range hosts. MCP servers connect to native spoke addresses — no port
mapping or tunnels.

**Previous approach (superseded):** SSH tunnels through
`host.docker.internal`. Rejected 2026-11-02 — operational cost (tunnel
lifecycle, port mapping, health monitoring, SSH permission rules) not
justified by marginal security benefit of encrypting same-machine hop.

**Evaluated alternatives (retained from previous analysis):**
| Option | Verdict |
|--------|---------|
| Host networking | Destroys firewall isolation. Rejected |
| Docker bridge routing to VPN | Works — this is what we use (NAT, not raw routing) |
| VPN client inside container | Overkill, conflicts with host VPN. Rejected |
| socat on host | Viable but no encryption. Rejected |
| SSH tunnels through host | Operational cost too high for marginal benefit. Superseded |
```

- [ ] **Step 5: Run tests**

Run: `bash scripts/tests/test-engagement-yaml.sh`
Expected: all PASS

- [ ] **Step 6: Commit**

```bash
git add scripts/validate-engagement.sh scripts/tests/test-engagement-yaml.sh \
       docs/planning/prd-v2.md docs/planning/prd-v2-addendum.md
git commit -m "feat: engagement YAML schema + PRD amendments for spoke redesign

Adds kali_agent_id and cache_timestamp to engagement YAML.
Amends FR-K1, FR-K2, adds FR-K5 (engagement resilience), amends NFR-O5.
Updates addendum: SSH tunnels superseded by specific-IP allow.

DCM27-Chris.M #UseTheRobotsToDestroyTheRobots"
```

---

## PRD Alignment Check

| PRD Ref | Requirement | Option C Compliance | Notes |
|---------|-------------|-------------------|-------|
| FR-K1 | Deploy box spoke via host.docker.internal | **PASS** — IP in ipset, SSH for shell | Amendment adds firewall allow detail |
| FR-K2 | Tuoni MCP over HTTPS, tunneled through host | **AMEND** — direct HTTPS, not tunneled | Simpler, same end result |
| FR-P2 | Spoke preflight ("Am I ready?") | **PASS** — health check probes spoke IPs | Direct TCP check, no tunnel health |
| NFR-O5 | Graceful degradation | **PASS** — degradation table in spec | VPN reconnect, SSH fallback, Obsidian cache |
| NFR-D2 | Tuoni authoritative, never cached | **PASS** — no change | Direct HTTPS to Tuoni, queried fresh |
| NFR-S4 | MCP STDIO, pinned versions | **PASS** — no change | Connectivity method irrelevant to transport |
| Addendum | SSH tunnel selected | **SUPERSEDE** — document pivot rationale | Decision record updated |

All PRD requirements satisfied or amended. No requirement violated. Key
amendment: FR-K2 says "tunneled through host.docker.internal" — changed to
"direct TCP through Docker bridge NAT" with same functional outcome.
