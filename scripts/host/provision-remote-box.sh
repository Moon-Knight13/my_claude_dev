#!/usr/bin/env bash
# provision-remote-box.sh — one entry point to bring a fresh MCD Deploybox to
# the "golden" dev state after you have Remote-SSH'd onto it. Run FROM the repo
# checkout on the box (the local bootstrap clones it there). Needs sudo for the
# host-level killswitch.
#
#   sudo bash scripts/host/provision-remote-box.sh [--yes]
#
# Does, in order (each step idempotent, destructive bits confirm-gated):
#   1. VSCode server extensions: anthropic.claude-code, redhat.ansible
#   2. Ansible-lint settings + Docker prereqs (setup-ansible-lint.sh)
#   3. Caveman (install-caveman.sh) + Claude plugins (repo set + official)
#   4. Killswitch (setup-killswitch.sh)
#   5. SSH agent-forwarding sanity check (Catapult/ctp need the forwarded key)
#
# Reconnect-safe: a completion marker at /var/lib/claude-devbox/provisioned lets
# a re-run on the SAME box short-circuit ("already provisioned"). The marker
# lives on the box filesystem, so a re-imaged box has no marker and the full
# post-install setup runs again automatically. Force a re-run with --force.
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_REPO_ROOT="$(cd "$_SCRIPT_DIR/../.." && pwd)"
# shellcheck disable=SC1091
source "$_SCRIPT_DIR/lib/host-common.sh"

# Bump when the provisioning steps change so existing boxes re-provision.
PROVISION_VERSION=2
MARKER_DIR=/var/lib/claude-devbox
MARKER="$MARKER_DIR/provisioned"
FORCE=0
for a in "$@"; do
    case "$a" in
        --yes)   export ASSUME_YES=1 ;;
        --force) FORCE=1 ;;
        *) host_warn "unknown arg: $a" ;;
    esac
done

# Run a command as root whether or not we were invoked with sudo.
_sudo() { if [[ "$(id -u)" -eq 0 ]]; then "$@"; else sudo "$@"; fi; }

# Skip fast if this box is already provisioned at this version (unless --force).
if [[ "$FORCE" != "1" && -f "$MARKER" ]] && grep -q "^version=${PROVISION_VERSION}$" "$MARKER" 2>/dev/null; then
    host_step "Already provisioned — skipping"
    while IFS= read -r _line; do host_note "$_line"; done < "$MARKER"
    host_note "Re-run with --force to reprovision. (A re-imaged box clears this marker and runs fully.)"
    exit 0
fi

# --- locate the claude CLI (bundled with the VSCode extension if not on PATH) --
find_claude() {
    if command -v claude >/dev/null 2>&1; then command -v claude; return 0; fi
    local c="" cand
    for cand in "$HOME"/.vscode-server/extensions/anthropic.claude-code-*/resources/native-binary/claude; do
        [[ -x "$cand" ]] && c="$cand"
    done
    [[ -n "$c" ]] && { echo "$c"; return 0; }
    return 1
}

# --- locate a VSCode `code` shim (server remote-cli if not on PATH) -----------
find_code() {
    if command -v code >/dev/null 2>&1; then command -v code; return 0; fi
    local c="" cand
    for cand in "$HOME"/.vscode-server/bin/*/bin/remote-cli/code; do
        [[ -x "$cand" ]] && c="$cand"
    done
    [[ -n "$c" ]] && { echo "$c"; return 0; }
    return 1
}

# --- 1. VSCode server extensions ---------------------------------------------
host_step "[1/5] VSCode server extensions"
if CODE_BIN="$(find_code)"; then
    for ext in anthropic.claude-code redhat.ansible; do
        if "$CODE_BIN" --list-extensions 2>/dev/null | grep -qix "$ext"; then
            host_info "$ext already installed"
        elif "$CODE_BIN" --install-extension "$ext" >/dev/null 2>&1; then
            host_info "installed $ext"
        else
            host_warn "could not install $ext (install from the Extensions view)"
        fi
    done
else
    host_warn "no 'code' shim found — open the Extensions view and install: anthropic.claude-code, redhat.ansible"
fi

# --- 2. Ansible-lint + Docker ------------------------------------------------
host_step "[2/5] Ansible-lint + Docker"
bash "$_SCRIPT_DIR/setup-ansible-lint.sh" ${ASSUME_YES:+--yes} \
    || host_warn "setup-ansible-lint.sh reported an issue (continuing)"

# --- 3. Caveman + Claude plugins ---------------------------------------------
host_step "[3/5] Caveman + Claude plugins"
if [[ -f "$_REPO_ROOT/scripts/install-caveman.sh" ]]; then
    bash "$_REPO_ROOT/scripts/install-caveman.sh" || host_warn "install-caveman.sh failed (continuing)"
else
    host_note "scripts/install-caveman.sh not found — skipping caveman"
fi
if [[ -f "$_REPO_ROOT/scripts/install-claude-plugins.sh" ]]; then
    bash "$_REPO_ROOT/scripts/install-claude-plugins.sh" || host_warn "install-claude-plugins.sh failed (continuing)"
fi

if CLAUDE_BIN="$(find_claude)"; then
    _plugins="$("$CLAUDE_BIN" plugin list 2>/dev/null || echo "")"
    if ! echo "$_plugins" | grep -q "claude-plugins-official"; then
        if "$CLAUDE_BIN" plugin marketplace add claude-plugins-official >/dev/null 2>&1; then
            host_info "added marketplace claude-plugins-official"
        else
            host_note "marketplace add reported already-present / failed (continuing)"
        fi
    fi
    for p in skill-creator gitlab; do
        if echo "$_plugins" | grep -q "${p}@claude-plugins-official"; then
            host_info "${p}@claude-plugins-official already installed"
        elif "$CLAUDE_BIN" plugin install "${p}@claude-plugins-official" >/dev/null 2>&1; then
            host_info "installed ${p}@claude-plugins-official"
        else
            host_warn "could not install ${p}@claude-plugins-official"
        fi
    done
else
    host_warn "claude CLI not found — skipping official plugin install (connect once so the extension unpacks, then re-run)"
fi

# --- 4. Killswitch -----------------------------------------------------------
host_step "[4/5] Killswitch"
bash "$_SCRIPT_DIR/setup-killswitch.sh" ${ASSUME_YES:+--yes} \
    || host_warn "setup-killswitch.sh reported an issue"

# --- 5. SSH agent-forwarding sanity check ------------------------------------
# Downstream tools (Catapult/ctp) authenticate with the developer's FORWARDED
# SSH key. Verify the box permits forwarding and (best-effort) that a forwarded
# key is actually reachable. Read-only: we warn, we do NOT edit sshd here.
host_step "[5/5] SSH agent forwarding"
_aaf="$(_sudo sshd -T 2>/dev/null | awk '/^allowagentforwarding/ {print $2}')"
if [[ "$_aaf" == "no" ]]; then
    host_warn "sshd has 'AllowAgentForwarding no' — agent forwarding is BLOCKED."
    host_note "fix: add 'AllowAgentForwarding yes' to /etc/ssh/sshd_config.d/ and reload sshd."
elif [[ -n "$_aaf" ]]; then
    host_info "sshd AllowAgentForwarding=$_aaf"
else
    host_note "could not read sshd effective config (sshd -T) — skipping forwarding check"
fi
if [[ -n "${SSH_AUTH_SOCK:-}" ]] && ssh-add -l >/dev/null 2>&1; then
    host_info "forwarded SSH agent reachable ($(ssh-add -l 2>/dev/null | wc -l) key(s) visible)"
else
    host_note "no forwarded key visible in THIS shell. Verify from your interactive"
    host_note "VSCode session (useExecServer off + reconnected):  ssh-add -l"
fi

# Record completion so a reconnect can skip. Best-effort; never fail the run.
if _sudo mkdir -p "$MARKER_DIR" 2>/dev/null; then
    printf 'version=%s\nprovisioned_at=%s\nhost=%s\n' \
        "$PROVISION_VERSION" "$(date -Is)" "$(hostname)" \
        | _sudo tee "$MARKER" >/dev/null 2>&1 \
        && host_note "marker written: $MARKER (delete or use --force to reprovision)"
fi

host_step "Provisioning complete"
host_note "If the docker group was just added, REBOOT the box for it to take effect."
host_note "Killswitch audit log: sudo tail -f /var/log/claude-killswitch.log"
