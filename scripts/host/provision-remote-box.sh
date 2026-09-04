#!/usr/bin/env bash
# provision-remote-box.sh — one entry point to bring a fresh remote dev box to
# the "golden" dev state after you have Remote-SSH'd onto it. Run FROM the repo
# checkout on the box (the local bootstrap clones it there). Needs sudo for the
# host-level killswitch.
#
#   sudo bash scripts/host/provision-remote-box.sh [--yes] [--force]
#       [--verify-cmd '<command that proves the build tooling works>']
#       [--git-identity-global]
#
# --verify-cmd is how step 6 stops this script declaring a golden state it never
# checked. Site-specific, so it is passed in rather than baked in (this repo is
# public). Example shape: a command that lists the tooling's inventory. Without
# it the step reports "not verified" and the marker records that — it does not
# quietly claim success.
#
# Does, in order (each step idempotent, destructive bits confirm-gated):
#   1. VSCode server extensions (anthropic.claude-code, redhat.ansible) and a
#      `claude` wrapper on the developer's PATH — the CLI ships inside the
#      extension and is not otherwise reachable from a shell
#   2. Ansible-lint settings + Docker prereqs (setup-ansible-lint.sh)
#   3. Caveman (install-caveman.sh) + Claude plugins (repo set + official)
#   4. Killswitch (setup-killswitch.sh)
#   5. Git identity for this box (prompted; never overwrites, never global by
#      default — see the shared-account note in the step itself)
#   6. Build-tooling verification (only when you supply the command; the
#      template cannot know it, and this repository is public)
#   7. SSH agent-forwarding sanity check (downstream tooling needs the forwarded key)
#   8. ctp tool bridge + destructive-action + destructive-git gates at user scope (gates
#      present in every session, including those started from the range checkout;
#      the safety gate confirms destructive commands like rm -rf / dropdb / destroy)
#   9. Commit guard installed at user scope (warn-only PII/secret scan on every
#      commit, in any repo incl. the range checkout; never blocks a commit)
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
PROVISION_VERSION=8
# Overridable so scripts/tests/test-provision.sh can assert marker behaviour
# without writing under /var on the machine running the tests.
MARKER_DIR="${DEVBOX_MARKER_DIR:-/var/lib/claude-devbox}"
MARKER="$MARKER_DIR/provisioned"
FORCE=0
VERIFY_CMD="${DEVBOX_TOOL_VERIFY_CMD:-}"
GIT_IDENTITY_GLOBAL=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes)   export ASSUME_YES=1 ;;
        --force) FORCE=1 ;;
        --verify-cmd) VERIFY_CMD="${2:-}"; shift ;;
        --verify-cmd=*) VERIFY_CMD="${1#*=}" ;;
        --git-identity-global) GIT_IDENTITY_GLOBAL=1 ;;
        *) host_warn "unknown arg: $1" ;;
    esac
    shift
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
# Both searches use CLAUDE_TARGET_HOME, not $HOME: under sudo the latter is
# /root, where a developer's VSCode server has never been installed. That is why
# provisioning reported "no 'code' shim found" on a box that plainly had one.
find_claude() {
    if command -v claude >/dev/null 2>&1; then command -v claude; return 0; fi
    local c="" cand
    for cand in "$CLAUDE_TARGET_HOME"/.vscode-server/extensions/anthropic.claude-code-*/resources/native-binary/claude; do
        [[ -x "$cand" ]] && c="$cand"
    done
    [[ -n "$c" ]] && { echo "$c"; return 0; }
    return 1
}

# --- locate a VSCode `code` shim (server remote-cli if not on PATH) -----------
find_code() {
    if command -v code >/dev/null 2>&1; then command -v code; return 0; fi
    local c="" cand
    for cand in "$CLAUDE_TARGET_HOME"/.vscode-server/bin/*/bin/remote-cli/code; do
        [[ -x "$cand" ]] && c="$cand"
    done
    [[ -n "$c" ]] && { echo "$c"; return 0; }
    return 1
}

host_step "Provisioning for ${CLAUDE_TARGET_USER} (home: ${CLAUDE_TARGET_HOME})"
if [[ "$CLAUDE_TARGET_HOME" == "/root" ]]; then
    host_warn "target home is /root — user-level steps would provision root, not a developer."
    host_note "run with sudo from the developer's own shell so SUDO_USER is set."
fi

# --- 1. VSCode server extensions ---------------------------------------------
host_step "[1/9] VSCode server extensions + claude on PATH"
CLAUDE_EXT_JUST_INSTALLED=0
if CODE_BIN="$(find_code)"; then
    for ext in anthropic.claude-code redhat.ansible; do
        # Check the extensions directory FIRST. `code --list-extensions` returns
        # nothing useful when it is not attached to a running server, so relying
        # on it made every run reinstall extensions that were already there and
        # report "installed" for a no-op.
        if compgen -G "$CLAUDE_TARGET_HOME/.vscode-server/extensions/${ext}-*" >/dev/null 2>&1; then
            host_info "$ext already installed"
        elif run_as_target "$CODE_BIN" --list-extensions 2>/dev/null | grep -qix "$ext"; then
            host_info "$ext already installed"
        elif run_as_target "$CODE_BIN" --install-extension "$ext" >/dev/null 2>&1; then
            host_info "installed $ext"
            [[ "$ext" == "anthropic.claude-code" ]] && CLAUDE_EXT_JUST_INSTALLED=1
        else
            host_warn "could not install $ext (install from the Extensions view)"
        fi
    done
else
    host_warn "no 'code' shim found — open the Extensions view and install: anthropic.claude-code, redhat.ansible"
fi

# The CLI ships INSIDE the extension and is not on PATH, so `claude` fails in the
# developer's own shells even on a fully provisioned box. A fixed symlink breaks
# on every extension update, because the directory name carries the version — so
# install a wrapper that resolves the glob at run time.
if command -v claude >/dev/null 2>&1; then
    host_info "claude already on PATH ($(command -v claude))"
else
    _wrapper_src="$(mktemp)"
    cat > "$_wrapper_src" <<'WRAP'
#!/usr/bin/env bash
# Resolve the Claude Code CLI that ships inside the VSCode extension. Written by
# provision-remote-box.sh. The glob is evaluated on every invocation so an
# extension update does not break this.
set -euo pipefail
_bin=""
for _cand in "$HOME"/.vscode-server/extensions/anthropic.claude-code-*/resources/native-binary/claude; do
    [[ -x "$_cand" ]] && _bin="$_cand"
done
if [[ -z "$_bin" ]]; then
    echo "claude: no CLI found under $HOME/.vscode-server/extensions/anthropic.claude-code-*" >&2
    echo "install the Claude Code extension and connect once so it unpacks." >&2
    exit 127
fi
exec "$_bin" "$@"
WRAP
    chmod 644 "$_wrapper_src"   # readable by the target user before install(1)
    _wrapper_dst="$CLAUDE_TARGET_HOME/.local/bin/claude"
    if [[ -f "$_wrapper_dst" ]] && cmp -s "$_wrapper_src" "$_wrapper_dst"; then
        host_info "claude wrapper already current: $_wrapper_dst"
    else
        run_as_target mkdir -p "$CLAUDE_TARGET_HOME/.local/bin" \
            && run_as_target install -m 755 "$_wrapper_src" "$_wrapper_dst" \
            && host_info "installed claude wrapper: $_wrapper_dst"
    fi
    rm -f "$_wrapper_src"
    if ! run_as_target bash -lc 'command -v claude >/dev/null 2>&1'; then
        host_warn "${CLAUDE_TARGET_HOME}/.local/bin is not on ${CLAUDE_TARGET_USER}'s PATH"
        host_note "add to your shell profile:  export PATH=\"\$HOME/.local/bin:\$PATH\""
    fi
fi

# --- 2. Ansible-lint + Docker ------------------------------------------------
host_step "[2/9] Ansible-lint + Docker"
run_as_target bash "$_SCRIPT_DIR/setup-ansible-lint.sh" ${ASSUME_YES:+--yes} \
    || host_fail "setup-ansible-lint.sh reported an issue"

# --- 3. Caveman + Claude plugins ---------------------------------------------
host_step "[3/9] Caveman + Claude plugins"
if [[ -f "$_REPO_ROOT/scripts/install-caveman.sh" ]]; then
    run_as_target bash "$_REPO_ROOT/scripts/install-caveman.sh" || host_fail "install-caveman.sh failed"
else
    host_note "scripts/install-caveman.sh not found — skipping caveman"
fi
if [[ -f "$_REPO_ROOT/scripts/install-claude-plugins.sh" ]]; then
    if CLAUDE_BIN_EARLY="$(find_claude)"; then
        run_as_target env CLAUDE_BIN="$CLAUDE_BIN_EARLY" \
            bash "$_REPO_ROOT/scripts/install-claude-plugins.sh" \
            || host_fail "install-claude-plugins.sh failed"
    else
        host_fail "claude CLI not found — skipping the shared plugin installer"
        host_note "connect once with the Claude Code extension so it unpacks, then re-run"
    fi
fi

if CLAUDE_BIN="$(find_claude)"; then
    _plugins="$(run_as_target "$CLAUDE_BIN" plugin list 2>/dev/null || echo "")"
    if ! echo "$_plugins" | grep -q "claude-plugins-official"; then
        # The marketplace is added by owner/repo, not by bare name. Adding
        # "claude-plugins-official" left it unregistered, so every subsequent
        # `plugin install <x>@claude-plugins-official` failed — and the failure
        # was reported as "already-present / failed (continuing)", which reads
        # like nothing was wrong.
        if _mkt_out="$(run_as_target "$CLAUDE_BIN" plugin marketplace add anthropics/claude-plugins-official 2>&1)"; then
            host_info "added marketplace claude-plugins-official"
        else
            host_warn "marketplace add failed:"
            printf '%s\n' "$_mkt_out" | tail -5 | while IFS= read -r _l; do host_note "    $_l"; done
        fi
    fi
    for p in skill-creator gitlab; do
        if echo "$_plugins" | grep -q "${p}@claude-plugins-official"; then
            host_info "${p}@claude-plugins-official already installed"
        elif _pi_out="$(run_as_target "$CLAUDE_BIN" plugin install "${p}@claude-plugins-official" --scope user 2>&1)"; then
            host_info "installed ${p}@claude-plugins-official"
        else
            # Print what actually went wrong. Discarding it turned every plugin
            # problem into the same content-free line.
            host_fail "could not install ${p}@claude-plugins-official"
            printf '%s\n' "$_pi_out" | tail -5 | while IFS= read -r _l; do host_note "    $_l"; done
        fi
    done
elif [[ "$CLAUDE_EXT_JUST_INSTALLED" == "1" ]]; then
    # Not the same as "missing". The extension went on disk moments ago and its
    # binary is unpacked when VSCode next starts the server. Reporting this the
    # same way as a genuinely absent CLI makes a normal first provision look
    # broken.
    host_fail "claude CLI not usable YET — the extension was installed during this run"
    host_note "reconnect the Remote-SSH window so it unpacks, then re-run this script."
    host_note "this is expected on a first provision; nothing is wrong."
else
    host_fail "claude CLI not found — official plugins not installed"
    host_note "install the Claude Code extension, connect once so it unpacks, then re-run."
fi

# --- 4. Killswitch -----------------------------------------------------------
host_step "[4/9] Killswitch"
bash "$_SCRIPT_DIR/setup-killswitch.sh" ${ASSUME_YES:+--yes} \
    || host_fail "setup-killswitch.sh reported an issue"

# --- 5. Git identity for this box --------------------------------------------
# The setup guide has the developer set this by hand and it was never
# implemented here. It is also the one step where the shared account changes the
# right answer.
#
# NOT global by default. `git config --global` writes to the shared account's
# home, so the first developer to run it silently becomes the committer identity
# for every colleague who has no repo-local override. That is the same failure
# as the SSH one this repository just fixed — a wrong identity that works
# perfectly until someone reads the attribution. Pass --git-identity-global only
# on a box genuinely dedicated to you.
host_step "[5/9] Git identity"
_g_name="$(run_as_target git config --global user.name 2>/dev/null || true)"
_g_mail="$(run_as_target git config --global user.email 2>/dev/null || true)"
if [[ -n "$_g_name" || -n "$_g_mail" ]]; then
    host_info "global git identity already set: ${_g_name:-<unset>} <${_g_mail:-unset}>"
    host_warn "this account is SHARED — that identity may belong to a colleague."
    host_note "check before you commit, and override per repository if it is not yours."
fi
host_ask GIT_USER_NAME "Your git commit name (blank to skip)" ""
if [[ -n "${GIT_USER_NAME:-}" ]]; then
    host_ask GIT_USER_EMAIL "Your git commit email" ""
fi
if [[ -n "${GIT_USER_NAME:-}" && -n "${GIT_USER_EMAIL:-}" ]]; then
    # Repo-local first: always safe on a shared account.
    run_as_target git -C "$_REPO_ROOT" config user.name "$GIT_USER_NAME" \
        && run_as_target git -C "$_REPO_ROOT" config user.email "$GIT_USER_EMAIL" \
        && host_info "set git identity for this repository checkout"
    if [[ "$GIT_IDENTITY_GLOBAL" == "1" ]]; then
        if [[ -n "$_g_name" || -n "$_g_mail" ]]; then
            host_warn "global identity already set — NOT overwriting it"
            host_note "clear it first if you meant to replace it: git config --global --unset user.name"
        else
            run_as_target git config --global user.name "$GIT_USER_NAME"
            run_as_target git config --global user.email "$GIT_USER_EMAIL"
            host_info "set GLOBAL git identity (shared account — every repo without an override uses it)"
        fi
    fi
    host_note "in YOUR project checkout, run the same two commands without --global:"
    host_note "    git config user.name \"$GIT_USER_NAME\""
    host_note "    git config user.email \"$GIT_USER_EMAIL\""
else
    host_note "skipped — set it per repository before you commit:"
    host_note "    git config user.name \"...\" && git config user.email \"...\""
fi

# --- 6. Build-tooling verification -------------------------------------------
# Provisioning used to write its completion marker having never confirmed the
# tooling the box exists to run actually works. That is the failure mode
# docs/PROJECT.md § "Provisioning must not lie" was written about, still present
# in the script that documents it.
#
# The command is site-specific and this repository is public, so it is supplied
# at run time. When it is not supplied we do not pretend: the step says so and
# the marker records tool_verified=unconfigured.
host_step "[6/9] Build tooling"
TOOL_VERIFIED="unconfigured"
if [[ -z "$VERIFY_CMD" ]]; then
    host_note "no --verify-cmd given — this run CANNOT confirm the build tooling works."
    host_note "supply the command that lists your tooling's inventory, e.g.:"
    host_note "    sudo bash scripts/host/provision-remote-box.sh --verify-cmd '<command>'"
    host_note "recorded in the marker as tool_verified=unconfigured."
else
    host_info "running: $VERIFY_CMD"
    if _verify_out="$(run_as_target bash -lc "$VERIFY_CMD" 2>&1)"; then
        TOOL_VERIFIED="yes"
        host_info "build tooling responded ($(printf '%s' "$_verify_out" | wc -l) line(s))"
    else
        TOOL_VERIFIED="no"
        # host_fail, not host_warn: a box that cannot run its own tooling has not
        # reached the golden state, and must not get a completion marker.
        host_fail "build tooling verification FAILED: $VERIFY_CMD"
        printf '%s\n' "$_verify_out" | tail -15 | while IFS= read -r _l; do host_note "    $_l"; done
        host_note "if this is an authentication failure, the forwarded agent is the usual cause:"
        host_note "    bash scripts/host/diagnose-git-auth.sh"
        host_note "    eval \"\$(bash scripts/host/fix-agent-sock.sh)\"   # stale socket after a reconnect"
    fi
fi

# --- 7. SSH agent-forwarding sanity check ------------------------------------
# Downstream build tooling authenticates with the developer's FORWARDED
# SSH key. Verify the box permits forwarding and (best-effort) that a forwarded
# key is actually reachable. Read-only: we warn, we do NOT edit sshd here.
host_step "[7/9] SSH agent forwarding"
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
elif [[ -z "${SSH_AUTH_SOCK:-}" && "$(id -u)" -eq 0 ]]; then
    # sudo strips SSH_AUTH_SOCK from the environment. Reporting that as "no
    # forwarded key" sends the developer to debug forwarding that is fine.
    host_note "SSH_AUTH_SOCK is unset because sudo dropped it — this says nothing"
    host_note "about forwarding. Check from your own shell:  ssh-add -l"
else
    host_note "no forwarded key visible in THIS shell. Verify from your interactive"
    host_note "VSCode session (useExecServer off + reconnected):  ssh-add -l"
    host_note "after a reconnect the socket can be stale, not missing:"
    host_note "    eval \"\$(bash scripts/host/fix-agent-sock.sh)\""
fi

# --- 8. ctp tool bridge + safety gate (user-scope) ---------------------------
# Install the gates at USER scope so they are present in Claude sessions started
# from the range checkout, not just this repo. install-ctp-bridge.sh also ships
# the destructive-action gate (cmd-segment.sh + safety-guard.sh) and the
# destructive-git gate (git-guard.sh), seeding ~/.config/safety-guard.conf and
# ~/.config/git-guard.conf, so a destructive command (rm -rf, dropdb, terraform
# destroy, ...) or git op (push --force, reset --hard, clean -f, branch -D)
# prompts for human confirmation in the same hook. Runs as the developer
# (run_as_target) so it lands in their home, never root's. Inert until they set
# CTP_ALLOWED_TARGET — a provisioned box refuses every deploy until configured,
# which is the safe direction.
host_step "[8/9] ctp tool bridge + destructive-action + destructive-git gates (user-scope)"
if command -v jq >/dev/null 2>&1; then
    if run_as_target bash "$_REPO_ROOT/scripts/install-ctp-bridge.sh"; then
        host_info "ctp bridge + safety gate installed for ${CLAUDE_TARGET_USER} (set CTP_ALLOWED_TARGET in ~/.ctp-bridge.conf; safety gate confirms destructive commands)"
    else
        host_fail "ctp bridge install failed"
    fi
else
    host_fail "jq not installed — ctp bridge gate cannot be installed (its hook needs jq)"
fi

host_step "[9/9] Commit guard (warn-only PII/secret scan)"
# Warn-only staged-content scan installed at USER scope so it covers every repo
# the developer commits in, including the range checkout, without writing into a
# pushed tree. It never blocks a commit (owner decision, PII and secrets alike);
# it prints and logs findings so a leaked secret can be rotated per SECURITY.md.
if run_as_target bash "$_REPO_ROOT/scripts/install-commit-guard.sh"; then
    host_info "commit guard installed for ${CLAUDE_TARGET_USER} (warn-only; findings in ~/.local/state/commit-guard/)"
else
    host_fail "commit guard install failed"
fi

# A failed step must NOT be recorded as a completed provision. Writing the
# marker anyway is what let a broken caveman install go unnoticed: the run
# printed "complete", exited 0, and every re-run then short-circuited on
# "Already provisioned".
#
# This gate sits AFTER every step. It used to sit before the last two, so a
# failure in them could not have stopped the marker being written.
if (( ${#HOST_FAILURES[@]} > 0 )); then
    host_step "Provisioning INCOMPLETE — ${#HOST_FAILURES[@]} step(s) failed"
    for _f in "${HOST_FAILURES[@]}"; do host_warn "$_f"; done
    host_note "No completion marker written, so a re-run retries these steps."
    host_note "Check status any time with: bash scripts/check-day0.sh"
    exit 1
fi

# Record completion so a reconnect can skip. Best-effort; never fail the run.
# tool_verified carries what this run actually established, so a later reader can
# tell a verified box from one where nobody supplied the command.
if _sudo mkdir -p "$MARKER_DIR" 2>/dev/null; then
    printf 'version=%s\nprovisioned_at=%s\nhost=%s\ntool_verified=%s\n' \
        "$PROVISION_VERSION" "$(date -Is)" "$(hostname)" "$TOOL_VERIFIED" \
        | _sudo tee "$MARKER" >/dev/null 2>&1 \
        && host_note "marker written: $MARKER (delete or use --force to reprovision)"
fi

host_step "Provisioning complete"
host_note "If the docker group was just added, REBOOT the box for it to take effect."
host_note "Killswitch audit log: sudo tail -f /var/log/claude-killswitch.log"
# The build tooling's first-run (vault) configuration is interactive and
# correctly manual — this script never touches credentials. But nothing else
# tells the operator it is the next required step, so a freshly provisioned box
# looks ready while ctp still cannot run. Point at it; do not perform it.
host_note "Next, once per box: run 'make start' and complete the first-run (vault) config."
host_note "  ctp cannot run until the vault is unlocked; the ctp bridge refuses until then."
