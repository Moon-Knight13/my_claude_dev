# Environment Profiles

Profile templates for `~/.claude-profiles/`. Each `.env` file defines the
environment for a specific use case.

## Usage

```bash
# Copy a profile to ~/.claude-profiles/
mkdir -p ~/.claude-profiles
cp profiles/range.env ~/.claude-profiles/

# Activate by setting ACTIVE_PROFILE before launching Claude Code
export ACTIVE_PROFILE=range

# Or switch at runtime
scripts/switch-profile.sh ctf
```

## Profiles

| File | Purpose |
|------|---------|
| `range.env` | Cyber range — full spoke connectivity, all MCPs |
| `ctf.env` | CTF platforms (HTB, THM, PG) — no range spokes |
| `pentest.env` | Client engagements — custom spokes per engagement |
| `homelab.env` | Homelab infra — local Ollama, no range |
| `general.env` | Software dev — minimal, dev mode only |

## How It Works

`scripts/lib/load-env.sh` loads `.env` first (base config), then overlays
`~/.claude-profiles/$ACTIVE_PROFILE.env` on top. Environment variables set by
the caller still win over both files.

Without `ACTIVE_PROFILE`, behavior is identical to before profiles existed.
