#!/usr/bin/env bash
# Behavioural tests for the devbox agent-forwarding and tunnel defaults (issue #86).
#
# A fresh bootstrap must write `ForwardAgent no` and no RemoteForward unless the
# developer explicitly asks; an opt-in that cannot be honoured must degrade to
# `no`, never silently to `yes`; and a re-run must flag risky directives an older
# run left behind. These tests drive the helpers in scripts/local/lib/ssh-config.sh
# directly and grep the bootstrap scripts for their defaults — no network, no
# prompts, deterministic.
#
# Usage: bash scripts/tests/test-devbox-forwarding.sh
# Exit: 0 pass, non-zero = number of failures.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$(dirname "$HERE")")"
LIB="$ROOT/scripts/local/lib/ssh-config.sh"
SH="$ROOT/scripts/local/bootstrap-devbox.sh"
PS1="$ROOT/scripts/local/bootstrap-devbox.ps1"

[[ -f "$LIB" ]] || { echo "FAIL: helper library not found at $LIB"; exit 1; }
# shellcheck source=/dev/null
source "$LIB"

fails=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fails=$((fails + 1)); }
eq()  { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }

# --- ssh_forward_value -------------------------------------------------------
eq "default mode forwards nothing"            "$(ssh_forward_value "" "" 9 6)"           "no"
eq "explicit no forwards nothing"             "$(ssh_forward_value no "" 9 6)"           "no"
eq "scoped on OpenSSH 9.6 uses the socket"    "$(ssh_forward_value scoped /s.sock 9 6)"  "/s.sock"
eq "scoped on OpenSSH 8.9 uses the socket"    "$(ssh_forward_value scoped /s.sock 8 9)"  "/s.sock"
eq "scoped on OpenSSH 8.8 degrades to no"     "$(ssh_forward_value scoped /s.sock 8 8)"  "no"
eq "scoped with no socket degrades to no"     "$(ssh_forward_value scoped "" 9 6)"       "no"
eq "unknown mode forwards nothing"            "$(ssh_forward_value maybe "" 9 6)"        "no"
eq "FORWARD_AGENT=all is the only path to yes" "$(ssh_forward_value all "" 0 0)"        "yes"

# --- ssh_host_block: fresh run -----------------------------------------------
blk="$(ssh_host_block box box.example.test box.example.test dev "$HOME/.ssh/k" "$(ssh_forward_value "" "" 9 6)" "")"
if grep -qx '  ForwardAgent no' <<<"$blk"; then ok "fresh block has ForwardAgent no"; else bad "fresh block has ForwardAgent no"; fi
if grep -qi 'RemoteForward' <<<"$blk"; then bad "fresh block has no RemoteForward"; else ok "fresh block has no RemoteForward"; fi
blk2="$(ssh_host_block box box.example.test box.example.test dev "$HOME/.ssh/k" no "  RemoteForward 127.0.0.1:11434 127.0.0.1:11434")"
if grep -qx '  RemoteForward 127.0.0.1:11434 127.0.0.1:11434' <<<"$blk2"; then ok "opt-in tunnel line is written"; else bad "opt-in tunnel line is written"; fi
blk3="$(ssh_host_block box box.example.test box.example.test dev "$HOME/.ssh/k" /s.sock "")"
if grep -qx '  ForwardAgent /s.sock' <<<"$blk3"; then ok "scoped socket written as ForwardAgent path"; else bad "scoped socket written as ForwardAgent path"; fi

# --- ssh_risky_directives: re-run warning -------------------------------------
cat >"$TMP/cfg" <<'CFG'
Host other other.example.test
  ForwardAgent yes

Host box box.example.test
  HostName box.example.test
  ForwardAgent   YES
  RemoteForward 127.0.0.1:11434 127.0.0.1:11434
CFG
risky="$(ssh_risky_directives box box.example.test <"$TMP/cfg")"
if grep -qx 'ForwardAgent yes' <<<"$risky"; then ok "re-run flags ForwardAgent yes (any case)"; else bad "re-run flags ForwardAgent yes (any case)"; fi
if grep -q '^RemoteForward ' <<<"$risky"; then ok "re-run flags RemoteForward"; else bad "re-run flags RemoteForward"; fi
cat >"$TMP/clean" <<'CFG'
Host other other.example.test
  ForwardAgent yes

Host box box.example.test
  ForwardAgent no
CFG
eq "other hosts' directives are not flagged" "$(ssh_risky_directives box box.example.test <"$TMP/clean")" ""

# --- bootstrap script defaults --------------------------------------------------
if grep -q 'LOCAL_MODEL_TUNNEL:-false' "$SH"; then ok "bash tunnel defaults off"; else bad "bash tunnel defaults off"; fi
if grep -q "falling back to 'ForwardAgent yes'" "$SH"; then bad "bash never falls back to ForwardAgent yes"; else ok "bash never falls back to ForwardAgent yes"; fi
if grep -q 'ssh_host_block ' "$SH"; then ok "bash writes the block via ssh_host_block"; else bad "bash writes the block via ssh_host_block"; fi
if grep -q 'ProxyJump' "$SH"; then ok "bash documents ProxyJump"; else bad "bash documents ProxyJump"; fi
if grep -q '"remote.SSH.enableAgentForwarding": fwd,' "$SH" \
   && ! grep -q '"remote.SSH.enableAgentForwarding": True' "$SH"; then
    ok "bash VSCode agent forwarding follows the Host block decision"
else
    bad "bash VSCode agent forwarding follows the Host block decision"
fi
# The PowerShell patterns below match a literal `$` on purpose.
# shellcheck disable=SC2016
if grep -q '\$env:LOCAL_MODEL_TUNNEL -ne "true"' "$PS1"; then ok "ps1 tunnel defaults off"; else bad "ps1 tunnel defaults off"; fi
# shellcheck disable=SC2016
if grep -q 'ForwardAgent yes\$TunnelLine' "$PS1"; then bad "ps1 no longer hardcodes ForwardAgent yes"; else ok "ps1 no longer hardcodes ForwardAgent yes"; fi
# shellcheck disable=SC2016
if grep -q '\$Forward = "no"' "$PS1"; then ok "ps1 defaults ForwardAgent no"; else bad "ps1 defaults ForwardAgent no"; fi
# shellcheck disable=SC2016
if grep -q 'enableAgentForwarding" -NotePropertyValue \$fwdOn' "$PS1"; then
    ok "ps1 VSCode agent forwarding follows the Host block decision"
else
    bad "ps1 VSCode agent forwarding follows the Host block decision"
fi

echo
if (( fails == 0 )); then echo "All devbox forwarding tests passed."; else echo "$fails failure(s)."; fi
exit "$fails"
