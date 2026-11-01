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
