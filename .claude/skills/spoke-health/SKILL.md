---
name: spoke-health
description: "Check connectivity and health of all hub spokes. Use when operator says 'check health', 'spoke status', 'am I connected', or before switching to an operational mode."
modes: [base, platform-ops, red-team, purple, red-dev, green-dev]
---

# Spoke Health Check

Verify all hub-to-spoke connections are live and functional.
Run before switching to an operational mode, or when connectivity
seems degraded.

## Procedure

### Step 0: Load Environment + Gateway Pre-flight

Source .env and check exercise zone gateway reachability first:

```bash
source "$CLAUDE_PROJECT_DIR/scripts/lib/load-env.sh"
source "$CLAUDE_PROJECT_DIR/scripts/lib/gateway-preflight.sh"
```

Run the gateway check (green-dev and platform-ops modes):

```bash
check_gateway_reachable
```

If the gateway is unreachable, report it prominently and **do not investigate
routing** — the gateway being down explains all exercise zone connectivity
failures. Continue with remaining spoke checks but flag that exercise zone
modes (green-dev, red-team, red-dev, purple) are blocked until the gateway
responds.

If `RANGE_GATEWAY_HOST` is not set, skip the check (non-exercise environments).

### Step 1: SSH Spokes

Hub is this machine — do not test it. Test outbound spokes only:

```bash
ssh -o ConnectTimeout=10 deploybox echo "ok"     # deploy spoke
ssh -o ConnectTimeout=10 kali echo "ok"          # weapons spoke
ssh -o ConnectTimeout=15 -T range-git 2>&1 | head -1  # GitLab SSH
```

Report each hop: OK or FAIL with error.

### Step 2: HTTPS Services

```bash
curl -so /dev/null -w "%{http_code}" --connect-timeout 5 "${SPOKE_PROVIDENTIA_URL}"
curl -so /dev/null -w "%{http_code}" --connect-timeout 5 "${SPOKE_WIKI_URL}"
curl -so /dev/null -w "%{http_code}" --connect-timeout 5 "${SPOKE_GIT_URL}"
curl -sk -o /dev/null -w "%{http_code}" --connect-timeout 5 "https://${SPOKE_KALI_HOST}:${SPOKE_KALI_C2_WEB_PORT:-8443}/"
```

Expected: 200 or 302 for range services, 401 for Tuoni (auth required = alive).

### Step 3: MCP Server Probes

Test MCP servers that depend on spoke connectivity:

- **range-intel:** `mcp__range-intel__range_environments` — should return environment list
- **outline-readonly:** `mcp__outline-readonly__outline_search` with a known term
- **tuoni-mcp:** `tuoni_agents_list` — should return (possibly empty) agent list
- **bloodhound-mcp:** any tool call (e.g. list domains) — confirms Neo4j connectivity
- **hashcat-mcp:** any tool call (e.g. list capabilities) — confirms hashcat binary accessible
- **nuclei-mcp:** any tool call (e.g. list templates) — confirms nuclei scanner available
- **ghidra-mcp:** any tool call (e.g. list functions) — confirms Ghidra headless backend reachable

### Step 4: Local Services

Check local applications that affect operator experience:

```bash
pgrep -a obsidian || pgrep -a electron
```

- **Obsidian App:** WARN if not running — not a hard failure.
  MCP writes to filesystem directly, so obsidian-mcp works without the app.
  But operator cannot browse llm-wiki artifacts in Obsidian UI.
  Message: `"WARN: Obsidian app not running. llm-wiki artifacts won't be visible in Obsidian UI. Launch with: obsidian &"`

### Step 5: Mode Readiness

Based on results, report which modes are available:

| Mode | Requires |
|------|----------|
| platform-ops | Nothing (always available) |
| green-dev | range-intel + outline-readonly + deploybox SSH |
| red-team | All of green-dev + tuoni-mcp + kali SSH + bloodhound-mcp + nuclei-mcp |
| red-dev | tuoni-mcp + kali SSH + hashcat-mcp + ghidra-mcp (optional) |
| purple | All of red-team + hashcat-mcp |

### Step 6: Report

Output a table:

```
Gateway          ICMP      Status
─────────────────────────────────────────
zone-gateway     ICMP      OK

Spoke            Protocol  Status  Latency
─────────────────────────────────────────
Deploybox        SSH       OK      0.3s
Kali             SSH       OK      0.4s
GitLab           SSH       OK      0.6s
Providentia      HTTPS     OK      0.2s
Wiki             HTTPS     OK      0.2s
GitLab           HTTPS     OK      0.3s
Tuoni            HTTPS     OK      0.2s

MCP Server       Status
────────────────────────
range-intel      OK
outline-readonly OK
tuoni-mcp        OK
bloodhound-mcp   OK
hashcat-mcp      OK
nuclei-mcp       OK
ghidra-mcp       OK

Local Service    Status
────────────────────────
Obsidian App     WARN (not running)

Mode Readiness
──────────────
platform-ops  READY
green-dev     READY
red-team      READY
red-dev       READY
purple        READY
```

If any spoke is down, report which modes are affected and what to fix.
