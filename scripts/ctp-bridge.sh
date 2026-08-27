#!/usr/bin/env bash
# ctp-bridge.sh — the ONLY supported path to run a build-tooling (ctp) command.
#
# Purpose: let a developer (and, through the PreToolUse hook, Claude) run the two
# deploy verbs against one configured box, with every gate in code. Safety is not
# pattern-matching over a command string — it is classification of the parsed
# argv in scripts/lib/ctp-guard.sh, shared with the hook so the two cannot drift.
#
# Owner policy (docs/PROJECT.md): every verb is confirmed manually until
# protections earn an exemption. This wrapper ships confirm-on-everything with no
# allow-list to relax; an empty allow-list is the finished state, not a stub.
#
# Usage:
#   scripts/ctp-bridge.sh host deploy <box>
#   scripts/ctp-bridge.sh host deploy-role <box>
# Exit: the real ctp exit status on a run; non-zero with a reason on any refusal.
set -euo pipefail

_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ROOT="$(cd "$_HERE/.." && pwd)"
# shellcheck source=scripts/host/lib/host-common.sh disable=SC1091
source "$_HERE/host/lib/host-common.sh"
# shellcheck source=scripts/lib/ctp-guard.sh disable=SC1091
source "$_HERE/lib/ctp-guard.sh"

CONF="${CTP_BRIDGE_CONF:-$_ROOT/.ctp-bridge.conf}"
COUNT_LOG="${CTP_BRIDGE_LOG:-$_ROOT/.ai/ctp-bridge.log}"

if ! ctp_load_config "$CONF"; then
    host_warn "no config at $CONF — copy .ctp-bridge.conf.example and set CTP_ALLOWED_TARGET"
    exit 2
fi

# --- classify (shared gates) -------------------------------------------------
verdict="$(ctp_classify "$@")" && rc=0 || rc=$?
read -r decision reason_or_verb target_or_rest <<<"$verdict"
if [[ "$rc" -ne 0 || "$decision" != "confirm" ]]; then
    host_warn "refused: ${reason_or_verb} ${target_or_rest}"
    exit 3
fi
VERB="$reason_or_verb"
TARGET="$target_or_rest"

CONTAINER="$(ctp_container)"

# --- preconditions before any mutating run -----------------------------------
if ! docker inspect -f '{{.State.Running}}' "$CONTAINER" >/dev/null 2>&1; then
    host_warn "container '$CONTAINER' is not running — run 'make start' first"
    exit 4
fi
# Vault must be unlocked. Check EXISTENCE ONLY — never read the file's contents.
if ! docker exec "$CONTAINER" test -e /var/tmp/vlt_pf 2>/dev/null; then
    host_warn "vault is locked (no /var/tmp/vlt_pf) — run 'make start' and complete first-run config"
    exit 4
fi
# Busy: an ansible/ctp run already in flight in the container.
if docker exec "$CONTAINER" pgrep -f 'ansible-playbook|ctp ' >/dev/null 2>&1; then
    host_warn "a run is already in progress in '$CONTAINER' — refusing to start a second"
    exit 4
fi

# --- confirm gate (human-shell path) -----------------------------------------
# This wrapper's OWN gate. Unlike host-common's confirm(), it never auto-yeses on
# non-interactive stdin — a present human is the whole point. The agent path does
# not reach here unconfirmed: the PreToolUse hook prompts the user first.
if [[ "${ASSUME_YES:-0}" == "1" ]]; then
    host_warn "refusing: ASSUME_YES must not reach the ctp gate"
    exit 5
fi
if [[ ! -t 0 ]]; then
    host_warn "refusing: non-interactive caller cannot confirm 'ctp host $VERB $TARGET'"
    exit 5
fi
printf '  ??  run: ctp host %s %s   [y/N] ' "$VERB" "$TARGET"
read -r reply
if [[ ! "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]; then
    host_note "skipped by operator"
    exit 6
fi

# --- run ---------------------------------------------------------------------
# argv passed as POSITIONAL PARAMS, never interpolated into a command string:
# `ctp "$@"` inside the login shell. Interpolation would re-open the very
# quoting/env-prefix hole the classifier exists to close.
mkdir -p "$(dirname "$COUNT_LOG")"
_log_count() { # verb outcome — verbs + outcomes only, never target or output
    printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ 2>/dev/null || echo unknown)" "$1" "$2" >> "$COUNT_LOG"
}

set +e
docker exec -i "$CONTAINER" zsh -c \
    'source /home/builder/autocomplete.zsh >/dev/null 2>&1; ctp "$@"' _ host "$VERB" "$TARGET"
run_rc=$?
set -e
_log_count "host_$VERB" "exit_$run_rc"
exit "$run_rc"
