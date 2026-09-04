#!/usr/bin/env bash
# shellcheck disable=SC2015
# test-commit-guard.sh — the warn-only commit guard: findings are surfaced but
# the commit is NEVER blocked, the review log records rule/file/line but never
# the matched value, the carried config works outside this repo (range checkout),
# and a missing scanner degrades to a warning instead of failing the commit.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok()  { echo "  OK  $1"; ((PASS++)) || true; }
bad() { echo " FAIL $1"; ((FAIL++)) || true; }

command -v git >/dev/null 2>&1      || { echo "git required; skipping"; exit 0; }
command -v jq  >/dev/null 2>&1      || { echo "jq required; skipping"; exit 0; }
command -v gitleaks >/dev/null 2>&1 || { echo "gitleaks required; skipping"; exit 0; }

CFG="$ROOT/.gitleaks.toml"
# Fixtures assembled from fragments so the COMMITTED test file holds no literal
# secret/PII — otherwise this template's own gitleaks/semgrep CI gates would flag
# the test. Bash concatenates the adjacent strings at runtime into a valid-looking
# value that trips the scanner, which is exactly what these tests need.
SECRET='sk-ant-''api03-''Zx9Kq2mNvBcD4fGhJkLpQrStUvWxYz0123456789abcd'
EMAIL='jane.doe''@realdomain.com'

new_repo() { local d; d="$(mktemp -d)"; git -C "$d" init -q; git -C "$d" config user.email t@t.co; git -C "$d" config user.name t; printf '%s' "$d"; }

# ── 1. findings warned, but the commit still succeeds (warn-only) ────────────
R="$(new_repo)"; ST="$R/.state"
printf 'k=%s\nm=%s\n' "$SECRET" "$EMAIL" > "$R/app.conf"
git -C "$R" add app.conf
out="$(cd "$R" && COMMIT_GUARD_GITLEAKS_CONFIG="$CFG" COMMIT_GUARD_STATE="$ST" bash "$ROOT/scripts/commit-scan.sh" 2>&1)"; rc=$?
[[ $rc -eq 0 ]]                          && ok "scanner exits 0 on findings (warn-only)"      || bad "scanner exit $rc"
grep -q "SECRET" <<<"$out"               && ok "secret finding surfaced"                       || bad "secret not surfaced"
grep -q "SECURITY.md" <<<"$out"          && ok "secret warning cites SECURITY.md"              || bad "no SECURITY.md pointer"
grep -q "PII" <<<"$out"                  && ok "PII finding surfaced"                          || bad "PII not surfaced"

# ── 2. the review log records rule/file/line but NEVER the matched value ─────
LOG="$ST/findings.jsonl"
[[ -f "$LOG" ]]                          && ok "review log written"                            || bad "no review log"
grep -q '"rule":"anthropic-api-key"' "$LOG" && ok "log has rule id"                            || bad "log missing rule"
grep -q '"line":1' "$LOG"                && ok "log has line number"                           || bad "log missing line"
! grep -qF "$SECRET" "$LOG"              && ok "matched secret value NOT in log"               || bad "LEAK: secret value in log"
! grep -qF "$EMAIL"  "$LOG"              && ok "matched PII value NOT in log"                  || bad "LEAK: PII value in log"

# ── 3. clean staged content is silent, commit succeeds ──────────────────────
R2="$(new_repo)"; ST2="$R2/.state"
echo "just some harmless text" > "$R2/readme.txt"; git -C "$R2" add readme.txt
out2="$(cd "$R2" && COMMIT_GUARD_GITLEAKS_CONFIG="$CFG" COMMIT_GUARD_STATE="$ST2" bash "$ROOT/scripts/commit-scan.sh" 2>&1)"; rc2=$?
[[ $rc2 -eq 0 && -z "$out2" ]]           && ok "clean content: silent, exit 0"                 || bad "clean content not silent (rc=$rc2, out='$out2')"

# ── 4. carried config works OUTSIDE this repo, writing nothing into that tree ─
#     (models the range checkout: config travels, the pushed tree stays clean)
R3="$(new_repo)"; ST3="$(mktemp -d)"
printf 'k=%s\n' "$SECRET" > "$R3/x.conf"; git -C "$R3" add x.conf
(cd "$R3" && COMMIT_GUARD_GITLEAKS_CONFIG="$CFG" COMMIT_GUARD_STATE="$ST3" bash "$ROOT/scripts/commit-scan.sh" >/dev/null 2>&1)
grep -q anthropic-api-key "$ST3/findings.jsonl" 2>/dev/null && ok "carried config detects in a foreign repo" || bad "carried config did not detect"
[[ -z "$(find "$R3" -name 'findings.jsonl' 2>/dev/null)" ]]  && ok "nothing written into the scanned tree"    || bad "wrote into the scanned tree"

# ── 5. missing scanner degrades to a warning, commit still succeeds ─────────
BIN="$(mktemp -d)"
for t in bash env git jq date mkdir dirname cat sed grep sort head tr; do ln -s "$(command -v "$t")" "$BIN/$t" 2>/dev/null; done
R4="$(new_repo)"
printf 'k=%s\n' "$SECRET" > "$R4/y.conf"; git -C "$R4" add y.conf
out4="$(cd "$R4" && PATH="$BIN" COMMIT_GUARD_GITLEAKS_CONFIG="$CFG" COMMIT_GUARD_STATE="$R4/.st" bash "$ROOT/scripts/commit-scan.sh" 2>&1)"; rc4=$?
[[ $rc4 -eq 0 ]]                         && ok "missing gitleaks: exit 0 (never blocks)"       || bad "missing gitleaks exit $rc4"
grep -qi "not installed" <<<"$out4"      && ok "missing gitleaks: warns it did not scan"       || bad "no missing-scanner warning"

# ── 6. installer wires a GLOBAL hook that fires on a real commit, warn-only ──
FH="$(mktemp -d)"
CLAUDE_TARGET_USER="$(id -un)" CLAUDE_TARGET_HOME="$FH" HOME="$FH" bash "$ROOT/scripts/install-commit-guard.sh" >/dev/null 2>&1
[[ -x "$FH/.local/lib/commit-guard/commit-scan.sh" ]] && ok "installer places runner user-scope" || bad "runner not installed"
hp="$(HOME="$FH" git config --global --get core.hooksPath 2>/dev/null)"
[[ "$hp" == *commit-guard* ]]            && ok "installer sets global core.hooksPath"           || bad "core.hooksPath not set ($hp)"
RG="$(new_repo)"
printf 'k=%s\n' "$SECRET" > "$RG/z.conf"; git -C "$RG" add z.conf
cout="$(cd "$RG" && HOME="$FH" git commit -m "with secret" 2>&1)"; crc=$?
[[ $crc -eq 0 ]]                         && ok "global hook: commit succeeds (warn-only)"       || bad "commit blocked by hook (rc=$crc)"
grep -q "SECRET" <<<"$cout"              && ok "global hook: surfaced the finding on commit"    || bad "hook did not surface finding"

echo ""; echo "commit-guard: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
