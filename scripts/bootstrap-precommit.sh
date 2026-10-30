#!/usr/bin/env bash
set -euo pipefail

if [[ ! -f ".pre-commit-config.yaml" ]]; then
  echo "No .pre-commit-config.yaml found. Skipping pre-commit bootstrap."
  exit 0
fi

min_precommit_version="3.7.0"

version_lt() {
  # Returns success if $1 < $2
  [[ "$(printf '%s\n' "$1" "$2" | sort -V | head -n1)" != "$2" ]]
}

install_or_upgrade_precommit() {
  if ! command -v python3 >/dev/null 2>&1; then
    echo "WARNING: python3 is required to install pre-commit. Skipping."
    exit 0
  fi

  python3 -m ensurepip --upgrade >/dev/null 2>&1 || true
  python3 -m pip install --user --break-system-packages "pre-commit>=${min_precommit_version}"
  export PATH="$HOME/.local/bin:$PATH"
}

if ! command -v pre-commit >/dev/null 2>&1; then
  install_or_upgrade_precommit
else
  current_precommit_version="$(pre-commit --version | awk '{print $2}')"
  if version_lt "$current_precommit_version" "$min_precommit_version"; then
    install_or_upgrade_precommit
  fi
fi

_saved_hooks_path="$(git config --get core.hooksPath 2>/dev/null || true)"
if [[ -n "$_saved_hooks_path" ]]; then
  echo "Temporarily unsetting core.hooksPath for pre-commit install."
  git config --unset-all core.hooksPath
fi

pre-commit install

if [[ -n "$_saved_hooks_path" ]]; then
  git config core.hooksPath "$_saved_hooks_path"
  echo "Restored core.hooksPath -> $_saved_hooks_path"
fi

# Patch generated hook to degrade gracefully when pre-commit is not installed
# (e.g. host-side commits while container is down). Warn and exit 0 instead of
# failing so a broken container never blocks committing a fix.
_hook="$(git rev-parse --git-dir)/hooks/pre-commit"
if [[ -f "$_hook" ]]; then
  sed -i '/exec.*-mpre_commit/i\    "$INSTALL_PYTHON" -c "import pre_commit" 2>/dev/null || { echo "pre-commit not available — skipping checks." >&2; exit 0; }' "$_hook"
  sed -i 's/echo .* not found\..*/echo "pre-commit not available — skipping checks." >\&2/' "$_hook"
  sed -i 's/exit 1$/exit 0/' "$_hook"
  echo "Patched pre-commit hook for graceful host-side fallback."
fi

if [[ "${PRECOMMIT_INSTALL_HOOK_ENVS:-0}" == "1" ]]; then
  pre-commit install --install-hooks
fi

# Keep startup deterministic; only update hook pins when explicitly requested.
if [[ "${PRECOMMIT_AUTOUPDATE:-0}" == "1" ]]; then
  pre-commit autoupdate
fi

echo "pre-commit bootstrap complete."
