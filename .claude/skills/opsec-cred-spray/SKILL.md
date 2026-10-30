---
name: opsec-cred-spray
description: "OPSEC guard skill: enforces lockout policy enumeration before any credential spraying. Prevents account lockouts that alert defenders. Invoke before any password spray or brute-force attempt."
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
1. Harvested credentials from other hosts (password reuse)
2. Seasonal patterns: `Season+Year!` (`Autumn2026!`)
3. Company name patterns: `CompanyName+123!`
4. Common defaults for the specific platform (from README/wiki)
5. Single common password only if nothing else available

### Step 5: Execute spray

- One password across ALL targets, then wait full window
- Log every attempt (success AND failure) with timestamp
- Monitor for lockout indicators between rounds
- If ANY lockout detected: STOP ALL spray immediately

### Step 6: On lockout detection

1. **STOP** all authentication attempts immediately
2. **Wait** full lockout duration plus buffer
3. **Report** to operator — lockout is a detection event
4. **Assess** whether SOC/blue team has been alerted
5. **Decide** with operator: continue with adjusted parameters or abort

## What to flag

- Any bulk auth attempt without prior lockout enumeration
- Spray rate exceeding calculated safe parameters
- Running crackmapexec/hydra without explicit `--lockout-threshold` or equivalent
- More than one password per observation window per account
- Spray against accounts marked as honeypots in engagement YAML
