#!/usr/bin/env bash
# mcp-wrapper.sh — source .env vars then exec MCP server command.
# Used by settings.json so MCP servers get vars from .env even when
# container environment lacks them (Claude restart without rebuild).
#
# Usage: mcp-wrapper.sh <command> [args...]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/load-env.sh
source "$SCRIPT_DIR/lib/load-env.sh"

exec "$@"
