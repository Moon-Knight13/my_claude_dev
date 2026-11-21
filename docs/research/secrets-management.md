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

### Primary: SOPS + age (encrypted .env files in repo)

**Why SOPS+age wins:**
1. **Offline** — critical for range ops where internet may not exist
2. **Zero infrastructure** — no server, no subscription, no container
3. **Fits existing architecture** — encrypted .env files replace plaintext .env,
   load-env.sh already handles the parsed output
4. **Git-backed** — encrypted secrets versioned alongside code, reviewable diffs
5. **Per-environment isolation** — `.sops.yaml` creation rules bind paths to keys
6. **Single operator** — one age key (or one per environment for harder isolation)
7. **Rotation** — `sops secrets/range.env.enc` opens editor, re-encrypts on save

**Secondary (cloud environments only): 1Password CLI**

For cloud VPS and homelab where internet is available, `op run` with `op://`
references is cleaner for secrets that change frequently or are shared with other
tools. This is additive — SOPS handles the base case, 1Password layers on where
connectivity exists.

### 4.1 Proposed architecture

```
secrets/                          # NEW directory, in repo
  range.env.enc                   # SOPS-encrypted, age backend
  homelab.env.enc                 # different creation rule (optional: different key)
  cloud.env.enc
  ctf.env.enc
  pentest.env.enc
.sops.yaml                        # creation rules, in repo
age-keys/                         # NEVER in repo
  ~/.config/sops/age/keys.txt     # age identity file (standard location)
```

**.sops.yaml example:**
```yaml
creation_rules:
  - path_regex: secrets/range\.env\.enc$
    age: >-
      age1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
  - path_regex: secrets/homelab\.env\.enc$
    age: >-
      age1yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy
  - path_regex: secrets/.*\.env\.enc$
    age: >-
      age1zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz
```

### 4.2 Mode-to-secret mapping

```
MODE              → ALLOWED SECRET FILES
─────────────────────────────────────────
platform-ops      → (none, or general.env.enc)
green-dev         → range.env.enc
red-team          → range.env.enc
red-dev           → range.env.enc
purple            → range.env.enc
blue              → range.env.enc
homelab           → homelab.env.enc
ctf               → ctf.env.enc
pentest           → pentest.env.enc
cloud-dev         → cloud.env.enc
```

### 4.3 Integration with existing load-env.sh

**New flow:**
```
1. Mode activates (mode-inject.sh / switch-profile.sh)
2. Mode config declares which secret file to use
3. load-env.sh enhanced:
   a. Load .env (non-secret config: FIREWALL_MODE, LOCAL_MODEL_*, etc.)
   b. If SECRETS_FILE set, decrypt via sops:
      sops -d "$SECRETS_FILE" | while read line; do export "$line"; done
   c. Profile overlay still works (additive)
4. Guard hook enhanced: verify SECRETS_FILE matches mode mapping
```

**load-env.sh changes (minimal):**
```bash
# After loading .env, decrypt mode-specific secrets
if [[ -n "${SECRETS_FILE:-}" && -f "$SECRETS_FILE" ]]; then
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

Purpose: prevent decrypting wrong environment's secrets for active mode.

```
1. Parse command for `sops -d` or `sops exec-env` calls
2. Extract target filename
3. Load mode-secret mapping from .claude/modes/<mode>/secret-policy.yaml
4. If target file not in allowed list → DENY
5. If no mode active → DENY all secret decryption
```

**Existing hook updates:**
- `pretooluse-ctp.sh`: Add `secrets/*.env.enc` to `CTP_SECRET_BUILTIN` for
  the encrypted files (belt and suspenders — SOPS encryption is the real gate,
  but denying raw reads prevents fumbling with `cat` on encrypted blobs)
- `mode-tool-gate.sh`: No change needed (already gates MCP tools per mode)
- `tuoni-secret-guard.sh`: No change needed (guards Tuoni paths specifically)

### 4.5 Migration path

**Phase 1: Infrastructure (no behavior change)**
1. Install `sops` and `age` (add to `check-day0.sh`)
2. Generate age key: `age-keygen -o ~/.config/sops/age/keys.txt`
3. Create `.sops.yaml` with creation rules
4. Create `secrets/` directory
5. Add `secrets/*.env.enc` to `.gitignore` exceptions (encrypted files ARE committed)

**Phase 2: Encrypt existing secrets**
1. Extract secret vars from `.env` into `secrets/range.env`
2. `sops -e secrets/range.env > secrets/range.env.enc`
3. Remove secret vars from `.env` (keep non-secret config)
4. Create encrypted files for other envs as profiles are activated
5. Remove plaintext: `rm secrets/range.env`

**Phase 3: Integration**
1. Update `load-env.sh` to decrypt `SECRETS_FILE` after loading `.env`
2. Add `SECRETS_FILE` to mode configs or profile metadata
3. Add `secret-env-gate.sh` hook
4. Update `switch-profile.sh` to set `SECRETS_FILE`

**Phase 4: Harden**
1. Update `check-day0.sh` to verify sops+age installed
2. Update `check-day0.sh` to verify no plaintext secrets in `.env`
3. Add age key backup guidance to docs
4. Test full flow per mode

### 4.6 What stays the same

- `.env` continues to exist for non-secret config (FIREWALL_MODE, LOCAL_MODEL_*, feature toggles)
- Guard stack continues to deny `.env` reads (CTP_SECRET_BUILTIN unchanged)
- Profile overlay mechanism unchanged (additive)
- MCP URL derivation unchanged (load-env.sh still derives URLs from hosts)
- All existing hooks continue to function

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

secrets/range.env.enc (encrypted, committed):
  TUONI_USERNAME=...
  TUONI_PASSWORD=...
  PROVIDENTIA_TOKEN=...
  GITLAB_TOKEN=...
  GITLAB_PROJECT=...
  OUTLINE_API_KEY=...
  MCP_PROXY_TOKEN=...
  BLOODHOUND_PASSWORD=...

secrets/cloud.env.enc (encrypted, committed):
  RUNPOD_API_KEY=...
```

---

## 5. Risk Assessment

### What SOPS+age does NOT solve
- **Mode-gated access is still a hook concern.** SOPS provides at-rest encryption
  and per-file isolation. The hook layer enforces which file gets decrypted per mode.
  A compromised hook = access to all encrypted files (if operator has the age key).
- **Decrypted secrets still exist in process environment.** Same as today — once
  decrypted, MCP servers see the env vars. SOPS moves the exposure window from
  "always on disk" to "only in process memory at runtime."
- **Age key is the crown jewel.** Losing `~/.config/sops/age/keys.txt` means
  all encrypted secrets are compromised. Must be backed up securely (USB key,
  printed paper key, 1Password for the key itself).
- **String-matching hooks are defense-in-depth, not a sandbox.** Same accepted-risk
  framing as the existing guard stack. A hostile model could obfuscate around the
  `sops -d` pattern matching. Real containment is OS-level.

### What SOPS+age improves
- Secrets encrypted at rest (not plaintext in .env)
- Per-environment files enable mode-gated hook enforcement
- Encrypted files safe to commit (backup, versioning, audit trail)
- No external service dependency (offline range ops)
- Rotation: `sops secrets/range.env.enc`, edit, save, done
- Profile system gets real teeth (profile selects secret file, not just config overlay)

---

## 6. Future Extensions

- **1Password hybrid:** For cloud/homelab envs with internet, add `op run` as
  alternative decryption backend. `load-env.sh` checks: if `SECRETS_BACKEND=op`,
  use `op run`; if `SECRETS_BACKEND=sops` (default), use `sops -d`.
- **Per-MCP secret injection:** Instead of exporting all secrets to process env,
  inject only the secrets each MCP server needs. Requires MCP launch wrapper
  changes (`mcp-wrapper.sh` already exists).
- **Age key per environment:** Strongest isolation — range age key only on
  range-connected machines, homelab key only on homelab host. Prevents single
  key compromise from exposing all environments.
- **Automated rotation hook:** Post-exercise script that prompts for new creds
  and re-encrypts the relevant secret file.

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
