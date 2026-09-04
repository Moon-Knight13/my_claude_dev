#!/usr/bin/env bash
# install-ctp-bridge.sh — install the ctp tool bridge at USER scope on the box.
#
# Why user scope: the thing the gate protects (ctp reaching a live range) is
# box-wide, and the work does not happen in this repo — it happens in the range
# checkout (e.g. ~/catapult/inventories/dcm). A PreToolUse hook registered only
# in this repo's .claude/ would not load for a Claude session started there. So
# the hook, wrapper, guard and config are installed into ~/.claude and ~/.local,
# where every session on the account sees them regardless of CWD — and nothing is
# written into the range checkout (a git tree you push).
#
# Idempotent. Preserves an existing ~/.ctp-bridge.conf (your target box) and an
# existing ~/.claude/settings.json (merges, never clobbers).
#
# Usage:  bash scripts/install-ctp-bridge.sh
# Installs for the invoking user ($HOME). The provisioner calls it through
# run_as_target so it lands in the developer's home, not root's.
set -euo pipefail

_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_REPO="$(cd "$_HERE/.." && pwd)"
# shellcheck source=scripts/host/lib/host-common.sh disable=SC1091
source "$_HERE/host/lib/host-common.sh"

SRC_WRAPPER="$_HERE/ctp-bridge.sh"
SRC_GUARD="$_HERE/lib/ctp-guard.sh"
SRC_SEG="$_HERE/lib/cmd-segment.sh"
SRC_SAFETY="$_HERE/lib/safety-guard.sh"
SRC_HOOK="$_REPO/.claude/hooks/pretooluse-ctp.sh"
SRC_CONF_EXAMPLE="$_REPO/.ctp-bridge.conf.example"
SRC_SAFETY_CONF="$_REPO/.safety-guard.conf.example"

LIB_DIR="$HOME/.local/lib/ctp-bridge"
BIN="$HOME/.local/bin/ctp-bridge"
HOOK_DIR="$HOME/.claude/hooks"
HOOK="$HOOK_DIR/pretooluse-ctp.sh"
CONF="$HOME/.ctp-bridge.conf"
SAFETY_CONF="$HOME/.config/safety-guard.conf"
STATE_DIR="$HOME/.local/state/ctp-bridge"
SETTINGS="$HOME/.claude/settings.json"

host_step "Installing ctp tool bridge for $(id -un) (home: $HOME)"

for f in "$SRC_WRAPPER" "$SRC_GUARD" "$SRC_SEG" "$SRC_SAFETY" "$SRC_HOOK" "$SRC_CONF_EXAMPLE" "$SRC_SAFETY_CONF"; do
    [[ -f "$f" ]] || host_fail "missing source: $f"
done
(( ${#HOST_FAILURES[@]} == 0 )) || { host_warn "cannot install; source files missing"; exit 1; }

if ! command -v jq >/dev/null 2>&1; then
    host_fail "jq is required (the hook needs it to parse tool calls) — install jq and re-run"
    exit 1
fi

# --- 1. copy scripts to fixed locations --------------------------------------
mkdir -p "$LIB_DIR" "$(dirname "$BIN")" "$HOOK_DIR" "$STATE_DIR"
install -m 0644 "$SRC_GUARD" "$LIB_DIR/ctp-guard.sh"
install -m 0644 "$SRC_SEG" "$LIB_DIR/cmd-segment.sh"
install -m 0644 "$SRC_SAFETY" "$LIB_DIR/safety-guard.sh"
install -m 0755 "$SRC_WRAPPER" "$BIN"
install -m 0755 "$SRC_HOOK" "$HOOK"
host_info "wrapper -> $BIN"
host_info "guard   -> $LIB_DIR/ctp-guard.sh"
host_info "segment -> $LIB_DIR/cmd-segment.sh"
host_info "safety  -> $LIB_DIR/safety-guard.sh"
host_info "hook    -> $HOOK"

# --- 2. seed config (never overwrite an existing target) ---------------------
if [[ -f "$CONF" ]]; then
    host_note "kept existing $CONF (your settings are preserved)"
    # Migrate: a config seeded before a key existed would silently lack it, and a
    # missing required key (e.g. CTP_ALLOWED_TEAM) reads as "configured" while the
    # gate is actually unset. Append any example key the config does not have, at
    # its example (fail-closed) value, so it is visible to fill in.
    _added=0
    while IFS= read -r _k; do
        if ! grep -q "^${_k}=" "$CONF"; then
            grep "^${_k}=" "$SRC_CONF_EXAMPLE" >> "$CONF"
            host_info "added missing key ${_k} to $CONF (set its value)"
            _added=1
        fi
    done < <(grep -oE '^[A-Z_]+=' "$SRC_CONF_EXAMPLE" | sed 's/=$//')
    [[ "$_added" == 0 ]] && host_note "config has all current keys"
else
    install -m 0600 "$SRC_CONF_EXAMPLE" "$CONF"
    host_info "seeded $CONF — set CTP_ALLOWED_TARGET and CTP_ALLOWED_TEAM before deploying"
    host_note "until they are set, every deploy is refused (safe default)."
fi

# --- 2b. seed the destructive-action gate config (never overwrite) -----------
mkdir -p "$(dirname "$SAFETY_CONF")"
if [[ -f "$SAFETY_CONF" ]]; then
    host_note "kept existing $SAFETY_CONF"
else
    install -m 0644 "$SRC_SAFETY_CONF" "$SAFETY_CONF"
    host_info "seeded $SAFETY_CONF (destructive-action gate; empty allow-list = confirm everything)"
fi

# --- 3. merge the PreToolUse hook into user settings (no clobber) ------------
[[ -f "$SETTINGS" ]] || echo '{}' > "$SETTINGS"
if ! jq -e . "$SETTINGS" >/dev/null 2>&1; then
    host_fail "$SETTINGS is not valid JSON; refusing to touch it. Fix it and re-run."
    exit 1
fi
# Upsert our entry: if one with our command exists, refresh its matcher (so an
# older install's matcher is upgraded); otherwise append. Other hooks untouched.
HOOK_ABS="$HOOK" MATCHER="Bash|Read|Write|Edit" jq '
  .hooks //= {} |
  .hooks.PreToolUse //= [] |
  if any(.hooks.PreToolUse[]?; (.hooks[]?.command) == env.HOOK_ABS)
  then .hooks.PreToolUse |= map(
    if (.hooks[]?.command) == env.HOOK_ABS then .matcher = env.MATCHER else . end)
  else .hooks.PreToolUse += [{
    "matcher": env.MATCHER,
    "hooks": [{"type": "command", "command": env.HOOK_ABS}]
  }] end
' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
host_info "registered PreToolUse hook in $SETTINGS (absolute path, no clobber)"

# --- 4. PATH reminder --------------------------------------------------------
case ":$PATH:" in
    *":$HOME/.local/bin:"*) host_info "$HOME/.local/bin is on PATH — run 'ctp-bridge ...' from anywhere" ;;
    *) host_note "add $HOME/.local/bin to PATH to run 'ctp-bridge' by name (or use the full path)" ;;
esac

host_step "ctp bridge installed"
host_note "From the range checkout: ctp-bridge host deploy <box>   (hook prompts; wrapper runs)"
host_note "Never write ctp-bridge files into the range checkout — it is a repo you push."
