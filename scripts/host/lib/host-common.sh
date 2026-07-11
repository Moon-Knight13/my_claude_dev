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
