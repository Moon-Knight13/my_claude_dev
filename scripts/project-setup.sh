#!/usr/bin/env bash
# Project-specific container setup — the project's extension point.
#
# The last entry in devcontainer.json's postStartCommand, so start-time setup
# has one home instead of growing devcontainer.json. Ships as a no-op: replace
# the body below with whatever the project needs at container start (extra
# runtime deps, symlinks, fetching a fixture, …).
#
# Two constraints worth respecting:
#
#   - Exit 0 unless the failure genuinely warrants a broken container. This
#     runs last in a `&&` chain, so a non-zero exit marks the whole
#     postStartCommand failed.
#   - Network egress is deny-by-default (see .devcontainer/init-firewall.sh).
#     registry.npmjs.org, pypi.org and files.pythonhosted.org are reachable;
#     anything else needs adding to the allowlist there first.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── SSH config for spoke connectivity ────────────────────────────────────────
# Generate ~/.ssh/config Host blocks from .env spoke variables so ProxyJump
# through host.docker.internal works without manual -o flags.
bash "$SCRIPT_DIR/setup-container-ssh.sh" || true

# ── Ghidra backend for rea-mcp (on-demand, idempotent) ─────────────────────
# Downloads ~1.5GB on first run, no-op when already installed.
# Skipped when SKIP_GHIDRA=1 to keep rebuild fast during dev.
if [[ "${SKIP_GHIDRA:-0}" != "1" ]]; then
  bash "$SCRIPT_DIR/install-ghidra-backend.sh" || true
fi

# ── Export .env into shell profile ───────────────────────────────────────────
# Claude Code MCP servers resolve ${VAR} from process environment.
# Source .env in shell rc so every terminal (and Claude Code launched from it)
# inherits the vars. set -a exports all sourced vars; set +a restores default.
_env_line='[ -f /workspace/.env ] && set -a && source /workspace/.env && set +a'
for _rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
    if [ -f "$_rc" ] && ! grep -qF 'source /workspace/.env' "$_rc"; then
        printf '\n# Load project env vars for MCP servers\n%s\n' "$_env_line" >> "$_rc"
    fi
done

# ── Derive MCP URL vars from *_HOST vars ────────────────────────────────────
# Firewall scripts use *_HOST (bare hostname/IP). MCP servers expect full URLs.
# Derive if not explicitly set in .env.
_derive_line='[ -n "${PROVIDENTIA_HOST:-}" ] && : "${PROVIDENTIA_URL:=https://$PROVIDENTIA_HOST}" && export PROVIDENTIA_URL; [ -n "${OUTLINE_HOST:-}" ] && : "${OUTLINE_API_URL:=https://$OUTLINE_HOST/api}" && export OUTLINE_API_URL; [ -n "${OUTLINE_TOKEN:-}" ] && : "${OUTLINE_API_KEY:=$OUTLINE_TOKEN}" && export OUTLINE_API_KEY; [ -n "${RANGE_GIT_HOST:-}" ] && : "${GITLAB_URL:=https://$RANGE_GIT_HOST}" && export GITLAB_URL'
for _rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
    if [ -f "$_rc" ] && ! grep -qF 'PROVIDENTIA_URL:=https' "$_rc"; then
        printf '\n# Derive MCP URL vars from *_HOST vars\n%s\n' "$_derive_line" >> "$_rc"
    fi
done

# ── Install local MCP server dependencies ───────────────────────────────────
# range-intel is a Python MCP server; install deps so Claude Code can start it.
if [ -f /workspace/mcp-servers/range-intel/pyproject.toml ]; then
    pip3 install --quiet --user --break-system-packages \
        -e /workspace/mcp-servers/range-intel 2>/dev/null || true
fi

# tuoni-mcp: GitHub-only package (shell-dot/tuoni-mcp). Install if not present.
if ! python3 -c "import tuoni_mcp" 2>/dev/null; then
    pip3 install --quiet --user --break-system-packages \
        "tuoni-mcp @ git+https://github.com/shell-dot/tuoni-mcp.git" 2>/dev/null || true
fi
