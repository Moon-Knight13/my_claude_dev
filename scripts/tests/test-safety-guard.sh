#!/usr/bin/env bash
# shellcheck disable=SC2015
# test-safety-guard.sh — the destructive-action gate: destructive commands are
# classified `ask` on segmented command words (so quoted/heredoc text and env
# prefixes/subshells are handled), benign commands are untouched, the ctp path is
# preserved, the owner allow-list can exempt a verb, and the INSTALLED hook gates
# using the libs from ~/.local (not the repo).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok()  { echo "  OK  $1"; ((PASS++)) || true; }
bad() { echo " FAIL $1"; ((FAIL++)) || true; }
command -v jq >/dev/null 2>&1 || { echo "jq required; skipping"; exit 0; }

# ── unit: safety_classify verdicts ──────────────────────────────────────────
# shellcheck disable=SC1091
source "$ROOT/scripts/lib/cmd-segment.sh"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib/safety-guard.sh"
safety_load_config /nonexistent-empty-allowlist

asks()   { local v; v="$(safety_classify "$1")"; [[ "$v" == ask:* ]]  && ok "ask: $1"    || bad "expected ask: $1 (got '$v')"; }
allows() { local v; v="$(safety_classify "$1")"; [[ -z "$v" ]]         && ok "allow: $1"  || bad "expected allow: $1 (got '$v')"; }

asks   'rm -rf /var/data'
asks   'rm -fr build'
asks   'FOO=1 dropdb prod'
asks   'dd if=/dev/zero of=/dev/sda'
asks   'terraform destroy -auto-approve'
asks   'kubectl delete pod x'
asks   'docker system prune -af'
asks   'psql -c "DROP TABLE users"'
asks   'mkfs.ext4 /dev/sdb1'
asks   'shred -u secret.txt'
allows 'ls -la'
allows 'git status'
allows 'psql -c "SELECT 1"'
allows 'rm file.txt'
allows 'git commit -m "drop the users table"'
allows 'echo drop database everything'
allows 'terraform plan'

# ── owner allow-list exempts a verb ─────────────────────────────────────────
_AL="$(mktemp)"; echo 'SAFETY_ALLOWLIST=rm terraform' > "$_AL"; safety_load_config "$_AL"
[[ -z "$(safety_classify 'rm -rf /x')" ]]            && ok "allow-list exempts rm"        || bad "rm not exempted"
[[ -z "$(safety_classify 'terraform destroy')" ]]    && ok "allow-list exempts terraform" || bad "terraform not exempted"
[[ "$(safety_classify 'dropdb x')" == ask:* ]]       && ok "non-exempt verb still gated"  || bad "dropdb wrongly exempted"
safety_load_config /nonexistent-empty-allowlist

# ── hook e2e: decision JSON via stdin ───────────────────────────────────────
HOOK="$ROOT/.claude/hooks/pretooluse-ctp.sh"
J() { jq -cn --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}'; }
dec() { local d; d="$(J "$1" | bash "$HOOK" 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecision // "none"' 2>/dev/null)"; echo "${d:-none}"; }

[[ "$(dec 'rm -rf /data')"          == ask  ]] && ok "hook: rm -rf -> ask"                 || bad "hook rm -rf"
# shellcheck disable=SC2016  # the $(...) is intentional literal test data, must not expand
[[ "$(dec 'echo "$(rm -rf /x)"')"   == ask  ]] && ok "hook: subshell rm -rf -> ask"        || bad "hook subshell"
[[ "$(dec 'ls -la && git status')"  == none ]] && ok "hook: benign -> no opinion"          || bad "hook benign"
[[ "$(dec 'git commit -m "drop table"')" == none ]] && ok "hook: commit msg -> no opinion" || bad "hook false-positive"
[[ "$(dec 'ctp host deploy box')"   == deny ]] && ok "hook: bare ctp -> deny (preserved)"  || bad "hook ctp regression"

# ── installed hook resolves libs from ~/.local and gates ────────────────────
FH="$(mktemp -d)"; trap 'rm -rf "$FH"' EXIT
HOME="$FH" bash "$ROOT/scripts/install-ctp-bridge.sh" >/dev/null 2>&1
[[ -f "$FH/.local/lib/ctp-bridge/cmd-segment.sh" ]] && ok "installer ships cmd-segment.sh" || bad "cmd-segment not shipped"
[[ -f "$FH/.local/lib/ctp-bridge/safety-guard.sh" ]] && ok "installer ships safety-guard.sh" || bad "safety-guard not shipped"
[[ -f "$FH/.config/safety-guard.conf" ]] && ok "installer seeds safety-guard.conf" || bad "config not seeded"
idec() { local d; d="$(jq -cn --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}' | HOME="$FH" bash "$FH/.claude/hooks/pretooluse-ctp.sh" 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecision // "none"' 2>/dev/null)"; echo "${d:-none}"; }
[[ "$(idec 'terraform destroy')" == ask ]] && ok "installed hook gates from ~/.local" || bad "installed hook did not gate"

echo ""; echo "safety-guard: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
