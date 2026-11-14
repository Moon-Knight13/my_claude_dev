---
name: opsec-cred-spray
description: "OPSEC guard skill: enforces lockout policy enumeration before any credential spraying. Prevents account lockouts that alert defenders. Invoke before any password spray or brute-force attempt."
modes: [red-team, purple]
---

# OPSEC: Lockout-Aware Credential Spray

## Rule

**MUST enumerate lockout policy before any credential spraying.**

Account lockouts are high-visibility events that alert defenders. A single
lockout can compromise the entire engagement.

## When this fires

- Planning any credential spray or password guessing
- Testing harvested credentials against multiple hosts
- Any bulk authentication attempt (even 2+ targets)
- Mention of hydra, crackmapexec, spray, brute in offensive context
- **cred-harvest Phase 4.5** (automated cred-reuse spray against same-template hosts)

## Procedure

### Step 1: Enumerate lockout policy (REQUIRED)

Before any spray, determine:

| Setting | How to find | Default if unknown |
|---------|-------------|-------------------|
| Lockout threshold | AD: `net accounts /domain` via agent | Assume 3 |
| Observation window | AD: same command, or GPO query | Assume 30 min |
| Lockout duration | AD: same command | Assume 30 min |
| Reset counter | After lockout duration | Same as duration |

For non-AD targets:
- Linux PAM: check `/etc/pam.d/common-auth` for pam_faillock/pam_tally2
- Application: check documentation or test with known-bad password
- Network device: vendor documentation, usually 3-5 attempts

**fail2ban detection (Linux/BSD targets):**
- Default: 5 failures in 10 min = 10 min ban (SSH jail)
- pfSense: 3 failures = 30 min ban (more aggressive)
- Range hosts may have custom thresholds
- Probe: attempt one known-bad credential, check if port remains open
  5 seconds later. If port status changes: fail2ban active.
- Ban scope: typically per source IP, per service port. ICMP unaffected.
- **Gateway risk**: banning on a firewall/router target blocks ALL hosts
  behind it. Treat gateway targets with EXTRA caution — max 1 attempt
  before verifying port status.

### Step 2: Calculate safe spray parameters

```
max_attempts = lockout_threshold - 1
spray_window = observation_window
attempts_per_window = max_attempts
wait_between_windows = observation_window + 5 minutes buffer
```

If lockout policy UNKNOWN:
- **One attempt only** per account per observation window
- Assume 30-minute observation window
- Assume threshold of 3

### Step 3: Select spray targets

- Use Providentia host list to identify targets in scope
- Prioritize: service accounts (often no lockout), then admin accounts
- Exclude: known honeypot accounts, recently locked accounts

### Step 4: Select passwords

Order by likelihood:
1. **Harvested credentials from same-template hosts** (cred-reuse Phase 4.5 —
   highest confidence, same build = same default/deployed creds)
2. Harvested credentials from other hosts (general password reuse)
3. Seasonal patterns: `Season+Year!` (`Autumn2026!`)
4. Company name patterns: `CompanyName+123!`
5. Common defaults for the specific platform (from README/wiki)
6. Single common password only if nothing else available

### Step 5: Execute spray

- One password across ALL targets, then wait full window
- Log every attempt (success AND failure) with timestamp
- Monitor for lockout indicators between rounds
- If ANY lockout detected: STOP ALL spray immediately

### Step 6: On lockout or ban detection

1. **STOP** all authentication attempts immediately
2. **Log** OPSEC incident to engagement YAML findings (id: OPSEC-xxx)
3. **Record** ban source IP, target, timestamp, estimated expiry
4. **Wait** full lockout/ban duration plus 5-min buffer
5. **Report** to operator — lockout is a detection event
6. **Assess** whether SOC/blue team has been alerted
7. **Decide** with operator: continue with adjusted parameters or abort

**fail2ban-specific recovery:**
- Record banned source IP and estimated unban time in engagement YAML
- If alternate agent on different source IP exists: switch to that agent
- If banned target is gateway (firewall/router): ALL downstream targets
  inaccessible. Pivot to other reachable targets.
- Verify ban lifted before retrying: single TCP SYN to target port, confirm
  SYN-ACK response (not FILTERED/RST)
- After unban: reduce attempt rate to 1 per target, wait full observation
  window between attempts

### Step 7: Source IP rotation (when available)

When multiple agents exist on different hosts:
1. Map agent hostname to source IP
2. Track per-IP attempt count per target
3. When IP reaches (threshold - 1) attempts: rotate to next agent
4. If all IPs exhausted: full cooldown on all before next round
5. Record IP rotation in engagement YAML techniques_tried

## What to flag

- Any bulk auth attempt without prior lockout enumeration
- Spray rate exceeding calculated safe parameters
- Running crackmapexec/hydra without explicit `--lockout-threshold` or equivalent
- More than one password per observation window per account
- Spray against accounts marked as honeypots in engagement YAML
- SSH attempts against gateway/firewall targets without explicit fail2ban check
- More than 2 SSH attempts from same source IP to same target without pause
