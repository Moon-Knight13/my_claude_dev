#!/usr/bin/env bash
# Tests for scripts/validate-template.sh — runs the validator against crafted
# sandbox repos to verify file checks, subsystem toggling, CODEOWNERS guard,
# and script permission detection.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok()    { echo "  OK  $1"; ((PASS++)) || true; }
bad()   { echo " FAIL $1"; ((FAIL++)) || true; }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Core files that validate-template.sh always requires (section [1]).
CORE_FILES=(
    README.md SECURITY.md CLAUDE.md LICENSE
    .gitignore .editorconfig .env.example
    .gitleaks.toml .semgrep.yml .pre-commit-config.yaml
    .github/CODEOWNERS
    .github/workflows/ci.yml
    .github/workflows/secret-scan.yml
    .github/workflows/semgrep.yml
    .github/workflows/container-scan.yml
    .github/workflows/repository-audit.yml
    template.conf
    .github/dependabot.yml
    .github/pull_request_template.md
    .devcontainer/devcontainer.json
    .devcontainer/Dockerfile
    .devcontainer/init-firewall.sh
    .claude/settings.json.example
    .claude/commands/security-audit.md
    docs/TEMPLATE_GUIDE.md
    scripts/check-codeowners.sh
    scripts/validate-template.sh
    scripts/bootstrap-precommit.sh
    scripts/install-claude-plugins.sh
    scripts/lib/subsystems.sh
    scripts/project-setup.sh
    scripts/ci/README.md
)

# Build a minimal sandbox repo that should pass all core checks.
build_sandbox() {
    local sandbox="$1"
    rm -rf "$sandbox"
    mkdir -p "$sandbox"

    # Create directory structure and touch all core files
    for f in "${CORE_FILES[@]}"; do
        mkdir -p "$sandbox/$(dirname "$f")"
        touch "$sandbox/$f"
    done

    # Give stub .sh files a valid shebang so shellcheck (check [7]) does not
    # fail on empty files. Then make them executable (check [2]).
    find "$sandbox/scripts" -name "*.sh" -exec sh -c 'echo "#!/usr/bin/env bash" > "$1"' _ {} \;
    find "$sandbox/scripts" -name "*.sh" -exec chmod +x {} +

    # CODEOWNERS needs a real owner (not the placeholder) to pass check [8]
    echo "* @real-owner" > "$sandbox/.github/CODEOWNERS"

    # template.conf: disable all optional subsystems so only core is checked
    cat > "$sandbox/template.conf" <<'CONF'
SUBSYSTEM_ROUTING=false
SUBSYSTEM_BOARD=false
SUBSYSTEM_BMAD=false
SUBSYSTEM_CAVEMAN=false
SUBSYSTEM_DAY0=false
CONF

    # YAML files need valid syntax for check [4]
    for yml in .github/workflows/ci.yml .github/workflows/secret-scan.yml \
               .github/workflows/semgrep.yml .github/workflows/container-scan.yml \
               .github/workflows/repository-audit.yml .github/dependabot.yml \
               .pre-commit-config.yaml; do
        echo "---" > "$sandbox/$yml"
    done

    # Copy real lib files so validate-template.sh can source them
    cp "$ROOT/scripts/lib/subsystems.sh" "$sandbox/scripts/lib/subsystems.sh"
    cp "$ROOT/scripts/validate-template.sh" "$sandbox/scripts/validate-template.sh"
    chmod +x "$sandbox/scripts/validate-template.sh"

    # Copy check-codeowners.sh and its dependency
    cp "$ROOT/scripts/check-codeowners.sh" "$sandbox/scripts/check-codeowners.sh"
    chmod +x "$sandbox/scripts/check-codeowners.sh"
    mkdir -p "$sandbox/scripts/lib"
    cp "$ROOT/scripts/lib/template-detect.sh" "$sandbox/scripts/lib/template-detect.sh"

    # .shellcheckrc so shellcheck doesn't fail on disabled codes
    cp "$ROOT/.shellcheckrc" "$sandbox/.shellcheckrc" 2>/dev/null || true

    # Init a git repo (check [3] uses git check-ignore)
    (cd "$sandbox" && git init -q && git add -A && git commit -q -m "init" --allow-empty)
}

# Run validate-template.sh inside a sandbox, return its exit code.
# Output goes to $TMP/last-run.log for debugging.
run_validator() {
    local sandbox="$1"
    (cd "$sandbox" && bash scripts/validate-template.sh) >"$TMP/last-run.log" 2>&1
    echo $?
}

echo "test-validate-template"
echo "======================"

# ── Test 1: complete valid sandbox passes ─────────────────────────────────
echo ""
echo "[T1] Complete valid sandbox passes:"
SANDBOX="$TMP/t1"
build_sandbox "$SANDBOX"
rc=$(run_validator "$SANDBOX")
check "valid sandbox exits 0" "$rc" "0"

# ── Test 2: missing core file causes failure ──────────────────────────────
echo ""
echo "[T2] Missing core file causes failure:"
SANDBOX="$TMP/t2"
build_sandbox "$SANDBOX"
rm "$SANDBOX/SECURITY.md"
rc=$(run_validator "$SANDBOX")
check "missing SECURITY.md exits 1" "$rc" "1"

# ── Test 3: missing core .devcontainer file causes failure ────────────────
echo ""
echo "[T3] Missing devcontainer file causes failure:"
SANDBOX="$TMP/t3"
build_sandbox "$SANDBOX"
rm "$SANDBOX/.devcontainer/Dockerfile"
rc=$(run_validator "$SANDBOX")
check "missing Dockerfile exits 1" "$rc" "1"

# ── Test 4: subsystem OFF skips its files (not fail) ─────────────────────
echo ""
echo "[T4] Subsystem OFF skips missing files:"
SANDBOX="$TMP/t4"
build_sandbox "$SANDBOX"
# Board is OFF in template.conf, so board files should be skipped
# Verify absence: these files do not exist in sandbox
[[ ! -f "$SANDBOX/docs/KANBAN_WORKFLOW.md" ]] || bad "precondition: board file should not exist"
rc=$(run_validator "$SANDBOX")
check "board subsystem OFF, missing board files still exits 0" "$rc" "0"

# ── Test 5: subsystem ON requires its files ───────────────────────────────
echo ""
echo "[T5] Subsystem ON requires its files:"
SANDBOX="$TMP/t5"
build_sandbox "$SANDBOX"
# Enable board subsystem but don't create its files
sed -i 's/SUBSYSTEM_BOARD=false/SUBSYSTEM_BOARD=true/' "$SANDBOX/template.conf"
rc=$(run_validator "$SANDBOX")
check "board ON + missing board files exits 1" "$rc" "1"

# ── Test 6: CODEOWNERS placeholder fails ──────────────────────────────────
echo ""
echo "[T6] CODEOWNERS placeholder owner causes failure:"
SANDBOX="$TMP/t6"
build_sandbox "$SANDBOX"
# Put the placeholder in an active rule (not a comment)
echo "* @your-org/your-team" > "$SANDBOX/.github/CODEOWNERS"
# Ensure gh CLI reports this is NOT a template repo
rc=$(DAY0_FORCE_FULL=1 run_validator "$SANDBOX")
check "placeholder CODEOWNERS exits 1" "$rc" "1"

# ── Test 7: non-executable script detected ────────────────────────────────
echo ""
echo "[T7] Non-executable script causes failure:"
SANDBOX="$TMP/t7"
build_sandbox "$SANDBOX"
# Add a non-executable script
touch "$SANDBOX/scripts/broken-perms.sh"
chmod -x "$SANDBOX/scripts/broken-perms.sh"
rc=$(run_validator "$SANDBOX")
check "non-executable .sh exits 1" "$rc" "1"

# ── Test 8: invalid YAML detected ────────────────────────────────────────
echo ""
echo "[T8] Invalid YAML causes failure:"
if command -v python3 &>/dev/null; then
    SANDBOX="$TMP/t8"
    build_sandbox "$SANDBOX"
    echo "invalid: yaml: [unterminated" > "$SANDBOX/.github/workflows/ci.yml"
    rc=$(run_validator "$SANDBOX")
    check "bad YAML exits 1" "$rc" "1"
else
    echo "  --  python3 not available; YAML test skipped"
fi

# ── Results ───────────────────────────────────────────────────────────────
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ $FAIL -eq 0 ]] || exit 1
echo "All validate-template tests passed."
