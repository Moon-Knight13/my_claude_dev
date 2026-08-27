#!/usr/bin/env bash
# Install official Anthropic Claude Code plugins.
# Idempotent — skips plugins that are already installed.
# Plugins are stored in the Claude Code config volume (/home/node/.claude)
# and persist across container rebuilds.
set -euo pipefail

plugins=(
  skill-creator@claude-plugins-official
  frontend-design@claude-plugins-official
  code-review@claude-plugins-official
  superpowers@claude-plugins-official
  commit-commands@claude-plugins-official
)

# `claude` is on PATH in the devcontainer but NOT on a remote dev box, where the
# CLI ships inside the VSCode extension. Calling it bare failed the whole script
# on line 21 with "claude: command not found" — on the surface this repository
# exists to provision. Resolve it the same way provision-remote-box.sh does.
CLAUDE_BIN="${CLAUDE_BIN:-}"
if [[ -z "$CLAUDE_BIN" ]]; then
  if command -v claude >/dev/null 2>&1; then
    CLAUDE_BIN="$(command -v claude)"
  else
    for _cand in "${CLAUDE_TARGET_HOME:-$HOME}"/.vscode-server/extensions/anthropic.claude-code-*/resources/native-binary/claude; do
      [[ -x "$_cand" ]] && CLAUDE_BIN="$_cand"
    done
  fi
fi
if [[ -z "$CLAUDE_BIN" ]]; then
  echo "claude CLI not found (not on PATH, and no VSCode extension binary under ${CLAUDE_TARGET_HOME:-$HOME}/.vscode-server)" >&2
  echo "connect once with the Claude Code extension installed so it unpacks, then re-run." >&2
  exit 1
fi

# Register the official Anthropic marketplace before installing. `marketplace add`
# is idempotent (no-op if already on disk), and `update` refreshes the cache so
# newly published plugins resolve. Without this, `plugin install <x>@claude-plugins-official`
# fails with "not found in marketplace 'claude-plugins-official'".
echo "Registering marketplace claude-plugins-official..."
"$CLAUDE_BIN" plugin marketplace add anthropics/claude-plugins-official
"$CLAUDE_BIN" plugin marketplace update claude-plugins-official

installed=$("$CLAUDE_BIN" plugin list 2>/dev/null || echo "")

for plugin in "${plugins[@]}"; do
  name="${plugin%%@*}"
  if echo "$installed" | grep -q "${name}"; then
    echo "Already installed: ${name}"
  else
    echo "Installing: ${name}"
    "$CLAUDE_BIN" plugin install "${plugin}" --scope user
  fi
done

echo "Claude Code plugin installation complete."
