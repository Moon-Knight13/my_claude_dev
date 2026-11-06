#!/usr/bin/env bash
# t3-code-setup.sh — Repeatable T3 Code setup for a fresh host.
#
# Usage:
#   ./t3-code-setup.sh                    # stable channel
#   ./t3-code-setup.sh --channel nightly  # nightly channel
#   T3_PROJECTS="/path/a /path/b" ./t3-code-setup.sh
#
# Environment variables:
#   T3_CHANNEL        — stable | nightly | preview (default: stable)
#   T3_PROJECTS       — space-separated list of project directories to register
#   T3_CONNECT        — true | false (default: true) — enable T3 Connect
#   T3_LAN            — true | false (default: false) — enable LAN access
#   T3_OOM_PROTECT    — true | false (default: true) — enable OOM protection (needs sudo)
#   T3_BROWSER_SETUP  — true | false (default: true) — set up headless Chrome on Linux
#   T3_IDLE_COMPACTION — onReturn | never (default: onReturn)

set -euo pipefail

# ─── Parse arguments ──────────────────────────────────────────────────────
CHANNEL="${T3_CHANNEL:-stable}"
PROJECTS="${T3_PROJECTS:-}"
CONNECT="${T3_CONNECT:-true}"
LAN="${T3_LAN:-false}"
OOM_PROTECT="${T3_OOM_PROTECT:-true}"
BROWSER_SETUP="${T3_BROWSER_SETUP:-true}"
IDLE_COMPACTION="${T3_IDLE_COMPACTION:-onReturn}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --channel) CHANNEL="$2"; shift 2 ;;
    --connect) CONNECT=true; shift ;;
    --no-connect) CONNECT=false; shift ;;
    --lan) LAN=true; shift ;;
    --no-lan) LAN=false; shift ;;
    --no-oom-protect) OOM_PROTECT=false; shift ;;
    --no-browser-setup) BROWSER_SETUP=false; shift ;;
    --help|-h)
      sed -n '2,/^$/{ s/^# //; s/^#//; p; }' "$0"
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

log() { echo "[t3-setup] $*"; }

# ─── Step 1: Install T3 Code ─────────────────────────────────────────────
log "Installing T3 Code (channel: $CHANNEL)..."

if command -v t3 &>/dev/null; then
  CURRENT_VERSION=$(t3 --version 2>/dev/null || echo "unknown")
  log "T3 already installed: $CURRENT_VERSION"
  log "Updating to latest on $CHANNEL channel..."
  t3 update --channel "$CHANNEL" --yes 2>&1 || true
else
  log "T3 not found. Downloading installer..."
  # The canonical install method — check https://t3.codes for current URL
  # This assumes the installer script is available:
  if command -v curl &>/dev/null; then
    curl -fsSL https://t3.codes/install | bash -s -- --channel "$CHANNEL"
  elif command -v wget &>/dev/null; then
    wget -qO- https://t3.codes/install | bash -s -- --channel "$CHANNEL"
  else
    log "ERROR: Neither curl nor wget found. Install T3 manually."
    exit 1
  fi
fi

# Verify installation
if ! command -v t3 &>/dev/null; then
  log "ERROR: t3 binary not found after install."
  log "You may need to add it to PATH or restart your shell."
  exit 1
fi

log "T3 version: $(t3 --version 2>/dev/null)"

# ─── Step 2: Set up headless browser (Linux only) ────────────────────────
if [[ "$BROWSER_SETUP" == "true" ]] && [[ "$(uname -s)" == "Linux" ]]; then
  log "Setting up headless browser for preview tabs..."
  t3 browser setup 2>&1 || log "WARN: Browser setup failed. Preview tabs may not work."
fi

# ─── Step 3: Start background service ────────────────────────────────────
log "Installing and starting background service..."

ACCESS_FLAGS=""
if [[ "$CONNECT" == "true" ]]; then
  ACCESS_FLAGS="$ACCESS_FLAGS --connect"
else
  ACCESS_FLAGS="$ACCESS_FLAGS --no-connect"
fi

if [[ "$LAN" == "true" ]]; then
  ACCESS_FLAGS="$ACCESS_FLAGS --lan"
else
  ACCESS_FLAGS="$ACCESS_FLAGS --no-lan"
fi

# shellcheck disable=SC2086
t3 up --yes $ACCESS_FLAGS 2>&1

# ─── Step 4: OOM protection (Linux systemd) ──────────────────────────────
if [[ "$OOM_PROTECT" == "true" ]] && [[ "$(uname -s)" == "Linux" ]]; then
  if systemctl --user is-active t3code.service &>/dev/null; then
    log "Enabling OOM protection (may ask for sudo)..."
    t3 service protect 2>&1 || log "WARN: OOM protection failed. Run 't3 service protect' manually."
  fi
fi

# ─── Step 5: Register projects ───────────────────────────────────────────
if [[ -n "$PROJECTS" ]]; then
  log "Registering projects..."
  for project_dir in $PROJECTS; do
    if [[ -d "$project_dir" ]]; then
      project_name=$(basename "$project_dir")
      log "  Adding: $project_name ($project_dir)"
      t3 project add "$project_dir" --title "$project_name" 2>&1 || \
        log "  WARN: Failed to add $project_dir (may already be registered)"
    else
      log "  SKIP: $project_dir does not exist"
    fi
  done
fi

# ─── Step 6: Set default preferences ─────────────────────────────────────
log "Setting default preferences..."

SETTINGS_FILE="$HOME/.t3/userdata/settings.json"

if [[ -f "$SETTINGS_FILE" ]]; then
  # Update idle compaction preference via jq if available
  if command -v jq &>/dev/null; then
    jq --arg ic "$IDLE_COMPACTION" '.idleCompaction = $ic' "$SETTINGS_FILE" > "${SETTINGS_FILE}.tmp"
    mv "${SETTINGS_FILE}.tmp" "$SETTINGS_FILE"
    log "Set idleCompaction=$IDLE_COMPACTION"
  else
    log "WARN: jq not found. Manual settings edit needed for preferences."
  fi
else
  log "WARN: Settings file not found at $SETTINGS_FILE"
fi

# ─── Step 7: Verify ──────────────────────────────────────────────────────
log ""
log "=== Setup complete ==="
t3 status 2>&1
log ""
log "Next steps:"
log "  - Open T3 Code: t3"
log "  - Register more projects: t3 project add /path/to/repo"
log "  - Pair another device: t3 pair"
log "  - Link another environment: t3 environment link <url>"
log "  - Run diagnostics: t3 doctor"
