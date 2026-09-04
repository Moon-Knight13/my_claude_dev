#!/usr/bin/env bash
# install-commit-guard.sh — install the warn-only commit guard at USER scope.
#
# Why user scope + a GLOBAL hook: the work does not happen only in this repo — it
# happens in the range checkout too (e.g. ~/catapult/inventories/dcm). A hook
# installed into one repo's .git/hooks would miss the others. Setting the user's
# global core.hooksPath makes the scan run on EVERY commit the user (or an agent
# acting as them) makes, in any repo, without writing anything into a pushed tree.
#
# The guard is WARN-ONLY: it never blocks a commit (owner decision, for PII and
# secrets alike). The configs travel with the install so the range checkout is
# covered without polluting it.
#
# Idempotent. Chains to a repo-local pre-commit hook if one exists, so a repo
# using the pre-commit framework still runs its own hooks.
#
# Usage:  bash scripts/install-commit-guard.sh
# The provisioner calls it through run_as_target so it lands in the developer's
# home, not root's.
set -euo pipefail

_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_REPO="$(cd "$_HERE/.." && pwd)"
# shellcheck source=scripts/host/lib/host-common.sh disable=SC1091
source "$_HERE/host/lib/host-common.sh"

SRC_RUNNER="$_HERE/commit-scan.sh"
SRC_GITLEAKS="$_REPO/.gitleaks.toml"
SRC_SEMGREP="$_REPO/.semgrep.yml"

LIB_DIR="$HOME/.local/lib/commit-guard"
HOOK_DIR="$HOME/.local/share/commit-guard/hooks"
HOOK="$HOOK_DIR/pre-commit"

host_step "Installing commit guard (warn-only) for $(id -un) (home: $HOME)"

[[ -f "$SRC_RUNNER" ]] || { host_fail "missing source: $SRC_RUNNER"; exit 1; }
command -v git >/dev/null 2>&1 || { host_fail "git is required"; exit 1; }
command -v gitleaks >/dev/null 2>&1 || \
    host_note "gitleaks not on PATH yet — the guard installs, but scans no-op with a warning until gitleaks is present"

# --- 1. runner + carried configs --------------------------------------------
mkdir -p "$LIB_DIR" "$HOOK_DIR"
install -m 0755 "$SRC_RUNNER" "$LIB_DIR/commit-scan.sh"
[[ -f "$SRC_GITLEAKS" ]] && install -m 0644 "$SRC_GITLEAKS" "$LIB_DIR/.gitleaks.toml"
[[ -f "$SRC_SEMGREP"  ]] && install -m 0644 "$SRC_SEMGREP"  "$LIB_DIR/.semgrep.yml"
host_info "runner  -> $LIB_DIR/commit-scan.sh"
host_info "configs -> $LIB_DIR/.gitleaks.toml (+ .semgrep.yml if present)"

# --- 2. the global pre-commit hook (warn-only, chains repo-local) ------------
cat > "$HOOK" <<'HOOK_EOF'
#!/usr/bin/env bash
# commit guard — warn-only PII/secret scan (installed by install-commit-guard.sh).
# Runs the scan, then chains to a repo-local pre-commit hook if one exists.
# Always exits 0: this guard never blocks a commit.
set -uo pipefail
_RUNNER="$HOME/.local/lib/commit-guard/commit-scan.sh"
[[ -x "$_RUNNER" ]] && "$_RUNNER" || true

# Chain: a repo may have its own .git/hooks/pre-commit (e.g. pre-commit
# framework). core.hooksPath shadows it, so invoke it explicitly. Its exit code
# is honoured — a repo that deliberately blocks still blocks; only THIS guard is
# warn-only.
_local="$(git rev-parse --git-dir 2>/dev/null)/hooks/pre-commit"
if [[ -x "$_local" && "$_local" != "${BASH_SOURCE[0]}" ]]; then
    exec "$_local" "$@"
fi
exit 0
HOOK_EOF
chmod 0755 "$HOOK"
host_info "hook    -> $HOOK"

# --- 3. wire core.hooksPath (do not clobber a different existing setting) -----
_current="$(run_as_target git config --global --get core.hooksPath 2>/dev/null || true)"
if [[ -z "$_current" ]]; then
    run_as_target git config --global core.hooksPath "$HOOK_DIR"
    host_info "set global core.hooksPath -> $HOOK_DIR (covers every repo, incl. the range checkout)"
elif [[ "$_current" == "$HOOK_DIR" ]]; then
    host_note "core.hooksPath already points here"
else
    host_warn "core.hooksPath is already set to '$_current' — NOT overriding it."
    host_note "to enable the guard, add '$LIB_DIR/commit-scan.sh' to the pre-commit hook in '$_current', or unset core.hooksPath and re-run."
fi

host_step "commit guard installed (warn-only)"
host_note "Commits are never blocked; findings are printed and logged to ~/.local/state/commit-guard/findings.jsonl (rule/file/line only)."
