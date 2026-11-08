#!/usr/bin/env bash
# switch-profile.sh — switch active environment profile.
#
# Usage:
#   scripts/switch-profile.sh <profile-name>   # switch to profile
#   scripts/switch-profile.sh --list            # list available profiles
#   scripts/switch-profile.sh --current         # show active profile
#
# Validates profile exists in ~/.claude-profiles/, checks expected MCPs
# and spoke connectivity, then exports ACTIVE_PROFILE.

set -euo pipefail

PROFILES_DIR="$HOME/.claude-profiles"

die() { echo "ERROR: $*" >&2; exit 1; }

list_profiles() {
    if [[ ! -d "$PROFILES_DIR" ]]; then
        echo "No profiles directory at $PROFILES_DIR"
        echo "Copy templates from profiles/ to get started."
        exit 0
    fi
    local current="${ACTIVE_PROFILE:-}"
    echo "Available profiles in $PROFILES_DIR:"
    for f in "$PROFILES_DIR"/*.env; do
        [[ -f "$f" ]] || continue
        local name
        name=$(basename "$f" .env)
        local modes
        modes=$(grep -oP '(?<=^PROFILE_MODES=).*' "$f" 2>/dev/null || echo "unknown")
        if [[ "$name" == "$current" ]]; then
            echo "  * $name  (active)  modes: $modes"
        else
            echo "    $name            modes: $modes"
        fi
    done
}

show_current() {
    if [[ -n "${ACTIVE_PROFILE:-}" ]]; then
        echo "Active profile: $ACTIVE_PROFILE"
        local pf="$PROFILES_DIR/${ACTIVE_PROFILE}.env"
        [[ -f "$pf" ]] && grep -oP '(?<=^PROFILE_MODES=).*' "$pf" 2>/dev/null | sed 's/^/Modes: /'
    else
        echo "No active profile (using base .env only)"
    fi
}

validate_profile() {
    local profile="$1"
    local profile_file="$PROFILES_DIR/${profile}.env"
    local warnings=0

    echo "Validating profile: $profile"

    # Check expected MCPs
    local mcps
    mcps=$(grep -oP '(?<=^PROFILE_MCPS=).*' "$profile_file" 2>/dev/null || echo "")
    if [[ -n "$mcps" ]]; then
        echo "Expected MCPs: $mcps"
    fi

    # Check spoke connectivity if spoke vars defined
    local spokes=0
    while IFS='=' read -r key val; do
        [[ "$key" =~ ^SPOKE_.*_HOST$ && -n "$val" ]] || continue
        spokes=1
        local host_label="${key%%_HOST}"
        if ssh -n -o ConnectTimeout=3 -o BatchMode=yes "$val" echo ok &>/dev/null; then
            echo "  OK: $host_label ($val)"
        else
            echo "  WARN: $host_label ($val) — unreachable"
            ((warnings++))
        fi
    done < <(grep -E '^SPOKE_.*_HOST=' "$profile_file" 2>/dev/null || true)

    if [[ $spokes -eq 0 ]]; then
        echo "  No spokes configured (expected for this profile)"
    fi

    return $warnings
}

# ── Main ─────────────────────────────────────────────────────────────────────

case "${1:-}" in
    --list|-l)  list_profiles; exit 0 ;;
    --current)  show_current; exit 0 ;;
    --help|-h)
        echo "Usage: $0 <profile-name> | --list | --current"
        exit 0
        ;;
    "")
        die "Profile name required. Use --list to see available profiles."
        ;;
esac

profile="$1"
profile_file="$PROFILES_DIR/${profile}.env"

[[ -d "$PROFILES_DIR" ]] || die "No profiles directory at $PROFILES_DIR. Copy templates from profiles/ first."
[[ -f "$profile_file" ]] || die "Profile '$profile' not found at $profile_file. Use --list to see available."

# Validate
validate_profile "$profile" || true

# Export
export ACTIVE_PROFILE="$profile"
echo ""
echo "ACTIVE_PROFILE=$profile"
echo ""
echo "To persist across sessions, add to your shell rc:"
echo "  export ACTIVE_PROFILE=$profile"
