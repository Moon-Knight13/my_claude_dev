# Secrets Management — Multi-Environment Design

**Date:** 2026-11-21
**Status:** Research / proposal — no code changes
**Scope:** my_claude_dev hub, all environments (range, homelab, cloud VPS)

---

## 1. Current State Audit

### 1.1 How secrets flow today

```
.env (gitignored, plaintext)
  │
  ├── load-env.sh parses KEY=VALUE lines (never sourced)
  │   ├── Env > file (caller env wins)
  │   ├── Last-wins within file
  │   └── ACTIVE_PROFILE overlay from ~/.claude-profiles/<name>.env
  │
  ├── Derives MCP URLs from *_HOST vars
  │   PROVIDENTIA_HOST → PROVIDENTIA_URL
  │   OUTLINE_HOST     → OUTLINE_API_URL
  │   RANGE_GIT_HOST   → GITLAB_URL
  │   SPOKE_KALI_HOST  → TUONI_URL
  │
  └── GUARD_* vars extend/replace guard stack config
      GUARD_SECRET_PATHS   (extends, additive only)
      GUARD_PII_PATHS      (extends, additive only)
      GUARD_SAFETY_ALLOWLIST (replaces when set)
      GUARD_GIT_ALLOWLIST    (replaces when set)
```

**Secret variables in .env:**
- `TUONI_USERNAME`, `TUONI_PASSWORD`
- `PROVIDENTIA_TOKEN`, `GITLAB_TOKEN`, `GITLAB_PROJECT`
- `OUTLINE_API_KEY`
- `MCP_PROXY_TOKEN`
- `BLOODHOUND_PASSWORD`
- `RUNPOD_API_KEY`

### 1.2 Guard stack protecting secrets

**Built-in floor (hardcoded, never overridable):**
```
CTP_SECRET_BUILTIN='**/.env ~/.ssh/id_* ~/.gnupg/**'
```

**Hook chain (PreToolUse, top to bottom, first deny wins):**

| Hook | Matcher | What it guards |
|------|---------|----------------|
| `pretooluse-ctp.sh` | `Bash\|Read\|Write\|Edit` | Guard stack: secret paths, PII paths, ctp-bridge, destructive ops, git |
| `tuoni-secret-guard.sh` | `Bash` | Tuoni config/ssl/keys/DB paths specifically |

**Additional layers:**
- `secret-scan.sh` (UserPromptSubmit) — blocks prompts containing secrets
- `response-scanner.sh` (PostToolUse) — warns on secrets in tool output
- `.gitignore` covers `.env`, `.env.*`, `secrets.*`, `*.key`, `*.keystore`
- Commit guard (user-scope, warn-only) scans staged content via gitleaks

### 1.3 Profile system (already exists, partially built)

`load-env.sh` already supports `ACTIVE_PROFILE`:
```
~/.claude-profiles/<name>.env   # overlays .env, env still wins
```

Profile templates exist in `profiles/`:
- `range.env` — full spoke connectivity, all range MCPs
- `homelab.env` — local services, Ollama, no spokes
- `ctf.env`, `pentest.env`, `general.env`

`scripts/switch-profile.sh` validates MCPs and spokes per profile.

### 1.4 What's missing

1. **Secrets are plaintext in .env and profile files** — anyone with file access reads them
2. **No per-mode secret isolation** — red-team mode can read homelab creds (same .env)
3. **No rotation workflow** — manual edit of .env per exercise
4. **Profile overlay untested** — `~/.claude-profiles/` empty on this machine
5. **No secret injection for MCP servers** — MCP processes inherit full env
6. **Guard stack protects Claude from reading .env** but the secrets are still unencrypted at rest

---

## 2. Options Evaluation

### Requirements matrix

| Req | Description |
|-----|-------------|
| R1 | Per-environment secret sets (range, homelab, cloud) |
| R2 | Mode-gated access (red-team can't see homelab creds) |
| R3 | Hook enforcement (block wrong-env secret access) |
| R4 | No secrets in repo files |
| R5 | Works offline (range may lack internet) |
| R6 | Single operator (no team key mgmt overhead) |
| R7 | Rotation support (some creds change per exercise) |

### 2.1 SOPS + age — Encrypted secrets in git

**How it works:** SOPS encrypts values in YAML/JSON/ENV/INI files, leaving keys
readable. `age` provides the encryption backend — a single key file, no GPG
keyring complexity. `.sops.yaml` maps file paths to recipient keys.

**Pattern:**
```
secrets/
  range.env.enc      # encrypted with age key, committed
  homelab.env.enc    # different age key (or same)
  cloud.env.enc
.sops.yaml           # creation rules mapping paths to keys
```

Decrypt at runtime: `sops exec-env secrets/range.env.enc 'command'`
or: `sops -d secrets/range.env.enc > /tmp/range.env` (ephemeral)

| Req | Score | Notes |
|-----|-------|-------|
| R1 | **Yes** | One encrypted file per environment |
| R2 | **Partial** | Different age keys per env possible, but hook enforcement needed |
| R3 | **Partial** | Hooks must gate which .enc file gets decrypted per mode |
| R4 | **Yes** | Only encrypted values in repo |
| R5 | **Yes** | Fully offline, age is local-only |
| R6 | **Yes** | Single age key, no server |
| R7 | **Yes** | Edit encrypted file in place with `sops secrets/range.env.enc` |

**Pros:** Zero infrastructure, offline, encrypted secrets can live in git for
backup/versioning, familiar .env format, reviewable diffs (key names visible).

**Cons:** Decrypted secrets exist in memory/tempfiles during use. Age key file
itself needs protecting (but it's one file, not N secrets). No MCP server.

### 2.2 1Password CLI (`op`) — Vault-backed secrets

**How it works:** `op run` resolves `op://vault/item/field` references into env
vars at process launch. `op inject` templates config files. Touch ID / biometric
unlock on supported platforms.

**Pattern:**
```
.env.tpl:
  TUONI_PASSWORD=op://Range/tuoni/password
  PROVIDENTIA_TOKEN=op://Range/providentia/token

Launch: op run --env-file=.env.tpl -- claude
```

| Req | Score | Notes |
|-----|-------|-------|
| R1 | **Yes** | Separate vaults per environment |
| R2 | **Partial** | Vault scoping possible, but `op run` injects all at once |
| R3 | **Partial** | Hooks can verify which vault references are allowed per mode |
| R4 | **Yes** | Only `op://` references in repo files |
| R5 | **No** | Requires 1Password service (cloud sync, auth) |
| R6 | **Yes** | Personal 1Password account |
| R7 | **Yes** | Update in 1Password, all consumers get new value |

**Pros:** Strong encryption at rest, biometric unlock, rotation handled in
1Password, existing MCP servers (community: `op-mcp`, `onepassword-agent-mcp`).

**Cons:** Not offline. Subscription cost ($36/yr individual). MCP servers are
community-maintained, not official. 1Password's official position is that raw
secrets should not flow through MCP. Cloud dependency for range ops is a blocker.

### 2.3 pass / gopass + direnv — Unix password store

**How it works:** GPG/age-encrypted files in `~/.password-store/`, one file per
secret. `gopass` adds multiple mounts (stores) and age backend. direnv's `.envrc`
calls `gopass show` to populate env vars per directory.

**Pattern:**
```
~/.password-store/
  range/
    tuoni-password.age
    providentia-token.age
  homelab/
    unifi-token.age
  cloud/
    runpod-apikey.age

.envrc:
  export TUONI_PASSWORD=$(gopass show range/tuoni-password)
```

| Req | Score | Notes |
|-----|-------|-------|
| R1 | **Yes** | Subdirectories per environment |
| R2 | **Partial** | Different stores possible, but direnv loads what .envrc says |
| R3 | **Partial** | Hook must validate which store/prefix is active |
| R4 | **Yes** | Secrets in encrypted store outside repo |
| R5 | **Yes** | Fully offline, GPG/age local |
| R6 | **Yes** | Single operator, one GPG/age key |
| R7 | **Yes** | `gopass edit range/tuoni-password` |

**Pros:** Unix-native, offline, granular (one file per secret), git-backed store
for versioning, age backend avoids GPG complexity.

**Cons:** Extra tooling (gopass + direnv). No MCP server. direnv approval step
per directory. Secrets in memory during shell session.

### 2.4 Bitwarden CLI (`bw` / `bws`) — Vault-backed

**How it works:** `bw` CLI with session token, or `bws` (Secrets Manager CLI)
with service account token. Official MCP server exists (GPL-3.0, July 2025).

| Req | Score | Notes |
|-----|-------|-------|
| R1 | **Yes** | Collections or projects per environment |
| R2 | **Partial** | Project-scoped tokens possible with `bws` |
| R3 | **Partial** | Same hook pattern needed |
| R4 | **Yes** | Only references in repo |
| R5 | **No** | Requires Bitwarden server (cloud or self-hosted) |
| R6 | **Yes** | Personal account |
| R7 | **Yes** | Update in Bitwarden |

**Pros:** Official MCP server. Open source (self-hostable). `bws` supports
project-scoped tokens (least privilege per env). Free tier for personal use.

**Cons:** Not offline (blocker for range). Self-hosted Bitwarden is heavy
(SQL Server or PostgreSQL + Docker). Session token management adds friction.

### 2.5 HashiCorp Vault — Full secrets platform

| Req | Score | Notes |
|-----|-------|-------|
| R1 | **Yes** | Namespaces, policies, mounts |
| R2 | **Yes** | Policy-based access control |
| R3 | **Yes** | Token-scoped, auditable |
| R4 | **Yes** | Dynamic secrets possible |
| R5 | **Yes** | Self-hosted, works offline |
| R6 | **No** | Massive operational overhead for single operator |
| R7 | **Yes** | Dynamic secrets, lease-based rotation |

**Verdict:** Overkill. Operational cost (unsealing, policy authoring, server
maintenance) far exceeds single-operator needs.

### 2.6 Infisical / Doppler — Hosted secrets platforms

| Req | Score | Notes |
|-----|-------|-------|
| R1 | **Yes** | Environment-scoped by design |
| R2 | **Yes** | Environment + project scoping |
| R3 | **Partial** | CLI injection, hook still needed |
| R4 | **Yes** | Only references in repo |
| R5 | **No** | Cloud-hosted (Infisical self-host possible but heavy) |
| R6 | **Yes** | Free tier |
| R7 | **Yes** | Built-in rotation |

**Verdict:** Good for cloud-only workflows. Offline blocker for range. Infisical
self-hosted adds Docker + PostgreSQL overhead similar to Vault-lite.

### 2.7 git-crypt — Transparent git encryption

**How it works:** GPG-based smudge/clean filters. Encrypted files look like
binary blobs in git, transparently decrypted on checkout.

| Req | Score | Notes |
|-----|-------|-------|
| R1 | **Partial** | Per-file, not per-environment natively |
| R2 | **No** | Single key, all-or-nothing decrypt |
| R3 | **No** | No mode-based access control |
| R4 | **Yes** | Encrypted at rest in repo |
| R5 | **Yes** | Offline |
| R6 | **Yes** | Single key |
| R7 | **No** | Awkward — must re-encrypt on change |

**Verdict:** Too coarse. No per-environment isolation. Single unlock key means
all secrets or none.

---

## 3. Comparison Matrix

| Option | R1 Env Sets | R2 Mode Gate | R3 Hooks | R4 No Repo Secrets | R5 Offline | R6 Solo Op | R7 Rotation | Complexity |
|--------|:-----------:|:------------:|:--------:|:-----------------:|:----------:|:----------:|:-----------:|:----------:|
| **SOPS+age** | Y | Partial | Partial | Y | **Y** | Y | Y | Low |
| **1Password** | Y | Partial | Partial | Y | **N** | Y | Y | Low |
| **gopass+direnv** | Y | Partial | Partial | Y | **Y** | Y | Y | Medium |
| **Bitwarden** | Y | Partial | Partial | Y | **N** | Y | Y | Medium |
| **Vault** | Y | Y | Y | Y | Y | **N** | Y | High |
| **Infisical** | Y | Y | Partial | Y | **N** | Y | Y | Medium |
| **git-crypt** | Partial | N | N | Y | Y | Y | N | Low |

**Key insight:** No tool natively provides mode-gated access (R2) in our model.
That is always a hook-layer concern. The tool provides per-environment isolation;
hooks enforce which environment is active per mode.

---

## 4. Recommendation

### Honest cost/benefit: what changes from current .env

Before recommending a tool, what does any change actually buy?

| Concern | Current .env + hooks | Encrypted/vault-backed |
|---------|---------------------|------------------------|
| Agent reads secrets | **No** — hook denies `.env` reads | **No** — same hooks |
| Secrets at rest on disk | Plaintext in `.env` | Encrypted or in vault |
| File access = all secrets | **Yes** — `cat .env` | No (needs key/auth) |
| Per-environment isolation | **No** — one `.env`, all envs | **Yes** — separate sets |
| Mode-gated access | **No** — all secrets in one file | **Yes** — hook gates which set loads |
| Rotation | Edit `.env` manually | Same (nicer with vault UI) |
| MCP servers see all env vars | **Yes** | **Yes** (until per-MCP injection added) |

**Two real wins:** per-environment isolation with mode gating, and defense in
depth at rest. If you only run one environment and trust disk security, current
state is functional. The upgrade pays off for multi-environment + mode-gated access.

### Primary: Bitwarden Secrets Manager (`bws`)

**Why `bws` wins given existing Bitwarden:**
1. **Already owned** — no new subscription, vault already populated
2. **Project-scoped tokens** — service account token per project, isolated from
   vault logins/passwords/cards/identities (completely separate from `bw`)
3. **Per-environment isolation** — one Bitwarden SM project per env
4. **Rotation via familiar UI** — update in Bitwarden, all consumers get new value
5. **Official MCP server exists** — GPL-3.0 (uses `bw`, not `bws` yet — watch for updates)
6. **No new tooling to learn** — same platform, different CLI

**Critical safety note:** `bws` (Secrets Manager CLI) uses project-scoped service
account tokens. It **cannot** access vault logins, passwords, cards, or identities.
This is the correct CLI. `bw` (regular CLI) unlocks the **entire vault** — do not
use `bw` for agent-accessible secret injection.

**Offline fallback: SOPS + age**

For range ops where internet may not exist mid-session, SOPS+age as fallback.
Secrets resolved from Bitwarden at session start; if range needs re-read
mid-session offline, SOPS-encrypted file is the backup path. This may never
be needed — secrets load once at launch.

### 4.1 Proposed architecture

```
Bitwarden Secrets Manager:
  Project: range-creds          # TUONI_*, PROVIDENTIA_TOKEN, GITLAB_TOKEN, etc.
  Project: homelab-creds        # UniFi token, local service keys
  Project: cloud-creds          # RUNPOD_API_KEY, Hetzner token
  Project: ctf-creds            # per-exercise creds
  Project: pentest-creds        # per-engagement creds

Service account tokens (one per project):
  ~/.config/bws/range.token     # scoped to range-creds only
  ~/.config/bws/homelab.token   # scoped to homelab-creds only
  ~/.config/bws/cloud.token     # scoped to cloud-creds only
  (tokens gitignored, never in repo)

Optional SOPS fallback (offline range):
  secrets/range.env.enc         # SOPS-encrypted, age backend, committed
  ~/.config/sops/age/keys.txt   # age identity file
```

### 4.2 Mode-to-secret mapping

```
MODE              → BWS PROJECT         → TOKEN FILE
──────────────────────────────────────────────────────
platform-ops      → (none)              → (none)
green-dev         → range-creds         → ~/.config/bws/range.token
red-team          → range-creds         → ~/.config/bws/range.token
red-dev           → range-creds         → ~/.config/bws/range.token
purple            → range-creds         → ~/.config/bws/range.token
blue              → range-creds         → ~/.config/bws/range.token
homelab           → homelab-creds       → ~/.config/bws/homelab.token
ctf               → ctf-creds           → ~/.config/bws/ctf.token
pentest           → pentest-creds       → ~/.config/bws/pentest.token
cloud-dev         → cloud-creds         → ~/.config/bws/cloud.token
```

### 4.3 Integration with existing load-env.sh

**New flow:**
```
1. Mode activates (mode-inject.sh / switch-profile.sh)
2. Mode config declares SECRETS_PROJECT and BWS_TOKEN_FILE
3. load-env.sh enhanced:
   a. Load .env (non-secret config: FIREWALL_MODE, LOCAL_MODEL_*, etc.)
   b. If BWS_TOKEN_FILE set and bws available:
      BWS_ACCESS_TOKEN=$(<"$BWS_TOKEN_FILE") bws secret list --project-id "$SECRETS_PROJECT" \
        | parse and export each secret as env var
   c. Fallback: if bws unavailable and SECRETS_FILE set (SOPS path):
      sops -d "$SECRETS_FILE" | parse and export
   d. Profile overlay still works (additive)
4. Guard hook: verify SECRETS_PROJECT matches mode mapping
```

**load-env.sh changes (minimal):**
```bash
# After loading .env, inject mode-specific secrets from Bitwarden SM
if [[ -n "${BWS_TOKEN_FILE:-}" && -f "$BWS_TOKEN_FILE" && -n "${SECRETS_PROJECT:-}" ]]; then
    if command -v bws &>/dev/null; then
        while IFS=$'\t' read -r key val; do
            [[ "$key" =~ ^[A-Za-z_] ]] || continue
            [[ -z "${!key+x}" ]] && export "$key=$val"
        done < <(BWS_ACCESS_TOKEN="$(<"$BWS_TOKEN_FILE")" bws secret list \
            --project-id "$SECRETS_PROJECT" --output tsv 2>/dev/null \
            | awk -F'\t' '{print $2 "\t" $3}')
    fi
# SOPS fallback for offline environments
elif [[ -n "${SECRETS_FILE:-}" && -f "$SECRETS_FILE" ]]; then
    if command -v sops &>/dev/null; then
        while IFS='=' read -r key val; do
            [[ "$key" =~ ^[A-Za-z_] ]] || continue
            [[ -z "${!key+x}" ]] && export "$key=$val"
        done < <(sops -d "$SECRETS_FILE" 2>/dev/null)
    fi
fi
```

### 4.4 Hook enforcement design

**New guard: `secret-env-gate.sh`** (PreToolUse, Bash)

Purpose: prevent accessing wrong environment's secrets for active mode.

```
1. Parse command for `bws` or `sops -d` calls
2. For bws: extract --project-id
3. For sops: extract target filename
4. Load mode-secret mapping from .claude/modes/<mode>/secret-policy.yaml
5. If project/file not in allowed list → DENY
6. If no mode active → DENY all secret access
```

**Also gate token files:**
- Add `~/.config/bws/*.token` to `CTP_SECRET_BUILTIN` (hook denies Read/Bash
  access to token files — same pattern as `~/.ssh/id_*`)

**Existing hook updates:**
- `pretooluse-ctp.sh`: Add `~/.config/bws/*` and `secrets/*.env.enc` to
  `CTP_SECRET_BUILTIN` (denies raw reads of tokens and encrypted files)
- `mode-tool-gate.sh`: No change needed (already gates MCP tools per mode)
- `tuoni-secret-guard.sh`: No change needed (guards Tuoni paths specifically)

### 4.5 Migration path

**Phase 1: Bitwarden Secrets Manager setup (no code change)**
1. Enable Secrets Manager in Bitwarden account (may need upgrade)
2. Create projects: range-creds, homelab-creds, cloud-creds
3. Add secrets to each project (mirror current .env secret vars)
4. Create service account tokens scoped per project
5. Store tokens: `~/.config/bws/range.token`, etc.
6. Install `bws` CLI

**Phase 2: Wire into load-env.sh**
1. Add `bws` secret injection to `load-env.sh` (code above)
2. Add `SECRETS_PROJECT` and `BWS_TOKEN_FILE` to profile metadata
3. Update `switch-profile.sh` to set these vars per profile
4. Test: `SECRETS_PROJECT=<id> BWS_TOKEN_FILE=~/.config/bws/range.token load-env.sh`

**Phase 3: Hook enforcement**
1. Add `~/.config/bws/*` to `CTP_SECRET_BUILTIN`
2. Add `secret-env-gate.sh` hook
3. Add `secret-policy.yaml` to each mode dir

**Phase 4: Remove plaintext secrets from .env**
1. Remove secret vars from `.env` (keep non-secret config)
2. Update `.env.example` to document which secrets come from Bitwarden
3. Update `check-day0.sh` to verify `bws` installed and tokens present
4. Test full flow per mode

**Phase 5 (optional): SOPS fallback for offline range**
1. Install `sops` + `age` if range needs offline mid-session secret access
2. Create `secrets/range.env.enc` as backup
3. `load-env.sh` already has fallback path (Phase 2 code)

### 4.6 What stays the same

- `.env` continues to exist for non-secret config (FIREWALL_MODE, LOCAL_MODEL_*, feature toggles)
- Guard stack continues to deny `.env` reads (CTP_SECRET_BUILTIN unchanged)
- Profile overlay mechanism unchanged (additive)
- MCP URL derivation unchanged (load-env.sh still derives URLs from hosts)
- All existing hooks continue to function
- Bitwarden vault logins/passwords/cards never touched (bws is isolated)

### 4.7 .env split after migration

```
.env (committed as .env.example, gitignored as .env):
  FIREWALL_MODE=strict
  LOCAL_MODEL_ENABLED=true
  LOCAL_MODEL_ENDPOINT=http://host.docker.internal:11434
  LOCAL_MODEL_MODEL=qwen2.5-coder:7b
  CAVEMAN_ENABLED=1
  BMAD_ENABLED=1
  HUB_SSH_USER=chris
  SPOKE_DEPLOYBOX_HOST=...     # hostnames are config, not secrets
  SPOKE_KALI_HOST=...
  RANGE_GIT_HOST=...
  PROVIDENTIA_HOST=...
  OBSIDIAN_VAULT_PATH=...
  GUARD_SECRET_PATHS=...
  GUARD_PII_PATHS=...
  # Secrets come from Bitwarden SM — see docs/research/secrets-management.md
  # SECRETS_PROJECT=<uuid>       # set by profile/mode, not here
  # BWS_TOKEN_FILE=<path>        # set by profile/mode, not here

Bitwarden Secrets Manager (project: range-creds):
  TUONI_USERNAME
  TUONI_PASSWORD
  PROVIDENTIA_TOKEN
  GITLAB_TOKEN
  GITLAB_PROJECT
  OUTLINE_API_KEY
  MCP_PROXY_TOKEN
  BLOODHOUND_PASSWORD

Bitwarden Secrets Manager (project: cloud-creds):
  RUNPOD_API_KEY
```

---

## 5. Risk Assessment

### What this does NOT solve
- **Mode-gated access is still a hook concern.** Bitwarden provides per-project
  isolation and encryption. The hook layer enforces which project token loads per
  mode. A compromised hook = access to whatever tokens exist on disk.
- **Decrypted secrets still exist in process environment.** Same as today — once
  injected, MCP servers see env vars. This moves exposure from "always on disk as
  plaintext" to "only in process memory at runtime."
- **Service account tokens are the crown jewels.** `~/.config/bws/*.token` files
  grant access to their scoped projects. Must be protected (hook-guarded, not
  readable by agent). Per-project scoping limits blast radius — losing range.token
  exposes range creds only, not homelab or cloud.
- **String-matching hooks are defense-in-depth, not a sandbox.** Same accepted-risk
  framing as existing guard stack. Real containment is OS-level.
- **bws requires internet at secret-load time.** If range goes offline before
  secrets load, they won't be available. Mitigation: load at session start (before
  range ops begin), or use SOPS fallback.

### What this improves
- Secrets no longer plaintext on disk (stored in Bitwarden, tokens scoped)
- Per-environment isolation via Bitwarden SM projects
- Mode-gated hook enforcement possible (project ID per mode)
- Rotation through familiar Bitwarden UI
- Vault logins/passwords/cards completely isolated (bws can't reach them)
- Profile system gets real teeth (profile selects project + token)
- Guard stack extended to protect token files

### Bitwarden-specific risks
- **Bitwarden Secrets Manager pricing:** May require paid plan. Check current
  free tier limits (number of secrets, service accounts, projects).
- **bws CLI maturity:** Relatively new CLI, syntax changed at v0.3.0. Pin version.
- **Official MCP server uses `bw` not `bws`:** Do NOT use the official Bitwarden
  MCP server for secret injection — it unlocks full vault. Use `bws` CLI only.

---

## 6. Future Extensions

- **Per-MCP secret injection:** Instead of exporting all secrets to process env,
  inject only the secrets each MCP server needs. Requires MCP launch wrapper
  changes (`mcp-wrapper.sh` already exists). `bws` project scoping makes this
  natural — one project per MCP server's needs.
- **SOPS offline fallback:** If range ops genuinely need mid-session secret access
  without internet, add SOPS+age encrypted files as fallback (load-env.sh already
  has the fallback path in the proposed code).
- **Automated rotation hook:** Post-exercise script that rotates range creds in
  Bitwarden SM. `bws secret edit` or API call.
- **Service account token rotation:** Rotate `bws` tokens periodically. Script to
  generate new token, update `~/.config/bws/*.token`, revoke old one.
- **Bitwarden self-hosted (Vaultwarden):** If cloud dependency becomes a concern,
  Vaultwarden on homelab gives local control. Heavy setup but removes cloud trust.

---

## 7. References

### Research sources
- [1Password: Securing MCP Servers](https://1password.com/blog/securing-mcp-servers-with-1password-stop-credential-exposure-in-your-agent)
- [1Password for Claude (browser integration)](https://1password.com/blog/1password-for-claude)
- [1Password: Where MCP Fits and Where It Doesn't](https://1password.com/blog/where-mcp-fits-and-where-it-doesnt)
- [1Password CLI: Load secrets into environment](https://developer.1password.com/docs/cli/secrets-environment-variables)
- [op-mcp (Rust, community)](https://docs.rs/crate/op-mcp/0.1.0)
- [SOPS on GitHub](https://github.com/getsops/sops)
- [GitGuardian: Comprehensive Guide to SOPS](https://blog.gitguardian.com/a-comprehensive-guide-to-sops/)
- [gopass features](https://github.com/gopasspw/gopass/blob/master/docs/features.md)
- [Bitwarden MCP Server](https://bitwarden.com/blog/bitwarden-mcp-server/)
- [Bitwarden Secrets Manager CLI](https://bitwarden.com/pdf/help-secrets-manager-cli.pdf)
- [Infisical vs HashiCorp Vault](https://infisical.com/blog/hashicorp-vault-alternatives)
- [Doppler: Secrets Management Tools 2025](https://www.doppler.com/blog/secrets-management-tools-2025)
- [dotenvage (age-encrypted .env)](https://docs.rs/crate/dotenvage/0.3.5/source/README.md)

### Internal references
- `scripts/lib/load-env.sh` — current .env loading
- `scripts/lib/guard-stack.sh` — guard stack policy
- `.claude/hooks/pretooluse-ctp.sh` — enforcement point #1
- `.claude/hooks/tuoni-secret-guard.sh` — Tuoni-specific guard
- `docs/SAFETY_GATES.md` — full hook architecture documentation
- `profiles/` — environment profile templates
- `scripts/switch-profile.sh` — profile switching
