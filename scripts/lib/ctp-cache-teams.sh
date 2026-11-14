#!/usr/bin/env bash
# ctp-cache-teams.sh — populate per-team host list cache files.
#
# The team cache is the authoritative list of hostnames the ctp-bridge guard
# permits for each team. The guard refuses a deploy unless the target appears
# in at least one allowed team's cache file, so populating the cache is a
# required step before any deploy.
#
# Usage:
#   ctp-cache-teams.sh <team> <host1> [host2 ...]   — set from args
#   echo -e "host1\nhost2" | ctp-cache-teams.sh <team>  — set from stdin
#   ctp-cache-teams.sh --list                         — show cached teams
#   ctp-cache-teams.sh --show <team>                  — show hosts in a team
#
# Writes one hostname per line to:
#   ~/.cache/ctp-bridge/team-hosts-<team>.txt
#
# The pre-engagement-cache skill and the range-intel MCP provide the host lists;
# this script is the writer, not the source.
set -euo pipefail

# Allow override for testing
CACHE_DIR="${CTP_TEAMS_CACHE_DIR:-$HOME/.cache/ctp-bridge}"

_usage() {
    echo "Usage: ctp-cache-teams.sh <team> <host1> [host2 ...]"
    echo "       echo hosts | ctp-cache-teams.sh <team>"
    echo "       ctp-cache-teams.sh --list"
    echo "       ctp-cache-teams.sh --show <team>"
    exit 1
}

_list() {
    if [[ ! -d "$CACHE_DIR" ]]; then
        echo "no team cache directory at $CACHE_DIR"
        exit 0
    fi
    for f in "$CACHE_DIR"/team-hosts-*.txt; do
        [[ -f "$f" ]] || continue
        local team="${f##*/team-hosts-}"
        team="${team%.txt}"
        local count
        count="$(wc -l < "$f")"
        printf '%s  (%d hosts)\n' "$team" "$count"
    done
}

_show() {
    local team="$1"
    local cache_file="$CACHE_DIR/team-hosts-${team}.txt"
    if [[ ! -f "$cache_file" ]]; then
        echo "no cache for team '$team' — run: ctp-cache-teams.sh $team <hosts...>"
        exit 1
    fi
    cat "$cache_file"
}

case "${1:-}" in
    --list) _list; exit 0 ;;
    --show)
        [[ -n "${2:-}" ]] || _usage
        _show "$2"; exit 0 ;;
    --help|-h|"") _usage ;;
esac

TEAM="$1"; shift

# validate team name (alphanumeric + hyphens only)
if [[ ! "$TEAM" =~ ^[a-zA-Z0-9][-a-zA-Z0-9]*$ ]]; then
    echo "error: invalid team name '$TEAM' (alphanumeric and hyphens only)" >&2
    exit 1
fi

mkdir -p "$CACHE_DIR"
CACHE_FILE="$CACHE_DIR/team-hosts-${TEAM}.txt"

if [[ $# -gt 0 ]]; then
    # hosts from arguments
    printf '%s\n' "$@" | sort -u > "$CACHE_FILE"
elif [[ ! -t 0 ]]; then
    # hosts from stdin
    sort -u > "$CACHE_FILE"
else
    echo "error: no hosts provided (pass as args or pipe to stdin)" >&2
    exit 1
fi

COUNT="$(wc -l < "$CACHE_FILE")"
echo "cached $COUNT host(s) for team '$TEAM' -> $CACHE_FILE"
