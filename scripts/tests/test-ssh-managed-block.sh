#!/usr/bin/env bash
# Behavioural tests for the devbox SSH "managed block" helpers (issue #38).
#
# A developer who bootstrapped before a directive existed (IdentityFile for the
# box key, RemoteForward for the local-model tunnel) must be able to pick it up
# on a re-run WITHOUT the script touching the Host block they hand-wrote. The
# helpers add the missing directives in a separate, marker-delimited block that
# SSH merges in (IdentityFile and RemoteForward are additive).
#
# These tests drive the helpers directly against a temp config — no network, no
# prompts, deterministic.
#
# Usage: bash scripts/tests/test-ssh-managed-block.sh
# Exit: 0 pass, non-zero = number of failures.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$(dirname "$HERE")/local/lib/ssh-config.sh"

if [[ ! -f "$LIB" ]]; then
    echo "FAIL: helper library not found at $LIB"
    exit 1
fi
# shellcheck source=/dev/null
source "$LIB"

fails=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ALIAS="devbox07"
HOST="devbox07.example.net"
KEY="~/.ssh/devbox07_key"
TUNNEL="RemoteForward 127.0.0.1:11434 127.0.0.1:11434"

ok()   { echo "PASS $1"; }
bad()  { echo "FAIL $1: $2"; fails=$((fails + 1)); }

# Apply: compute missing directives, and if any, (re)write the managed block.
apply() {
    local cfg="$1" missing
    missing="$(ssh_managed_missing "$cfg" "$ALIAS" "$HOST" "$KEY" "$TUNNEL")"
    if [[ -n "$missing" ]]; then
        printf '%s\n' "$missing" | ssh_write_managed_block "$cfg" "$ALIAS" "$HOST"
    fi
}

# --- 1. stale hand-written block: both directives added in a managed block ----
cfg="$TMP/stale"
cat >"$cfg" <<EOF
Host $ALIAS $HOST
    HostName $HOST
    User gt
    ForwardAgent yes
EOF
apply "$cfg"
if grep -q 'devbox-managed devbox07' "$cfg" \
   && grep -qF "IdentityFile $KEY" "$cfg" \
   && grep -qF "$TUNNEL" "$cfg"; then
    ok stale-block-gets-both
else
    bad stale-block-gets-both "managed block or a directive missing:$(printf '\n%s' "$(cat "$cfg")")"
fi

# --- 2. hand-written block is left byte-for-byte untouched --------------------
before="$(awk '/^# >>> devbox-managed/{exit} {print}' "$cfg")"
expected="$(printf 'Host %s %s\n    HostName %s\n    User gt\n    ForwardAgent yes\n' "$ALIAS" "$HOST" "$HOST")"
if [[ "$before" == "$expected" ]]; then
    ok handwritten-untouched
else
    bad handwritten-untouched "developer block changed"
fi

# --- 3. already-complete block: nothing added --------------------------------
cfg="$TMP/complete"
cat >"$cfg" <<EOF
Host $ALIAS $HOST
    HostName $HOST
    User gt
    IdentityFile $KEY
    $TUNNEL
    ForwardAgent yes
EOF
sum_before="$(cksum "$cfg")"
apply "$cfg"
if ! grep -q 'devbox-managed' "$cfg" && [[ "$(cksum "$cfg")" == "$sum_before" ]]; then
    ok complete-block-noop
else
    bad complete-block-noop "wrote a managed block though nothing was missing"
fi

# --- 4. idempotent: applying twice yields an identical file ------------------
cfg="$TMP/idem"
cat >"$cfg" <<EOF
Host $ALIAS $HOST
    HostName $HOST
    User gt
EOF
apply "$cfg"
sum_once="$(cksum "$cfg")"
apply "$cfg"
if [[ "$(cksum "$cfg")" == "$sum_once" ]] && [[ "$(grep -c 'devbox-managed devbox07 >>>' "$cfg")" -eq 1 ]]; then
    ok idempotent
else
    bad idempotent "second apply changed the file or duplicated the block"
fi

# --- 5. multi-box file: only the target alias is touched ---------------------
cfg="$TMP/multibox"
cat >"$cfg" <<EOF
Host otherbox otherbox.example.net
    HostName otherbox.example.net
    User gt
    IdentityFile ~/.ssh/otherbox_key

Host $ALIAS $HOST
    HostName $HOST
    User gt
EOF
other_before="$(sed -n '/^Host otherbox /,/^$/p' "$cfg")"
apply "$cfg"
other_after="$(sed -n '/^Host otherbox /,/^$/p' "$cfg")"
if [[ "$other_before" == "$other_after" ]] \
   && [[ "$(grep -c 'devbox-managed' "$cfg")" -eq 2 ]] \
   && grep -q 'devbox-managed devbox07' "$cfg" \
   && ! grep -q 'devbox-managed otherbox' "$cfg"; then
    ok multibox-scoped
else
    bad multibox-scoped "touched the wrong box or added a block for otherbox"
fi

# --- 6. another box's identical directive does not suppress ours -------------
# otherbox has an IdentityFile line; ours is a different value and must still be
# added — the whole-file must not be scanned, only the matching block.
cfg="$TMP/nosuppress"
cat >"$cfg" <<EOF
Host otherbox otherbox.example.net
    IdentityFile $KEY

Host $ALIAS $HOST
    HostName $HOST
    User gt
EOF
apply "$cfg"
blk="$(awk '/>>> devbox-managed devbox07/{f=1} f{print} /<<< devbox-managed devbox07/{f=0}' "$cfg")"
if [[ -n "$blk" ]] && grep -qF "IdentityFile $KEY" <<<"$blk"; then
    ok match-scoped-detection
else
    bad match-scoped-detection "a same-looking directive in another block suppressed ours"
fi

# --- 7. self-heal: dev adds the lines by hand -> managed block removed --------
cfg="$TMP/selfheal"
cat >"$cfg" <<EOF
Host $ALIAS $HOST
    HostName $HOST
    User gt
EOF
apply "$cfg"                         # creates managed block
# developer folds the directives into their own block, by hand:
cat >"$cfg" <<EOF
Host $ALIAS $HOST
    HostName $HOST
    User gt
    IdentityFile $KEY
    $TUNNEL
EOF
apply "$cfg"                         # nothing missing now
if ! grep -q 'devbox-managed' "$cfg"; then
    ok self-heal-removes-block
else
    bad self-heal-removes-block "managed block lingered after directives were added by hand"
fi

# --- 8. no tunnel configured: managed block carries only IdentityFile ---------
cfg="$TMP/notunnel"
cat >"$cfg" <<EOF
Host $ALIAS $HOST
    HostName $HOST
    User gt
EOF
missing="$(ssh_managed_missing "$cfg" "$ALIAS" "$HOST" "$KEY" "")"
printf '%s\n' "$missing" | ssh_write_managed_block "$cfg" "$ALIAS" "$HOST"
if grep -qF "IdentityFile $KEY" "$cfg" && ! grep -q 'RemoteForward' "$cfg"; then
    ok no-tunnel-only-identity
else
    bad no-tunnel-only-identity "RemoteForward present though no tunnel was configured"
fi

echo ""
if [[ "$fails" -eq 0 ]]; then
    echo "ALL PASS"
else
    echo "$fails FAILED"
fi
exit "$fails"
