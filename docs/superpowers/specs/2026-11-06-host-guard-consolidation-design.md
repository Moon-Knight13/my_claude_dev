# Host Guard Config Consolidation

**Date:** 2026-11-06
**Status:** Draft — pending approval

## Intent

Move guard configuration from scattered config files into `.env` as
single source of truth for host-mode operation. Remote-box config files
remain as fallback (unchanged behavior).

## Why

Guard stack reads three separate config files designed for remote shared
boxes:
- `~/.ctp-bridge.conf` — secret paths, PII paths, ctp-bridge box/team gates
- `~/.config/safety-guard.conf` — destructive-action allowlist
- `~/.config/git-guard.conf` — destructive-git allowlist

On host, these files don't exist. No config = guards partially inert:
- Secret-path deny: OFF (no `CTP_SECRET_PATHS` set)
- PII-path deny: OFF (no `CTP_PII_PATHS` set)
- Destructive gate: ON but with no allowlist (all destructive ops ask — correct default)
- Git guard: ON but with no allowlist (all destructive git ops ask — correct default)
- CTP-bridge box/team gates: N/A on host (no ctp-bridge calls)

`.env` already holds all spoke config, MCP creds, and feature toggles.
Guard config belongs there too.

## Design

### Precedence

`.env` vars override config-file values. Config files remain as fallback.
This means: remote-box provisioning (which writes config files) is
unchanged. Host users set values in `.env` and skip config files entirely.

### New `.env` vars

```
# ── Guard configuration ──────────────────────────────────────────────────
# Secret paths: denied to all agent tools (Read/Write/Edit/Bash).
# Space-separated globs. ~/ expands to $HOME. **/ matches any directory.
GUARD_SECRET_PATHS=~/.ssh/id_* **/.env ~/.gnupg/**

# Org PII/IP paths: denied to agent tools (opt-in, empty = no PII guard).
GUARD_PII_PATHS=

# Destructive-action allowlist: exempt specific verbs from confirmation.
# Empty = all destructive ops require confirmation (recommended default).
GUARD_SAFETY_ALLOWLIST=

# Destructive-git allowlist: exempt specific git ops from confirmation.
# Empty = all destructive git ops require confirmation (recommended default).
GUARD_GIT_ALLOWLIST=
```

GUARD_ prefix avoids collision with ctp-guard.sh internal globals
(`CTP_SECRET_PATHS` etc.).

### Code changes

**`scripts/lib/guard-stack.sh`** — in `guard_stack_load()`, after all
three config loaders run, apply `.env` overrides:

```bash
# Source .env for host-mode config consolidation
_GS_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_GS_HERE/load-env.sh" 2>/dev/null || true

# .env overrides config files (host single-source pattern)
[[ -n "${GUARD_SECRET_PATHS:-}" ]]     && CTP_SECRET_PATHS="$GUARD_SECRET_PATHS"
[[ -n "${GUARD_PII_PATHS:-}" ]]        && CTP_PII_PATHS="$GUARD_PII_PATHS"
[[ -n "${GUARD_SAFETY_ALLOWLIST:-}" ]] && _SAFETY_ALLOWLIST="$GUARD_SAFETY_ALLOWLIST"
[[ -n "${GUARD_GIT_ALLOWLIST:-}" ]]    && _GITGUARD_ALLOWLIST="$GUARD_GIT_ALLOWLIST"
```

**`.env.example`** — add the guard config section with documented defaults.

**`scripts/host-setup.sh`** — after MCP setup, check if `.env` has guard
vars and print guidance if missing.

### What is NOT changed

- Config file parsers (`ctp_load_config`, `safety_load_config`,
  `gitguard_load_config`) — untouched.
- CTP-bridge box/team gates — still work, just not configured on host
  (they only fire when someone calls `ctp-bridge`, which doesn't happen
  on host).
- Remote-box provisioning — still writes config files, which still work.
- Guard stack fail-closed behavior — unchanged.
- Audit trail, secret scan, mode-tool-gate — unchanged (already work on host).

### Host-appropriate defaults

| Guard | Host default | Reason |
|-------|-------------|--------|
| `GUARD_SECRET_PATHS` | `~/.ssh/id_* **/.env ~/.gnupg/**` | Protect SSH keys, env files, GPG |
| `GUARD_PII_PATHS` | empty | Opt-in only |
| `GUARD_SAFETY_ALLOWLIST` | empty | All destructive ops ask (safe default) |
| `GUARD_GIT_ALLOWLIST` | empty | All destructive git ops ask (safe default) |

### Testing

Run existing guard-stack tests after changes — they test the file-based
path which is unchanged. Add one test verifying env override takes
precedence over config file value.

## Non-goals

- No changes to mode system
- No changes to secret-scan hook
- No devcontainer changes
- No docs update (separate workstream)

## Anti-goals

- Guard config in code or committed files — `.env` is gitignored
- Removing config file support — remote boxes still need it
