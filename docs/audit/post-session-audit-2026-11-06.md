# Post-Session Security Audit — 2026-11-06

**Repo:** Moon-Knight13/my_claude_dev  
**Branch:** main (`baec859`)  
**Auditor:** Claude Opus 4.6 (automated)  
**Scope:** Secrets, dead code, config consistency, CI health, git hygiene, recent commits

---

## Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 0     |
| HIGH     | 0     |
| MEDIUM   | 4     |
| LOW      | 4     |
| INFO     | 10    |

No credentials, tokens, or private keys found in tracked files or git history.

---

## MEDIUM

### M1. Internal hostnames in tracked files

**Risk:** Private range domain names exposed in committed files. If repo leaked, reveals organizational naming convention.

| File | Hostnames |
|------|-----------|
| `config/claude/CLAUDE.md` | `crp.cr14.net`, `dcm.ex` |
| `.claude/skills/spoke-health/SKILL.md` | `crp.cr14.net` |
| `docs/planning/prd-v2.md` | `wiki.crp.cr14.net`, `git.crp.cr14.net`, `providentia.crp.cr14.net` |
| `docs/superpowers/plans/2026-11-05-t3-code-phase0-validation.md` | `crp.cr14.net` |

**Mitigation:** Repo is private. Consider abstracting hostnames behind variables or documenting this as accepted risk.

### M2. `tuoni-plugins/` not in `.gitignore`

**Risk:** 69MB separate git repo sitting untracked in working tree. Accidental `git add .` or `git add -A` would commit entire subtree into parent repo, including 31MB of Claude worktrees.

**Fix:** Add `tuoni-plugins/` to `.gitignore`.

### M3. Base mode `settings.json` missing `Stop` hook

**Risk:** Active `.claude/settings.json` includes a `Stop` hook for `session-end-audit.sh`. Base mode's `settings.json` at `.claude/modes/base/settings.json` does not. If `start-mode.sh` copies from base, audit trail has a gap.

**Fix:** Sync Stop hook block into base mode settings.

### M4. Orphaned security hook — `pretooluse-source-priority.sh`

**Risk:** `scripts/hooks/pretooluse-source-priority.sh` is a red-team source-priority guard (enforces Tier 1/2/3 query ordering). Not referenced by any `settings.json`. Guard is inactive — source-priority violations would pass silently.

**Fix:** Wire into red-team mode's settings.json or document as intentionally deferred.

---

## LOW

### L1. `*.egg-info/` not in `.gitignore`

`mcp-servers/range-intel/src/range_intel_mcp.egg-info/` (28KB) untracked. Standard Python build artifact.

**Fix:** Add `*.egg-info/` to `.gitignore`.

### L2. 7 unreferenced utility scripts

Not called by any workflow, hook, documentation, or other script:

- `scripts/check-tuoni-version.sh`
- `scripts/ctp-deploy-range.sh`
- `scripts/ghidra-env.sh`
- `scripts/install-rea-mcp.sh`
- `scripts/scaffold-project.sh`
- `scripts/local/bootstrap-hub.sh`
- `scripts/local/setup-t3-service.sh`
- `scripts/host/t3-validate.sh`

**Action:** Review for removal or document intended use.

### L3. `docker-monthly-prune` systemd trio unreferenced

`scripts/host/docker-monthly-prune.*` (service + timer + install script) — self-contained but not referenced by setup docs or install automation.

**Action:** Document in setup instructions or remove if no longer needed.

### L4. 4 deprecated BMAD skills on disk

Superseded skills still present (gitignored, not tracked):

- `bmad-create-architecture/` (now `bmad-architecture`)
- `bmad-create-prd/` (now `bmad-prd`)
- `bmad-edit-prd/` (now `bmad-prd`)
- `bmad-validate-prd/` (now `bmad-prd`)

**Action:** Delete deprecated copies to reduce disk clutter and avoid confusion.

---

## INFO

1. **CI healthy** — all 7 workflows (ci, container-scan, pages, repository-audit, secret-scan, semgrep, tests) parse valid YAML, reference existing scripts, and pin actions to full SHAs.
2. **No secrets in git history** — `git log --all -p` grep found no real credentials, tokens, or private keys across all branches.
3. **`.env` properly handled** — gitignored, not tracked. `.env.example` has empty credential fields. `config/mcp-secrets.yaml` holds variable names only.
4. **`.mcp.json` paths valid** — all referenced binaries, scripts, and venvs exist.
5. **All 7 modes structurally complete** — each has `system-prompt.md` + `settings.json`; non-base modes have `tool-policy.yaml`.
6. **All 8 registered hooks exist and are executable.**
7. **No large files in git history** — no blobs >1MB across all branches.
8. **`.gitignore` comprehensive** — covers `.env`, `*.pem`, `*.key`, `*.p12`, `secrets.*`, `__pycache__/`, `.venv/`, `node_modules/`, engagement dirs.
9. **Recent 10 commits clean** — docs, tests, configs only. No debug output, temp files, or credential leaks.
10. **Test fixtures correctly designed** — fake JWT in `test-secret-scan.sh` uses `fakesig` suffix; test IPs are RFC 1918 fabrications.

---

## Recommendations (priority order)

1. Add `tuoni-plugins/` and `*.egg-info/` to `.gitignore` (M2, L1)
2. Sync Stop hook into base mode `settings.json` (M3)
3. Wire or document `pretooluse-source-priority.sh` (M4)
4. Triage unreferenced scripts — keep or remove (L2, L3)
5. Delete deprecated BMAD skill copies (L4)
6. Accept or mitigate internal hostname exposure (M1)
