#!/usr/bin/env bash
# Export engagement report from wiki structured pages.
#
# Collects wiki pages linked to an engagement, compiles through template,
# outputs HTML report. DOCX/PDF when pandoc is available.
#
# Usage:
#   bash scripts/export-report.sh <engagement-name> [--format html|docx|all]
#   bash scripts/export-report.sh --list
#
# Reads from: $OBSIDIAN_VAULT_CONTAINER_PATH (default: /home/node/vault)
# Writes to:  reports/<engagement>/<date>-report.<ext>
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAULT="${OBSIDIAN_VAULT_CONTAINER_PATH:-/home/node/vault}"
REPORTS_DIR="${REPORTS_DIR:-$HERE/../reports}"
FORMAT="${2:-html}"
[[ "$FORMAT" == "--format" ]] && FORMAT="${3:-html}"

# ── List engagements ──────────────────────────────────────────────────────
if [[ "${1:-}" == "--list" ]]; then
    echo "Engagements in vault:"
    if [[ -d "$VAULT/wiki/engagements" ]]; then
        for f in "$VAULT/wiki/engagements/"*.md; do
            [[ -f "$f" ]] || continue
            name="$(basename "$f" .md)"
            status=$(grep -m1 '^status:' "$f" 2>/dev/null | sed 's/status:[[:space:]]*//' || echo "unknown")
            echo "  ${name} (${status})"
        done
    else
        echo "  (none — wiki/engagements/ not found)"
    fi
    exit 0
fi

if [[ -z "${1:-}" ]]; then
    echo "Usage: export-report.sh <engagement-name> [--format html|docx|all]"
    echo "       export-report.sh --list"
    exit 1
fi

ENGAGEMENT="$1"

# ── Compile report ────────────────────────────────────────────────────────
node "$HERE/lib/compile-report.mjs" \
    --vault "$VAULT" \
    --engagement "$ENGAGEMENT" \
    --format "$FORMAT" \
    --output "$REPORTS_DIR"
