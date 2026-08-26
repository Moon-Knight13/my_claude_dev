#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib/subsystems.sh disable=SC1090,SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/subsystems.sh"

if ! subsystem_enabled caveman; then
  subsystem_skip_notice caveman "Caveman install"
  exit 0
fi

if [[ "${CAVEMAN_ENABLED:-1}" != "1" ]]; then
  echo "Caveman install disabled (CAVEMAN_ENABLED=${CAVEMAN_ENABLED})."
  exit 0
fi

CAVEMAN_VERSION="${CAVEMAN_VERSION:-v1.9.0}"
CAVEMAN_MODE="${CAVEMAN_MODE:-lite}"
CAVEMAN_REPO="${CAVEMAN_REPO:-JuliusBrussee/caveman}"
# The immutable commit CAVEMAN_VERSION pointed at when it was pinned. npm cannot
# fetch a bare commit sha (npm/cli: "GitFetcher requires an Arborist constructor
# to pack a tarball"), so the install pins the *tag* and uses this value to
# detect a tag that upstream has since moved. Refresh both together with:
#   git ls-remote https://github.com/JuliusBrussee/caveman refs/tags/<tag>^{}
CAVEMAN_COMMIT="${CAVEMAN_COMMIT:-32f37af81a02a4b91c107b768f1365848e5bf005}"
MARKER_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
MARKER_FILE="$MARKER_DIR/.template-caveman-version"
mkdir -p "$MARKER_DIR"

if [[ -f "$MARKER_FILE" ]] && grep -q "^${CAVEMAN_VERSION}$" "$MARKER_FILE"; then
  echo "Caveman already installed at ${CAVEMAN_VERSION}."
else
  # Do NOT go through upstream's install.sh. It is only a shim, and its
  # curl-pipe path execs `npx -y github:<repo>` with NO ref, so it always runs
  # the DEFAULT BRANCH — whose `caveman` bin is the runtime CLI, not the
  # installer. That CLI rejects the installer's own flags ("unknown command
  # \"--only\"", and likewise \"--\"), so the shim fails every single run.
  # Invoke the installer directly at a pinned tag instead; `bin/install.js`
  # there does accept --only/--non-interactive, and skips the leading `--`.
  if ! command -v npx >/dev/null 2>&1; then
    echo "WARN: npx not found (needs Node >=18); skipping caveman."
    exit 0
  fi

  # Supply-chain check: a git tag is mutable, so confirm it still points at the
  # commit we pinned. On drift we refuse to install rather than execute code
  # nobody reviewed -- but exit 0, because an optional statusline helper must
  # not abort provisioning. scripts/check-day0.sh reports the absence.
  if command -v git >/dev/null 2>&1; then
    _resolved="$(git ls-remote "https://github.com/${CAVEMAN_REPO}" \
      "refs/tags/${CAVEMAN_VERSION}^{}" 2>/dev/null | awk '{print $1}')" || _resolved=""
    if [[ -z "$_resolved" ]]; then
      echo "WARN: could not resolve ${CAVEMAN_VERSION}; skipping the tag-drift check."
    elif [[ "$_resolved" != "$CAVEMAN_COMMIT" ]]; then
      echo "ERROR: ${CAVEMAN_VERSION} now resolves to ${_resolved},"
      echo "       but CAVEMAN_COMMIT pins ${CAVEMAN_COMMIT}. The upstream tag moved."
      echo "       Refusing to install. Review the delta, then update CAVEMAN_COMMIT."
      exit 0
    fi
  else
    echo "WARN: git not available; skipping the tag-drift check."
  fi

  if ! npx -y "github:${CAVEMAN_REPO}#${CAVEMAN_VERSION}" -- \
      --only claude --non-interactive; then
    echo "WARN: caveman install failed; continuing without it."
    exit 0
  fi
  echo "$CAVEMAN_VERSION" > "$MARKER_FILE"
fi

# Point the user-level statusLine at the plugin's statusline script. The script
# lives under a hash-versioned plugin cache path that changes on every plugin
# update, so this must be (re)resolved at container start rather than hardcoded
# in template settings. Runs on every start — the marker above only skips the
# download.
configure_statusline() {
  local settings="$MARKER_DIR/settings.json"
  local script="" candidate

  for candidate in "$MARKER_DIR"/plugins/cache/caveman/caveman/*/src/hooks/caveman-statusline.sh; do
    if [[ -f "$candidate" ]] && { [[ -z "$script" ]] || [[ "$candidate" -nt "$script" ]]; }; then
      script="$candidate"
    fi
  done

  if [[ -z "$script" ]]; then
    echo "WARN: caveman statusline script not found under plugin cache; skipping statusline setup."
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "WARN: jq not available; skipping statusline setup."
    return 0
  fi

  if [[ ! -f "$settings" ]]; then
    echo '{}' > "$settings"
  elif ! jq -e . "$settings" >/dev/null 2>&1; then
    echo "WARN: $settings is not valid JSON; refusing to touch it. Fix it, then rerun."
    return 0
  fi

  local current
  current="$(jq -r '.statusLine.command // ""' "$settings")"
  if [[ "$current" == *"caveman-statusline.sh"* && "$current" == *"$script"* ]]; then
    echo "Caveman statusline already configured."
    return 0
  fi
  if [[ -n "$current" && "$current" != *"caveman-statusline.sh"* ]]; then
    echo "Custom statusLine already set in $settings; leaving it alone."
    return 0
  fi

  local tmp
  tmp="$(mktemp)"
  jq --arg cmd "bash \"$script\"" \
    '.statusLine = {type: "command", command: $cmd}' "$settings" > "$tmp"
  mv "$tmp" "$settings"
  echo "Caveman statusline configured: $script"
}

configure_statusline

# Mode activation is session-based; this file documents intended default mode.
echo "$CAVEMAN_MODE" > "$MARKER_DIR/.caveman-default-mode"
echo "Caveman install complete. Default mode: $CAVEMAN_MODE"
