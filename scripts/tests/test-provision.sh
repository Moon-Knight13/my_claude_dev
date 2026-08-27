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
                scripts/install-caveman.sh scripts/install-claude-plugins.sh; do
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

echo
echo "== $pass passed, $fail failed =="
(( fail == 0 ))
