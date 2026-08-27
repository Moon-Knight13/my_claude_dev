#!/usr/bin/env bash
# Deterministic tests for scripts/host/provision-remote-box.sh — the invariant
# that matters is "Provisioning must not lie" (docs/PROJECT.md): a step that
# fails must not produce a completion marker, and a run that verified nothing
# must not record that it did.
#
# Runs against a sandboxed copy with stubbed sub-installers and PATH shims. No
# sudo, no writes outside $TMPDIR, no network.
#
# Usage: bash scripts/tests/test-provision.sh
# Exit: 0 all pass, 1 otherwise.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(dirname "$HERE")"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok()  { echo "PASS $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1: $2"; fail=$((fail + 1)); }

# ── PATH shims ────────────────────────────────────────────────────────────────
# sudo becomes a passthrough so the script's _sudo/_as_user helpers work as an
# unprivileged user; the rest stand in for tools a box has and a test host does
# not. None of them are the subject of these tests.
SHIMS="$TMP/shims"
mkdir -p "$SHIMS"

cat > "$SHIMS/sudo" <<'EOF'
#!/usr/bin/env bash
# Passthrough, including the `sudo -u <user> cmd...` form.
[[ "${1:-}" == "-u" ]] && shift 2
[[ "${1:-}" == "-v" ]] && exit 0
exec "$@"
EOF

cat > "$SHIMS/code" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "--list-extensions" ]] && { echo anthropic.claude-code; echo redhat.ansible; }
exit 0
EOF

cat > "$SHIMS/claude" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-} ${2:-}" == "plugin list" ]]; then
  echo "claude-plugins-official"
  echo "skill-creator@claude-plugins-official"
  echo "gitlab@claude-plugins-official"
fi
exit 0
EOF

cat > "$SHIMS/sshd" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "-T" ]] && echo "allowagentforwarding yes"
exit 0
EOF

chmod +x "$SHIMS"/*

# ── sandbox ───────────────────────────────────────────────────────────────────
make_sandbox() { # writes a provisionable sandbox into $1
    local sb="$1"
    mkdir -p "$sb/scripts/host/lib" "$sb/scripts"
    cp "$SCRIPTS/host/provision-remote-box.sh" "$sb/scripts/host/"
    cp "$SCRIPTS/host/lib/host-common.sh" "$sb/scripts/host/lib/"
    # Stub every sub-installer: this suite tests the orchestrator's honesty, not
    # what the installers do.
    for stub in scripts/host/setup-ansible-lint.sh scripts/host/setup-killswitch.sh \
                scripts/install-caveman.sh scripts/install-claude-plugins.sh \
                scripts/install-ctp-bridge.sh; do
        # shellcheck disable=SC2016  # ${STUB_RC} is stub-script content, expanded at stub runtime
        printf '#!/usr/bin/env bash\nexit ${STUB_RC:-0}\n' > "$sb/$stub"
        chmod +x "$sb/$stub"
    done
    git -C "$sb" init -q
    git -C "$sb" config user.email "fixture@example.invalid"
    git -C "$sb" config user.name "Fixture"
}

provision() { # sandbox [args...] — runs the provisioner, echoes exit code
    local sb="$1"; shift
    (
        cd "$sb" || exit 99
        env PATH="$SHIMS:$PATH" \
            DEVBOX_MARKER_DIR="$sb/marker" \
            HOME="$sb/home" \
            GIT_CONFIG_GLOBAL="$sb/home/.gitconfig" \
            SUDO_USER="" \
            bash scripts/host/provision-remote-box.sh --yes "$@"
    ) > "$TMP/out" 2>&1
    echo $?
}

marker_field() { # sandbox field
    grep -E "^$2=" "$1/marker/provisioned" 2>/dev/null | cut -d= -f2-
}

# ── 1. Verification passes: marker records it ────────────────────────────────
SB="$TMP/verified"; make_sandbox "$SB"; mkdir -p "$SB/home"
rc="$(provision "$SB" --verify-cmd 'echo host-a; echo host-b')"
if [[ "$rc" == "0" ]] && [[ "$(marker_field "$SB" tool_verified)" == "yes" ]]; then
    ok "verify-cmd succeeds -> marker tool_verified=yes"
else
    bad "verify-cmd success" "exit=$rc; tool_verified=$(marker_field "$SB" tool_verified)"
fi

# ── 2. Verification fails: NO marker, non-zero exit ──────────────────────────
# The core invariant. A box that cannot run its own tooling has not reached the
# golden state, so a re-run must retry rather than short-circuit on
# "Already provisioned".
SB="$TMP/unverified"; make_sandbox "$SB"; mkdir -p "$SB/home"
rc="$(provision "$SB" --verify-cmd 'exit 7')"
if [[ "$rc" == "1" ]] && [[ ! -f "$SB/marker/provisioned" ]] \
    && grep -q "Provisioning INCOMPLETE" "$TMP/out"; then
    ok "verify-cmd fails -> no marker, exit 1"
else
    bad "verify-cmd failure" "exit=$rc; marker exists: $([[ -f "$SB/marker/provisioned" ]] && echo yes || echo no)"
fi

# ── 3. No verification command: says so, does not claim success ──────────────
SB="$TMP/noverify"; make_sandbox "$SB"; mkdir -p "$SB/home"
rc="$(provision "$SB")"
if [[ "$rc" == "0" ]] && [[ "$(marker_field "$SB" tool_verified)" == "unconfigured" ]] \
    && grep -q "CANNOT confirm the build tooling works" "$TMP/out"; then
    ok "no verify-cmd -> marker tool_verified=unconfigured, stated in output"
else
    bad "no verify-cmd" "exit=$rc; tool_verified=$(marker_field "$SB" tool_verified)"
fi

# ── 4. A failing sub-installer still blocks the marker ───────────────────────
# The failure gate used to sit before the last two steps, so a late failure could
# not have stopped the marker. Assert it now covers the whole run.
SB="$TMP/stubfail"; make_sandbox "$SB"; mkdir -p "$SB/home"
printf '#!/usr/bin/env bash\nexit 1\n' > "$SB/scripts/host/setup-killswitch.sh"
chmod +x "$SB/scripts/host/setup-killswitch.sh"
rc="$(provision "$SB" --verify-cmd 'true')"
if [[ "$rc" == "1" ]] && [[ ! -f "$SB/marker/provisioned" ]]; then
    ok "failing installer -> no marker, exit 1"
else
    bad "failing installer" "exit=$rc; marker exists: $([[ -f "$SB/marker/provisioned" ]] && echo yes || echo no)"
fi

# ── 5. Git identity is repo-local, never global by default ───────────────────
# `git config --global` on a shared account makes the first developer to run it
# the committer identity for every colleague without an override.
SB="$TMP/gitid"; make_sandbox "$SB"; mkdir -p "$SB/home"
(
    cd "$SB" || exit 0
    env PATH="$SHIMS:$PATH" DEVBOX_MARKER_DIR="$SB/marker" HOME="$SB/home" \
        GIT_CONFIG_GLOBAL="$SB/home/.gitconfig" GIT_USER_NAME="Test Dev" \
        GIT_USER_EMAIL="test@example.invalid" \
        bash scripts/host/provision-remote-box.sh --yes --verify-cmd 'true'
) > "$TMP/out" 2>&1
_local_name="$(git -C "$SB" config --local user.name 2>/dev/null || true)"
_global_name="$(GIT_CONFIG_GLOBAL="$SB/home/.gitconfig" git config --global user.name 2>/dev/null || true)"
if [[ "$_local_name" == "Test Dev" && -z "$_global_name" ]]; then
    ok "git identity set repo-local, global untouched"
else
    bad "git identity" "local='$_local_name' global='$_global_name' (global must stay empty)"
fi

# ── 6. --git-identity-global sets it only when nothing is there ──────────────
SB="$TMP/gitid-global"; make_sandbox "$SB"; mkdir -p "$SB/home"
printf '[user]\n\tname = Someone Else\n\temail = other@example.invalid\n' > "$SB/home/.gitconfig"
(
    cd "$SB" || exit 0
    env PATH="$SHIMS:$PATH" DEVBOX_MARKER_DIR="$SB/marker" HOME="$SB/home" \
        GIT_CONFIG_GLOBAL="$SB/home/.gitconfig" GIT_USER_NAME="Test Dev" \
        GIT_USER_EMAIL="test@example.invalid" \
        bash scripts/host/provision-remote-box.sh --yes --git-identity-global --verify-cmd 'true'
) > "$TMP/out" 2>&1
_global_name="$(GIT_CONFIG_GLOBAL="$SB/home/.gitconfig" git config --global user.name 2>/dev/null || true)"
if [[ "$_global_name" == "Someone Else" ]] && grep -q "NOT overwriting" "$TMP/out"; then
    ok "--git-identity-global refuses to overwrite an existing identity"
else
    bad "--git-identity-global overwrite guard" "global='$_global_name'"
fi

# ── 7. User-level work targets the developer, not root ──────────────────────
# Under sudo, $HOME is /root. Steps 1-3 do user-level work — VSCode extensions,
# the Machine settings.json, caveman, the plugin set — and using $HOME there
# provisioned root instead of the developer, silently, on every box.
SB="$TMP/target"; make_sandbox "$SB"; mkdir -p "$SB/home"
rc="$(provision "$SB" --verify-cmd 'true')"
if grep -q "Provisioning for " "$TMP/out"; then
    ok "run states which user it is provisioning for"
else
    bad "target user announced" "no 'Provisioning for' line in output"
fi

SB="$TMP/target-root"; make_sandbox "$SB"; mkdir -p "$SB/home"
(
    cd "$SB" || exit 0
    env PATH="$SHIMS:$PATH" DEVBOX_MARKER_DIR="$SB/marker" HOME="$SB/home" \
        CLAUDE_TARGET_USER=root CLAUDE_TARGET_HOME=/root \
        GIT_CONFIG_GLOBAL="$SB/home/.gitconfig" \
        bash scripts/host/provision-remote-box.sh --yes --verify-cmd 'true'
) > "$TMP/out" 2>&1
if grep -q "target home is /root" "$TMP/out"; then
    ok "provisioning root instead of a developer is called out"
else
    bad "root target warning" "no warning when CLAUDE_TARGET_HOME=/root"
fi

# ── 8. Marketplaces are added by owner/repo, never by bare name ─────────────
# `claude plugin marketplace add claude-plugins-official` silently does not
# register anything, and every later `plugin install <x>@claude-plugins-official`
# then fails. Static check: any marketplace add in this repo must name a source.
_bad_add="$(grep -rn --exclude-dir=tests "plugin marketplace add" "$SCRIPTS" 2>/dev/null \
    | grep -vE "plugin marketplace add [\"'\$]*[A-Za-z0-9_.-]+/" || true)"
if [[ -z "$_bad_add" ]]; then
    ok "every 'plugin marketplace add' names an owner/repo source"
else
    bad "marketplace add by bare name" "$_bad_add"
fi

# ── 9. The claude wrapper resolves the extension binary at run time ─────────
# The CLI ships inside the VSCode extension and is not on PATH. A fixed symlink
# breaks on every extension update because the directory carries the version, so
# the wrapper must evaluate the glob when it runs, not when it was written.
SB="$TMP/wrapper"; make_sandbox "$SB"; mkdir -p "$SB/home"
_fake_ext="$SB/home/.vscode-server/extensions/anthropic.claude-code-1.0.0/resources/native-binary"
mkdir -p "$_fake_ext"
printf '#!/usr/bin/env bash\necho CLAUDE-1.0.0 "$@"\n' > "$_fake_ext/claude"
chmod +x "$_fake_ext/claude"
# PATH deliberately WITHOUT a `claude`: the wrapper exists precisely for the box
# case where the CLI is not on PATH, so the suite's own claude shim must not be
# visible here.
SHIMS_NOCLAUDE="$TMP/shims-noclaude"; mkdir -p "$SHIMS_NOCLAUDE"
for _sh in "$SHIMS"/*; do
    [[ "$(basename "$_sh")" == "claude" ]] && continue
    cp "$_sh" "$SHIMS_NOCLAUDE/"
done
(
    cd "$SB" || exit 0
    env PATH="$SHIMS_NOCLAUDE:/usr/bin:/bin" DEVBOX_MARKER_DIR="$SB/marker" HOME="$SB/home" \
        CLAUDE_TARGET_USER="$(id -un)" CLAUDE_TARGET_HOME="$SB/home" \
        GIT_CONFIG_GLOBAL="$SB/home/.gitconfig" \
        bash scripts/host/provision-remote-box.sh --yes --verify-cmd 'true'
) > "$TMP/out" 2>&1
_wrapper="$SB/home/.local/bin/claude"
if [[ -x "$_wrapper" ]] && HOME="$SB/home" "$_wrapper" --version 2>&1 | grep -q "CLAUDE-1.0.0"; then
    ok "claude wrapper installed and resolves the extension binary"
else
    bad "claude wrapper" "not installed or did not resolve ($_wrapper)"
fi

# An extension update renames the versioned directory. A wrapper that resolved
# the glob at write time would now be broken.
if [[ -x "$_wrapper" ]]; then
    mv "$SB/home/.vscode-server/extensions/anthropic.claude-code-1.0.0" \
       "$SB/home/.vscode-server/extensions/anthropic.claude-code-2.0.0"
    printf '#!/usr/bin/env bash\necho CLAUDE-2.0.0 "$@"\n' \
        > "$SB/home/.vscode-server/extensions/anthropic.claude-code-2.0.0/resources/native-binary/claude"
    chmod +x "$SB/home/.vscode-server/extensions/anthropic.claude-code-2.0.0/resources/native-binary/claude"
    if HOME="$SB/home" "$_wrapper" --version 2>&1 | grep -q "CLAUDE-2.0.0"; then
        ok "wrapper survives an extension version bump"
    else
        bad "wrapper after version bump" "$(HOME="$SB/home" "$_wrapper" --version 2>&1 | head -1)"
    fi
fi

# ── 10. An already-installed extension is not reinstalled ───────────────────
# `code --list-extensions` returns nothing useful when it is not attached to a
# running server, so relying on it alone reported "installed" for a no-op on
# every run.
SB="$TMP/ext-idem"; make_sandbox "$SB"; mkdir -p "$SB/home"
mkdir -p "$SB/home/.vscode-server/extensions/anthropic.claude-code-1.0.0" \
         "$SB/home/.vscode-server/extensions/redhat.ansible-2.0.0"
(
    cd "$SB" || exit 0
    env PATH="$SHIMS:/usr/bin:/bin" DEVBOX_MARKER_DIR="$SB/marker" HOME="$SB/home" \
        CLAUDE_TARGET_USER="$(id -un)" CLAUDE_TARGET_HOME="$SB/home" \
        GIT_CONFIG_GLOBAL="$SB/home/.gitconfig" \
        bash scripts/host/provision-remote-box.sh --yes --verify-cmd 'true'
) > "$TMP/out" 2>&1
if grep -q "anthropic.claude-code already installed" "$TMP/out" \
    && ! grep -q "installed anthropic.claude-code" "$TMP/out"; then
    ok "present extension reported as already installed, not reinstalled"
else
    bad "extension idempotence" "$(grep -E 'claude-code' "$TMP/out" | head -2 | tr '\n' '|')"
fi

# ── 11. A second run changes nothing ────────────────────────────────────────
# Idempotence is the contract: every step is safe to re-run, and a re-run must
# not claim to have done work it did not do. --force is used so the marker
# short-circuit does not hide step-level behaviour.
SB="$TMP/idem"; make_sandbox "$SB"; mkdir -p "$SB/home"
mkdir -p "$SB/home/.vscode-server/extensions/anthropic.claude-code-1.0.0" \
         "$SB/home/.vscode-server/extensions/redhat.ansible-2.0.0"
run_twice() {
    (
        cd "$SB" || exit 0
        env PATH="$SHIMS:$PATH" DEVBOX_MARKER_DIR="$SB/marker" HOME="$SB/home" \
            CLAUDE_TARGET_USER="$(id -un)" CLAUDE_TARGET_HOME="$SB/home" \
            GIT_CONFIG_GLOBAL="$SB/home/.gitconfig" GIT_USER_NAME="Test Dev" \
            GIT_USER_EMAIL="test@example.invalid" \
            bash scripts/host/provision-remote-box.sh --yes --force --verify-cmd 'true'
    ) > "$1" 2>&1
    echo $?
}
rc1="$(run_twice "$TMP/run1")"
_marker1="$(cat "$SB/marker/provisioned")"
rc2="$(run_twice "$TMP/run2")"
_marker2="$(cat "$SB/marker/provisioned")"

if [[ "$rc1" == "0" && "$rc2" == "0" ]]; then
    ok "both runs succeed"
else
    bad "repeat run exit codes" "first=$rc1 second=$rc2"
fi

# The marker is rewritten each run, so only the timestamp may differ.
if [[ "$(grep -v provisioned_at <<<"$_marker1")" == "$(grep -v provisioned_at <<<"$_marker2")" ]]; then
    ok "marker content stable across runs (timestamp aside)"
else
    bad "marker drift" "run1='$_marker1' run2='$_marker2'"
fi

# Nothing may be reinstalled or re-created on the second pass.
_claims="$(grep -cE "^  \+\+  installed " "$TMP/run2" || true)"
if [[ "${_claims:-0}" == "0" ]]; then
    ok "second run claims no new installs"
else
    bad "second run reinstalls" "$(grep -E "^  \+\+  installed " "$TMP/run2" | tr '\n' '|')"
fi

# And the git identity written on the first pass must not be rewritten blindly.
if grep -q "NOT overwriting\|already set" "$TMP/run2" || ! grep -q "set GLOBAL git identity" "$TMP/run2"; then
    ok "second run does not overwrite an existing identity"
else
    bad "identity overwritten on re-run" "$(grep -i identity "$TMP/run2" | tr '\n' '|')"
fi

echo
echo "== $pass passed, $fail failed =="
(( fail == 0 ))
