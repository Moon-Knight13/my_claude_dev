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
# This script is CWD- and location-independent on purpose: it is installed at
# user scope on the box (see scripts/install-ctp-bridge.sh) and invoked as
# `ctp-bridge` from wherever the work happens — e.g. the range checkout, not this
# repo. It resolves its guard lib and config from fixed locations, never relative
# to a caller's directory.
#
# Usage (from anywhere):
#   ctp-bridge host deploy <box>
#   ctp-bridge host deploy-role <box>
# Exit: the real ctp exit status on a run; non-zero with a reason on any refusal.
set -euo pipefail

# self-contained logging (no repo-relative dependency, so it runs when installed)
host_info() { echo "  ++  $*"; }
host_note() { echo "  --  $*"; }
host_warn() { echo "  !!  $*" >&2; }

_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Find ctp-guard.sh across dev (repo) and installed (box) layouts. First hit wins.
_find_guard() {
    local c
    for c in "${CTP_GUARD_LIB:-}" \
             "$HOME/.local/lib/ctp-bridge/ctp-guard.sh" \
             "$_HERE/ctp-guard.sh" \
             "$_HERE/lib/ctp-guard.sh" \
             "$_HERE/../lib/ctp-bridge/ctp-guard.sh" \
             "$_HERE/../lib/ctp-guard.sh"; do
        [[ -n "$c" && -f "$c" ]] && { printf '%s' "$c"; return 0; }
    done
    return 1
}
_GUARD="$(_find_guard)" || { host_warn "cannot locate ctp-guard.sh"; exit 2; }
# shellcheck source=scripts/lib/ctp-guard.sh disable=SC1091
source "$_GUARD"

CONF="${CTP_BRIDGE_CONF:-$HOME/.ctp-bridge.conf}"
COUNT_LOG="${CTP_BRIDGE_LOG:-$HOME/.local/state/ctp-bridge/count.log}"

if ! ctp_load_config "$CONF"; then
    host_warn "no config at $CONF — copy .ctp-bridge.conf.example and set CTP_ALLOWED_TARGET"
    exit 2
fi

# --- classify (shared gates) -------------------------------------------------
verdict="$(ctp_classify "$@")" && rc=0 || rc=$?
read -r decision CLASS VERB TARGET <<<"$verdict"
if [[ "$rc" -ne 0 || "$decision" != "confirm" ]]; then
    # on refuse the verdict is "refuse <reason...>"; CLASS/VERB hold the reason
    host_warn "refused: ${CLASS} ${VERB} ${TARGET}"
    exit 3
fi

CONTAINER="$(ctp_container)"

# --- preconditions, by class -------------------------------------------------
# Container must be up for anything. A mutating run additionally needs an unlocked
# vault and no run already in flight; a read/inventory verb does not gate on those.
if ! docker inspect -f '{{.State.Running}}' "$CONTAINER" >/dev/null 2>&1; then
    host_warn "container '$CONTAINER' is not running — run 'make start' first"
    exit 4
fi
if [[ "$CLASS" == "mutating" ]]; then
    # Vault must be unlocked. Check EXISTENCE ONLY — never read the file's contents.
    if ! docker exec "$CONTAINER" test -e /var/tmp/vlt_pf 2>/dev/null; then
        host_warn "vault is locked (no /var/tmp/vlt_pf) — run 'make start' and complete first-run config"
        exit 4
    fi
    if docker exec "$CONTAINER" pgrep -f 'ansible-playbook|ctp ' >/dev/null 2>&1; then
        host_warn "a run is already in progress in '$CONTAINER' — refusing to start a second"
        exit 4
    fi
fi

# --- confirm gate ------------------------------------------------------------
# Every class is confirmed by a human, per owner policy. Two paths:
#   - agent path: the Bash tool has no TTY, so the human already confirmed at the
#     PreToolUse hook's `ask` prompt, and the hook left a single-use token bound to
#     THIS argv. Consume it here instead of prompting.
#   - human-shell path: a TTY is present, so prompt directly.
# ASSUME_YES is refused on either path — a present human is the whole point, and a
# token is written by the hook, never by ASSUME_YES.
_APPROVAL="$(ctp_approval_file)"
_consume_token() { # 0 iff a fresh token bound to "$*" exists; consumes it either way
    [[ -f "$_APPROVAL" ]] || return 1
    local exp argv now
    IFS=$'\t' read -r exp argv < "$_APPROVAL" 2>/dev/null
    rm -f "$_APPROVAL"                       # single-use: gone whether or not it matched
    now="$(date +%s 2>/dev/null || echo 0)"
    [[ -n "$exp" && "$now" -le "$exp" ]] || return 1
    [[ "$argv" == "$*" ]] || return 1
    return 0
}

if [[ "${ASSUME_YES:-0}" == "1" ]]; then
    host_warn "refusing: ASSUME_YES must not reach the ctp gate"
    exit 5
fi
if _consume_token "$@"; then
    host_note "approved at the hook prompt: ctp $*"
elif [[ -t 0 ]]; then
    printf '  ??  run: ctp %s   [y/N] ' "$*"
    read -r reply
    if [[ ! "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]; then
        host_note "skipped by operator"
        exit 6
    fi
else
    host_warn "refusing: non-interactive caller with no hook approval for 'ctp $*'"
    exit 5
fi

# --- run ---------------------------------------------------------------------
# The validated argv is forwarded as POSITIONAL PARAMS, never interpolated into a
# command string: `ctp "$@"` inside the login shell. Interpolation would re-open
# the quoting/env-prefix hole the classifier exists to close.
mkdir -p "$(dirname "$COUNT_LOG")"
_log_count() { # verb class outcome — verbs/outcomes only, never target or output
    printf '%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ 2>/dev/null || echo unknown)" "$1" "$2" "$3" >> "$COUNT_LOG"
}

# The exec is a non-interactive, non-login zsh: it never sources ~/.zshrc, which
# is what activates the Python venv that provides ansible-playbook. ctp itself is
# on PATH via autocomplete.zsh, but any verb that shells out to ansible dies at
# 127 without the venv. Reproduce ~/.zshrc's ESSENTIAL setup explicitly (not
# `zsh -i`, and not sourcing ~/.zshrc wholesale — that drags in interactive-only
# machinery): the env shim, the venv (glob-discovered, no site path hardcoded),
# then the ctp function. Each guarded so a box lacking one still runs. argv stays
# positional.
set +e
docker exec -i "$CONTAINER" zsh -c '
    _src() { [ -f "$1" ] && . "$1" >/dev/null 2>&1; }
    _src "$HOME/.local/bin/env"
    for _v in "$HOME"/*/.venv/bin/activate "$HOME"/.venv/bin/activate; do _src "$_v" && break; done
    _src "$HOME/autocomplete.zsh" || _src /home/builder/autocomplete.zsh
    ctp "$@"' _ "$@"
run_rc=$?
set -e
_log_count "$VERB" "$CLASS" "exit_$run_rc"
exit "$run_rc"
