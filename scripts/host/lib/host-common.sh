#!/usr/bin/env bash
# Shared helpers for the scripts/host/* remote-box provisioning scripts.
# Sourced, not executed. Provides confirm(), logging, and a sudo guard so the
# individual installers stay small and behave consistently.
#
# Convention: destructive steps call `confirm "<what>"` — it returns 0 to
# proceed, 1 to skip. Passing --yes (exported as ASSUME_YES=1) auto-confirms so
# the orchestrator can run unattended.

# --- output helpers ----------------------------------------------------------
host_info()  { echo "  ++  $*"; }
host_note()  { echo "  --  $*"; }
host_warn()  { echo "  !!  $*" >&2; }
host_step()  { echo ""; echo ">> $*"; }

# --- golden-state failure tracking -------------------------------------------
# host_warn stays advisory. host_fail is for a step that was supposed to reach
# the golden state and did not: it warns AND records, so the orchestrator can
# report honestly and exit non-zero instead of printing "complete" over a
# half-provisioned box.
# shellcheck disable=SC2034  # consumed by scripts that source this
HOST_FAILURES=()
host_fail() { HOST_FAILURES+=("$*"); host_warn "$*"; }

# --- confirm gate ------------------------------------------------------------
# confirm "<action description>" -> 0 proceed / 1 skip.
# Auto-yes when ASSUME_YES=1 (set by --yes). Non-interactive stdin also auto-yes
# with a loud note, so piped runs don't hang.
confirm() {
    local prompt="$1"
    if [[ "${ASSUME_YES:-0}" == "1" ]]; then
        host_info "auto-confirm (--yes): $prompt"
        return 0
    fi
    if [[ ! -t 0 ]]; then
        host_warn "non-interactive stdin; skipping (pass --yes to allow): $prompt"
        return 1
    fi
    local reply
    printf '  ??  %s [y/N] ' "$prompt"
    read -r reply
    [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# --- target user / home ------------------------------------------------------
# These scripts are invoked with sudo because ONE step (the killswitch) needs
# root. Everything else — VSCode extensions, the Machine settings.json, caveman,
# the Claude plugin set, git config, the docker group — is user-level work, and
# under sudo $HOME is /root. Using it silently provisioned root instead of the
# developer: extensions "not found" because they were looked for in
# /root/.vscode-server, settings merged into a file no VSCode session reads,
# plugins installed into /root/.claude, and a confirm prompt offering to add
# *root* to the docker group.
#
# CLAUDE_TARGET_USER / CLAUDE_TARGET_HOME are who the work is FOR, whether or not
# the script was elevated. run_as_target runs a command as them with the right
# HOME, and is a no-op passthrough when we are already that user.
CLAUDE_TARGET_USER="${CLAUDE_TARGET_USER:-${SUDO_USER:-$(id -un)}}"
if [[ -z "${CLAUDE_TARGET_HOME:-}" ]]; then
    CLAUDE_TARGET_HOME="$(getent passwd "$CLAUDE_TARGET_USER" 2>/dev/null | cut -d: -f6)"
    [[ -z "$CLAUDE_TARGET_HOME" ]] && CLAUDE_TARGET_HOME="$HOME"
fi
export CLAUDE_TARGET_USER CLAUDE_TARGET_HOME

run_as_target() { # run_as_target <cmd> [args...]
    if [[ "$(id -un)" == "$CLAUDE_TARGET_USER" ]]; then
        HOME="$CLAUDE_TARGET_HOME" "$@"
    elif [[ "$(id -u)" -eq 0 ]]; then
        sudo -u "$CLAUDE_TARGET_USER" \
            env HOME="$CLAUDE_TARGET_HOME" \
                CLAUDE_TARGET_USER="$CLAUDE_TARGET_USER" \
                CLAUDE_TARGET_HOME="$CLAUDE_TARGET_HOME" \
                ASSUME_YES="${ASSUME_YES:-0}" "$@"
    else
        # Not the target and not root: cannot switch. Run in place and say so.
        host_warn "running as $(id -un), not ${CLAUDE_TARGET_USER}: $1"
        "$@"
    fi
}

# --- prompt helper -----------------------------------------------------------
# host_ask VAR "<prompt>" "<default>" — reads into VAR, honouring a value already
# set in the environment. Never hangs: with --yes or a non-interactive stdin it
# takes the default and says so, so an unattended run behaves predictably.
host_ask() {
    local __var="$1" __prompt="$2" __default="${3:-}" __reply
    if [[ -n "${!__var:-}" ]]; then return 0; fi
    if [[ "${ASSUME_YES:-0}" == "1" || ! -t 0 ]]; then
        printf -v "$__var" '%s' "$__default"
        [[ -n "$__default" ]] && host_note "using default for ${__prompt}: ${__default}"
        return 0
    fi
    if [[ -n "$__default" ]]; then
        printf '  ??  %s [%s]: ' "$__prompt" "$__default"
    else
        printf '  ??  %s: ' "$__prompt"
    fi
    read -r __reply
    printf -v "$__var" '%s' "${__reply:-$__default}"
}

# --- sudo guard --------------------------------------------------------------
# Ensure we can elevate; exit cleanly with guidance if not. Sets $SUDO ("" or
# "sudo") for callers to prefix privileged commands.
# shellcheck disable=SC2034  # SUDO is consumed by the scripts that source this
require_sudo() {
    if [[ "$(id -u)" -eq 0 ]]; then
        SUDO=""
        return 0
    fi
    if command -v sudo >/dev/null 2>&1 && sudo -v 2>/dev/null; then
        SUDO="sudo"
        return 0
    fi
    host_warn "this step needs root (sudo). Re-run as root or install sudo."
    return 1
}
