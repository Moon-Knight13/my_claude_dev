#!/usr/bin/env bash
# Validate that all day-0 setup steps are complete.
#
# Auth-first: the two browser logins (gh, claude) are the ONLY manual steps —
# everything else is applied automatically by scripts/setup-day0.sh on container
# start (and on every re-run). This script therefore reports the auth gates
# first; while gh is unauthenticated, the gh-dependent items report SKIP (not
# FAIL) so the output has exactly one root-cause error and one fix command.
#
# States:
#   OK    configured
#   FAIL  needs action (listed hint) — the only state that fails the run
#   SKIP  blocked on an earlier auth gate; fixes itself once you log in
#   WARN  optional feature unavailable (never fails the run)
#
# Run again after each step — exits 0 only when nothing FAILs.
set -euo pipefail

# shellcheck source=scripts/lib/subsystems.sh disable=SC1090,SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/subsystems.sh"
# shellcheck source=scripts/lib/surface.sh disable=SC1090,SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/surface.sh"
# Load .env here too. Check 11 reads LOCAL_MODEL_ENABLED and LOCAL_MODEL_ENDPOINT
# directly, and without this it reads them from an environment where only the
# devcontainer sets them — reporting on defaults rather than on the developer's
# actual configuration. That is the failure documented in docs/PROJECT.md
# § ".env only works because something loads it", in a checker whose job is to
# catch it. Check 6 still asserts the plumbing in its own subshell, so this does
# not weaken it.
# shellcheck source=scripts/lib/load-env.sh disable=SC1090,SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/load-env.sh"

PASS=0
FAIL=0
SKIP=0
WARN=0

check() {
    local description="$1"
    local result="$2"  # "pass" | "fail" | "skip" | "warn"
    local hint="$3"

    case "$result" in
        pass)
            echo "  OK  $description"
            ((PASS++)) || true
            ;;
        skip)
            echo " SKIP $description (blocked: $hint)"
            ((SKIP++)) || true
            ;;
        warn)
            echo " WARN $description"
            echo "      -> $hint"
            ((WARN++)) || true
            ;;
        *)
            echo " FAIL $description"
            echo "      -> $hint"
            ((FAIL++)) || true
            ;;
    esac
}

echo "Day-0 Setup Validation"
echo "======================"

# Day-0 checks target repos *derived* from this template; the pristine template
# itself fails them by design (placeholder CODEOWNERS, no .env, no markers).
# is_template_repo() lives in the shared helper so setup-day0.sh reuses it.
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1090,SC1091
source "$_SCRIPT_DIR/lib/template-detect.sh"

if is_template_repo; then
    echo "  --  This is the template repo itself — day-0 checks are not applicable."
    echo "      They validate repos derived from the template."
    echo "      To run the full checklist anyway: DAY0_FORCE_FULL=1 bash scripts/check-day0.sh"
    exit 0
fi

# ── Auth gates ────────────────────────────────────────────────────────────────
# The only manual day-0 steps. Everything below "Setup" self-heals via
# scripts/setup-day0.sh once these pass.
echo "Auth gates (the only manual steps — browser OAuth, no tokens on disk)"

# 1. No token in the environment — checked BEFORE gh auth, because an env token
# makes `gh auth status` report "authenticated" via the token and would mask
# the browser-OAuth state this template requires.
if [[ -n "${GITHUB_TOKEN:-}${GH_TOKEN:-}" ]]; then
    check "No GitHub token in environment" "fail" \
        "Unset GITHUB_TOKEN/GH_TOKEN (check .env, host shell profile, devcontainer config) — this template uses gh browser OAuth so tokens never sit in env vars where any process can read them."
else
    check "No GitHub token in environment" "pass" ""
fi

# 2. gh authenticated via browser OAuth. Gates every gh-dependent item below.
GH_AUTHED=false
if gh auth status >/dev/null 2>&1; then
    GH_AUTHED=true
    check "gh CLI authenticated (browser OAuth)" "pass" ""
else
    check "gh CLI authenticated (browser OAuth)" "fail" \
        "Run in your terminal: gh auth login --hostname github.com --git-protocol https --web -s project  — then: gh auth setup-git  — then re-run: bash scripts/setup-day0.sh"
fi

# 3. GitHub Projects scope (needed to create/manage the Kanban board).
# Match the quoted 'project' scope token — an unanchored "project" also matches
# the read-only 'read:project' scope, which cannot create/manage the board.
GH_SCOPE=false
if [[ "$GH_AUTHED" == "true" ]]; then
    if gh auth status 2>&1 | grep -qF "'project'"; then
        GH_SCOPE=true
        check "gh has Projects scope" "pass" ""
    else
        check "gh has Projects scope" "fail" \
            "Grant it with: gh auth refresh -s project  — then re-run: bash scripts/setup-day0.sh"
    fi
else
    check "gh has Projects scope" "skip" "gh not authenticated"
fi

# 4. Claude CLI authenticated (browser login; credentials live in the config
# volume, never in the repo).
if ! command -v claude >/dev/null 2>&1; then
    check "Claude CLI authenticated" "fail" \
        "claude CLI not found — rebuild the devcontainer (it installs Claude Code on start)."
elif claude auth status 2>/dev/null | grep -qE '"loggedIn":[[:space:]]*true'; then
    check "Claude CLI authenticated" "pass" ""
else
    check "Claude CLI authenticated" "fail" \
        "Run in your terminal: claude auth login  (browser OAuth)"
fi

# ── Setup (auto-applied by scripts/setup-day0.sh) ────────────────────────────
echo ""
echo "Setup (auto-applied by scripts/setup-day0.sh on container start / re-run)"

# 5. CODEOWNERS populated with real owner
# Ignore comment lines: the placeholder legitimately appears in the file's header
# comments, so only real owner rules should be scanned for the unreplaced default.
if [[ -f ".github/CODEOWNERS" ]] && ! grep -v '^[[:space:]]*#' .github/CODEOWNERS | grep -q "@your-org/your-team"; then
    check "CODEOWNERS customized with real owners" "pass" ""
else
    check "CODEOWNERS customized with real owners" "fail" \
        "Run: bash scripts/setup-day0.sh  (derives the owner from the git remote; or edit .github/CODEOWNERS by hand)"
fi

# 6. .env exists AND its values actually reach the routing scripts.
# Checking only that the file exists used to report OK while nothing loaded it.
# Every consumer read the values from the environment, so on a remote box — which
# has no devcontainer containerEnv — route-model.sh fell through to its own
# defaults and returned local_disabled no matter what .env said. Assert the
# plumbing, not the file.
if [[ ! -f ".env" ]]; then
    check ".env file exists" "fail" \
        "Run: bash scripts/setup-day0.sh  (copies .env.example — then review the values)"
elif ! grep -q "load-env.sh" scripts/route-model.sh 2>/dev/null; then
    check ".env values reach the routing scripts" "fail" \
        "scripts/route-model.sh does not source scripts/lib/load-env.sh, so .env is ignored"
elif ! subsystem_enabled ROUTING; then
    check ".env loaded (local routing off in template.conf)" "pass" ""
else
    _effective_local="$(bash -c '
        source scripts/lib/load-env.sh 2>/dev/null || true
        printf "%s" "${LOCAL_MODEL_ENABLED:-false}"' 2>/dev/null || echo false)"
    if [[ "$_effective_local" == "true" ]]; then
        check ".env loaded; local routing enabled" "pass" ""
    else
        check ".env loaded; local routing disabled" "warn" \
            "LOCAL_MODEL_ENABLED is not true, so every task routes to Claude. Set it in .env to enable local offload."
    fi
fi

# 7. .claude/settings.json exists (MCP routing configured)
if [[ -f ".claude/settings.json" ]]; then
    check ".claude/settings.json exists (MCP routing)" "pass" ""
else
    check ".claude/settings.json exists (MCP routing)" "fail" \
        "Run: bash scripts/setup-day0.sh  (copies the example — then update model and endpoint if needed)"
fi

# 8. Claude plugins installed (all 5 required plugins)
_installed_plugins=$(claude plugin list 2>/dev/null || echo "")
_all_plugins_ok=true
for _p in skill-creator frontend-design code-review superpowers commit-commands; do
    if ! echo "$_installed_plugins" | grep -q "${_p}"; then
        _all_plugins_ok=false
        break
    fi
done
if [[ "$_all_plugins_ok" == "true" ]]; then
    check "All Claude plugins installed" "pass" ""
else
    check "All Claude plugins installed" "fail" \
        "Run: bash scripts/install-claude-plugins.sh  (or restart the devcontainer to re-run postStartCommand)"
fi

# 8b. Commit guard (warn-only PII/secret scan). Installed at USER scope on a box
# by provisioning (install-commit-guard.sh) so it covers every repo incl. the
# range checkout; not applied in the devcontainer. It NEVER blocks a commit — it
# prints and logs findings so a leaked secret can be rotated per SECURITY.md.
_cg_runner="$HOME/.local/lib/commit-guard/commit-scan.sh"
_cg_hooks="$(git config --global --get core.hooksPath 2>/dev/null || true)"
if [[ -x "$_cg_runner" && "$_cg_hooks" == *commit-guard* ]]; then
    if command -v gitleaks >/dev/null 2>&1; then
        check "Commit guard installed (warn-only; gitleaks present)" "pass" ""
    else
        check "Commit guard installed, but gitleaks missing (scans no-op)" "warn" \
            "Install gitleaks so staged content is scanned. The guard is warn-only either way — it never blocks a commit."
    fi
elif [[ "$(current_surface)" == "box" ]]; then
    check "Commit guard installed (warn-only PII/secret scan)" "fail" \
        "Run: bash scripts/install-commit-guard.sh (or re-run provisioning). Warn-only: never blocks a commit; prints/logs findings so secrets can be rotated per SECURITY.md. Bypassable with --no-verify — defense-in-depth, not a boundary."
else
    check "Commit guard (warn-only; box-only)" "skip" \
        "not installed in the devcontainer — applied on a box by provisioning"
fi

# 8b. Destructive-action gate (safety-guard). Installed at USER scope on a box by
# provisioning (install-ctp-bridge.sh, step 8): the PreToolUse hook confirms
# destructive commands (rm -rf, dropdb, terraform destroy, ...) before they run,
# failing closed to a deny with no human present. Not installed in the devcontainer.
_sg_lib="$HOME/.local/lib/ctp-bridge/safety-guard.sh"
_sg_hook="$HOME/.claude/hooks/pretooluse-ctp.sh"
if [[ -f "$_sg_lib" ]] && grep -q "safety_classify" "$_sg_hook" 2>/dev/null; then
    check "Destructive-action gate installed (defense-in-depth, not a sandbox)" "pass" ""
elif [[ "$(current_surface)" == "box" ]]; then
    check "Destructive-action gate installed" "fail" \
        "Run: bash scripts/install-ctp-bridge.sh (or re-run provisioning). It confirms destructive commands via the PreToolUse hook. Defeatable by obfuscation — defense-in-depth, not a sandbox."
else
    check "Destructive-action gate (box-only)" "skip" \
        "not installed in the devcontainer — applied on a box by provisioning"
fi

# 9. GitHub bootstrap has been run (completion marker written by
# bootstrap-github-settings.sh). setup-day0.sh applies it once gh is authed.
if [[ -f ".ai/bootstrap-completed" ]]; then
    check "GitHub settings bootstrapped" "pass" ""
elif [[ "$GH_AUTHED" == "true" ]]; then
    check "GitHub settings bootstrapped" "fail" \
        "Run: bash scripts/setup-day0.sh  (applies the ruleset; needs repo admin)"
else
    check "GitHub settings bootstrapped" "skip" "gh not authenticated"
fi

# 10. Kanban board bootstrapped. setup-day0.sh applies it once gh has the
# project scope.
if [[ -f ".ai/project-bootstrap-completed" ]]; then
    check "Kanban board bootstrapped" "pass" ""
elif [[ "$GH_AUTHED" == "true" && "$GH_SCOPE" == "true" ]]; then
    check "Kanban board bootstrapped" "fail" \
        "Run: bash scripts/setup-day0.sh  (creates the Project board)"
else
    check "Kanban board bootstrapped" "skip" "gh not authenticated or missing project scope"
fi

# ── Optional ──────────────────────────────────────────────────────────────────
echo ""
echo "Optional"

# 11. Local model endpoint. Surface-aware, because "configured" and "reachable"
# are the same thing on one surface and not the other:
#
#   devcontainer — the model runs on the developer's host, outside the container.
#     It cannot be installed from in here and day-0 must go green with just the
#     two logins, so unreachable is a WARN.
#   box — the endpoint arrives over the reverse tunnel the laptop bootstrap
#     writes into the SSH Host block. Enabled-but-unreachable is not an optional
#     extra there: every routing decision silently falls back to Claude while
#     .env and this check both report local routing on. That is the exact shape
#     of the failure docs/PROJECT.md records for the .env loader, so it FAILs.
#     Setting LOCAL_MODEL_ENABLED=false is the way to a green day-0 without a
#     tunnel — the point is that the reported state matches the routed state.
LOCAL_MODEL_ENABLED="${LOCAL_MODEL_ENABLED:-true}"
if [[ "$LOCAL_MODEL_ENABLED" == "true" ]]; then
    _surface="$(current_surface)"
    if [[ "$_surface" == "box" ]]; then
        LOCAL_MODEL_ENDPOINT="${LOCAL_MODEL_ENDPOINT:-http://127.0.0.1:11434}"
    else
        LOCAL_MODEL_ENDPOINT="${LOCAL_MODEL_ENDPOINT:-http://host.docker.internal:11434}"
    fi
    if curl --silent --fail --connect-timeout 2 "$LOCAL_MODEL_ENDPOINT" >/dev/null 2>&1; then
        check "local model reachable at $LOCAL_MODEL_ENDPOINT ($_surface)" "pass" ""
    elif [[ "$_surface" == "box" ]]; then
        # Unreachable is NOT a work stoppage: route-model.sh returns
        # claude:…:local_unreachable_fallback and delegate-local.sh exits 3, so
        # every task still gets done — by Claude. The local model is an
        # optimisation, and the harness has to keep working without it.
        #
        # So this WARNs by default and FAILs only when the developer has said the
        # local model is load-bearing for them (LOCAL_MODEL_REQUIRED=true). That
        # keeps the report honest — it always states that everything is routing
        # to Claude — without turning an optimisation being off into a red day-0.
        #
        # Deliberately does NOT suggest binding the model to 0.0.0.0. That advice
        # belongs to the container surface only; on a box it would publish a
        # personal machine's model onto the network the box sits on.
        _hint="Local routing is ENABLED but nothing answers, so every task routes to Claude instead. Work continues — this is a lost optimisation, not a blocker. The endpoint arrives over the reverse tunnel in your laptop's SSH Host block (RemoteForward) — re-run scripts/local/bootstrap-devbox.sh on the machine running the model, then RECONNECT (the tunnel is established at connect time). Check from the box with: curl -sS $LOCAL_MODEL_ENDPOINT . Set LOCAL_MODEL_ENABLED=false in .env to silence this, or LOCAL_MODEL_REQUIRED=true to make it a hard failure."
        if [[ "${LOCAL_MODEL_REQUIRED:-false}" == "true" ]]; then
            check "local model reachable at $LOCAL_MODEL_ENDPOINT (box, required)" "fail" "$_hint"
        else
            check "local model reachable at $LOCAL_MODEL_ENDPOINT (box) — routing to Claude" "warn" "$_hint"
        fi
    else
        check "local model reachable at $LOCAL_MODEL_ENDPOINT (devcontainer)" "warn" \
            "Optional local routing. Install + pull (https://ollama.com; ollama pull qwen2.5-coder:7b), then bind to 0.0.0.0 so the container can reach it (default 127.0.0.1 is loopback-only). See docs/TEMPLATE_GUIDE.md 'Bind Ollama so the container can reach it' — read the security disclaimer first. Or set LOCAL_MODEL_ENABLED=false in .env."
    fi
else
    echo "  --  local model check skipped (LOCAL_MODEL_ENABLED=false)"
fi

# 12. Visual explainer via GitHub Pages (optional — a WARN, never a FAIL). Only
# meaningful when the explainer is present; publishing is opt-in because Pages
# serves the page publicly.
if [[ -f docs/explainer/index.html ]]; then
    if ! gh auth status >/dev/null 2>&1; then
        check "Explainer published via GitHub Pages" "skip" "gh not authenticated"
    elif _slug="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)" \
        && gh api "repos/${_slug}/pages" >/dev/null 2>&1; then
        check "Explainer published via GitHub Pages" "pass" ""
    else
        check "Explainer published via GitHub Pages" "warn" \
            "Optional. docs/explainer/index.html is present but Pages is off, so the README link only opens locally. Enable at Settings -> Pages -> Source: 'GitHub Actions' (the 'pages' workflow then publishes it). Leave off if the page shouldn't be public."
    fi
fi

# 13. Caveman installed (optional — a WARN, never a FAIL). install-caveman.sh
# exits 0 when it cannot install, precisely so an optional statusline helper
# never aborts provisioning; that means its absence has to surface here instead.
_caveman_marker="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.template-caveman-version"
if [[ -f "$_caveman_marker" ]]; then
    check "Caveman installed ($(head -n1 "$_caveman_marker"))" "pass" ""
else
    check "Caveman installed" "warn" \
        "Optional. Run: bash scripts/install-caveman.sh and read its output — it exits 0 on failure by design. A moved upstream tag makes it refuse to install until CAVEMAN_COMMIT is reviewed and updated."
fi

echo ""
echo "Results: ${PASS} ok, ${FAIL} failed, ${SKIP} skipped, ${WARN} warnings"

if [[ $SKIP -gt 0 ]]; then
    echo "SKIP items unblock themselves — fix the auth FAILs above, then re-run: bash scripts/setup-day0.sh"
fi

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi

echo "All day-0 steps complete."
