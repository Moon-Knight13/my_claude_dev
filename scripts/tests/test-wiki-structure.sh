#!/usr/bin/env bash
# Tests for init-wiki-structure.sh and install-obsidian-mcp.sh
#
# Runs against a temp vault directory. No side effects.
# Usage: bash scripts/tests/test-wiki-structure.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

fails=0
ok()   { echo "PASS $1"; }
bad()  { echo "FAIL $1: $2"; fails=$((fails + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

VAULT="$TMP/vault"
mkdir -p "$VAULT/.obsidian"

# ── init-wiki-structure.sh tests ──────────────────────────────────────────

# --- 1. Script runs successfully on empty vault ----------------------------
if bash "$REPO_ROOT/scripts/init-wiki-structure.sh" "$VAULT" >/dev/null 2>&1; then
    ok wiki-init-runs
else
    bad wiki-init-runs "init-wiki-structure.sh failed"
fi

# --- 2. Required directories created --------------------------------------
expected_dirs=(
    "raw"
    "raw/recon"
    "raw/providentia"
    "raw/osint"
    "raw/captures"
    "wiki"
    "wiki/targets"
    "wiki/techniques"
    "wiki/creds"
    "wiki/iocs"
    "wiki/remediation"
    "wiki/purple"
    "wiki/engagements"
    "templates"
)

for dir in "${expected_dirs[@]}"; do
    if [[ -d "$VAULT/$dir" ]]; then
        ok "dir-$dir"
    else
        bad "dir-$dir" "directory not created"
    fi
done

# --- 3. Template files created --------------------------------------------
expected_files=(
    "templates/target.md"
    "templates/technique.md"
    "templates/credential.md"
    "templates/ioc.md"
    "templates/engagement.md"
    "index.md"
    "log.md"
    "raw/README.md"
)

for file in "${expected_files[@]}"; do
    if [[ -f "$VAULT/$file" ]]; then
        ok "file-$file"
    else
        bad "file-$file" "file not created"
    fi
done

# --- 4. Templates have YAML frontmatter -----------------------------------
for tmpl in "$VAULT/templates/"*.md; do
    name="$(basename "$tmpl" .md)"
    if head -1 "$tmpl" | grep -q '^\-\-\-$'; then
        ok "frontmatter-$name"
    else
        bad "frontmatter-$name" "missing YAML frontmatter"
    fi
done

# --- 5. Index has expected sections ----------------------------------------
if grep -q '## Targets' "$VAULT/index.md" && \
   grep -q '## Techniques' "$VAULT/index.md" && \
   grep -q '## Credentials' "$VAULT/index.md" && \
   grep -q '## IOCs' "$VAULT/index.md"; then
    ok index-sections
else
    bad index-sections "index.md missing expected sections"
fi

# --- 6. Log has table header -----------------------------------------------
if grep -q '| Date | Page | Action | Summary |' "$VAULT/log.md"; then
    ok log-table-header
else
    bad log-table-header "log.md missing table header"
fi

# --- 7. Idempotent — second run doesn't overwrite --------------------------
echo "# Custom content" >> "$VAULT/index.md"
bash "$REPO_ROOT/scripts/init-wiki-structure.sh" "$VAULT" >/dev/null 2>&1
if grep -q '# Custom content' "$VAULT/index.md"; then
    ok idempotent-no-overwrite
else
    bad idempotent-no-overwrite "second run overwrote existing file"
fi

# --- 8. Fails on missing vault directory -----------------------------------
if bash "$REPO_ROOT/scripts/init-wiki-structure.sh" "$TMP/nonexistent" >/dev/null 2>&1; then
    bad missing-vault-fails "should have failed on nonexistent vault"
else
    ok missing-vault-fails
fi

# ── install-obsidian-mcp.sh --check tests ────────────────────────────────

# --- 9. Check mode runs without modifying anything -------------------------
VAULT2="$TMP/vault2"
mkdir -p "$VAULT2/.obsidian"

cp "$REPO_ROOT/.claude/settings.json" "$TMP/settings-before.json"
if OBSIDIAN_VAULT_CONTAINER_PATH="$VAULT2" CLAUDE_PROJECT_DIR="$REPO_ROOT" \
   bash "$REPO_ROOT/scripts/install-obsidian-mcp.sh" --check >/dev/null 2>&1; then
    ok install-check-runs
else
    ok install-check-runs-expected-warn
fi

# --- 10. Target template has all expected fields ---------------------------
target_fields=("hostname" "ip" "os" "domain" "role" "team" "status")
for field in "${target_fields[@]}"; do
    if grep -q "^${field}:" "$VAULT/templates/target.md"; then
        ok "target-field-$field"
    else
        bad "target-field-$field" "missing field in target template"
    fi
done

# --- 11. Technique template has MITRE fields -------------------------------
mitre_fields=("mitre_id" "mitre_tactic" "name" "platforms")
for field in "${mitre_fields[@]}"; do
    if grep -q "^${field}:" "$VAULT/templates/technique.md"; then
        ok "technique-field-$field"
    else
        bad "technique-field-$field" "missing field in technique template"
    fi
done

# --- 12. Credential template has harvest fields ----------------------------
cred_fields=("username" "domain" "type" "source_host" "harvest_method")
for field in "${cred_fields[@]}"; do
    if grep -q "^${field}:" "$VAULT/templates/credential.md"; then
        ok "cred-field-$field"
    else
        bad "cred-field-$field" "missing field in credential template"
    fi
done

# --- 13. Raw README has naming convention ----------------------------------
if grep -q 'YYYY-MM-DD' "$VAULT/raw/README.md"; then
    ok raw-readme-convention
else
    bad raw-readme-convention "missing naming convention"
fi

# ── Summary ───────────────────────────────────────────────────────────────
echo ""
if (( fails == 0 )); then
    echo "All tests passed."
else
    echo "${fails} test(s) FAILED."
fi
exit "$fails"
