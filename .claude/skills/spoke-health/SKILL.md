---
name: spoke-health
description: "Check connectivity and health of all hub spokes. Use when operator says 'check health', 'spoke status', 'am I connected', or before switching to an operational mode."
modes: [platform-ops, red-team, purple, red-dev, green-dev]
---

# Spoke Health Check

Verify all hub-to-spoke connections are live and functional.
Run before switching to an operational mode, or when connectivity
seems degraded.

## Procedure

### Step 1: SSH Proxy Chain

Test each hop in order. If a hop fails, everything below it is unreachable.

```bash
ssh -o ConnectTimeout=5 hub echo "ok"           # host gateway
ssh -o ConnectTimeout=10 deploybox echo "ok"     # deploy spoke (via hub)
ssh -o ConnectTimeout=10 kali echo "ok"          # weapons spoke (via hub)
ssh -o ConnectTimeout=15 -T range-git 2>&1 | head -1  # GitLab SSH (via deploybox)
```

Report each hop: OK or FAIL with error.

### Step 2: HTTPS Services

```bash
curl -so /dev/null -w "%{http_code}" --connect-timeout 5 https://providentia.crp.cr14.net
curl -so /dev/null -w "%{http_code}" --connect-timeout 5 https://wiki.crp.cr14.net
curl -so /dev/null -w "%{http_code}" --connect-timeout 5 https://git.crp.cr14.net
curl -sk -o /dev/null -w "%{http_code}" --connect-timeout 5 "https://${SPOKE_KALI_HOST}:${SPOKE_KALI_C2_WEB_PORT:-8443}/"
```

Expected: 200 or 302 for range services, 401 for Tuoni (auth required = alive).

### Step 3: MCP Server Probes

Test MCP servers that depend on spoke connectivity:

- **range-intel:** `mcp__range-intel__range_environments` — should return environment list
- **outline-readonly:** `mcp__outline-readonly__outline_search` with a known term
- **tuoni-mcp:** `tuoni_agents_list` — should return (possibly empty) agent list

### Step 4: Mode Readiness

Based on results, report which modes are available:

| Mode | Requires |
|------|----------|
| platform-ops | Nothing (always available) |
| green-dev | range-intel + outline-readonly + deploybox SSH |
| red-team | All of green-dev + tuoni-mcp + kali SSH |
| red-dev | tuoni-mcp + kali SSH |
| purple | All of red-team |

### Step 5: Report

Output a table:

```
Spoke            Protocol  Status  Latency
─────────────────────────────────────────
Hub (127.0.0.1)  SSH       OK      0.1s
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

Mode Readiness
──────────────
platform-ops  READY
green-dev     READY
red-team      READY
red-dev       READY
purple        READY
```

If any spoke is down, report which modes are affected and what to fix.
