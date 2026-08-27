#!/usr/bin/env bash
# test-ctp-bridge-install.sh — the installer lands the gate at user scope, merges
# settings without clobbering, preserves the config, is idempotent, and the
# INSTALLED wrapper + hook resolve their guard lib from the installed location
# (not the repo) — the property that makes the gate work from the range checkout.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok()   { echo "  OK  $1"; ((PASS++)) || true; }
bad()  { echo " FAIL $1"; ((FAIL++)) || true; }
check(){ if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }

if ! command -v jq >/dev/null 2>&1; then echo "jq required; skipping"; exit 0; fi

HOME_DIR="$(mktemp -d)"
trap 'rm -rf "$HOME_DIR"' EXIT

# a pre-existing user settings.json with an unrelated key + hook, to prove no clobber
mkdir -p "$HOME_DIR/.claude"
cat > "$HOME_DIR/.claude/settings.json" <<'JSON'
{ "mcpServers": { "keep-me": {} },
  "hooks": { "PreToolUse": [ { "matcher": "Write", "hooks": [ { "type": "command", "command": "/pre-existing" } ] } ] } }
JSON

run_install() { HOME="$HOME_DIR" PATH="$PATH" bash "$ROOT/scripts/install-ctp-bridge.sh" >/dev/null 2>&1; }

run_install; check "installer exits 0" "$?" 0

[[ -x "$HOME_DIR/.local/bin/ctp-bridge" ]]              && ok "wrapper installed on PATH location" || bad "wrapper installed"
[[ -f "$HOME_DIR/.local/lib/ctp-bridge/ctp-guard.sh" ]] && ok "guard lib installed"                || bad "guard lib installed"
[[ -x "$HOME_DIR/.claude/hooks/pretooluse-ctp.sh" ]]    && ok "hook installed"                     || bad "hook installed"
[[ -f "$HOME_DIR/.ctp-bridge.conf" ]]                   && ok "config seeded"                      || bad "config seeded"

# settings merged: keeps the unrelated key AND the pre-existing hook AND adds ours
S="$HOME_DIR/.claude/settings.json"
check "kept unrelated mcpServers key" "$(jq -r '.mcpServers["keep-me"] | type' "$S")" object
check "kept pre-existing hook"        "$(jq '[.hooks.PreToolUse[] | select(.hooks[].command=="/pre-existing")] | length' "$S")" 1
HOOK_ABS="$HOME_DIR/.claude/hooks/pretooluse-ctp.sh" \
  check "added our hook (absolute path)" "$(jq --arg h "$HOME_DIR/.claude/hooks/pretooluse-ctp.sh" '[.hooks.PreToolUse[] | select(.hooks[].command==$h)] | length' "$S")" 1
check "our hook matcher covers Write/Edit" "$(jq -r --arg h "$HOME_DIR/.claude/hooks/pretooluse-ctp.sh" '.hooks.PreToolUse[] | select(.hooks[].command==$h) | .matcher' "$S")" "Bash|Read|Write|Edit"

# an older install's matcher is upgraded, not left stale, on re-run
jq --arg h "$HOME_DIR/.claude/hooks/pretooluse-ctp.sh" '(.hooks.PreToolUse[] | select(.hooks[].command==$h) | .matcher) = "Bash|Read"' "$S" > "$S.t" && mv "$S.t" "$S"
run_install
check "stale matcher upgraded on re-install" "$(jq -r --arg h "$HOME_DIR/.claude/hooks/pretooluse-ctp.sh" '.hooks.PreToolUse[] | select(.hooks[].command==$h) | .matcher' "$S")" "Bash|Read|Write|Edit"

# preserve an operator-set target across re-install, and MIGRATE a config that
# predates a required key: CTP_ALLOWED_TEAM must be appended, not left missing.
printf 'CTP_ALLOWED_TARGET=mybox\n' > "$HOME_DIR/.ctp-bridge.conf"   # old-format conf
run_install
check "config preserved on re-install" "$(grep -c '^CTP_ALLOWED_TARGET=mybox' "$HOME_DIR/.ctp-bridge.conf")" 1
check "missing key migrated in (CTP_ALLOWED_TEAM)" "$(grep -c '^CTP_ALLOWED_TEAM=' "$HOME_DIR/.ctp-bridge.conf")" 1
# idempotent: still exactly one of our hook entries
check "hook entry not duplicated" "$(jq --arg h "$HOME_DIR/.claude/hooks/pretooluse-ctp.sh" '[.hooks.PreToolUse[] | select(.hooks[].command==$h)] | length' "$S")" 1

# the INSTALLED wrapper resolves its guard from the installed lib (not the repo):
# a refused verb classifies and exits 3 before any docker call, from a CWD that is
# neither the repo nor $HOME.
( cd /tmp && HOME="$HOME_DIR" bash "$HOME_DIR/.local/bin/ctp-bridge" secrets edit >/dev/null 2>&1 )
check "installed wrapper refuses (guard resolved from install)" "$?" 3

# the INSTALLED hook resolves its guard too: bare ctp -> deny
DEC="$(printf '{"tool_name":"Bash","tool_input":{"command":"ctp host deploy mybox"}}' \
    | HOME="$HOME_DIR" bash "$HOME_DIR/.claude/hooks/pretooluse-ctp.sh" 2>/dev/null \
    | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)"
check "installed hook denies bare ctp (guard resolved from install)" "$DEC" deny

# the installed hook recognises the INSTALLED wrapper name `ctp-bridge` (no .sh),
# not just the repo filename — the real-world gap. update-inventory needs no team.
DEC2="$(printf '{"tool_name":"Bash","tool_input":{"command":"ctp-bridge project update-inventory"}}' \
    | HOME="$HOME_DIR" bash "$HOME_DIR/.claude/hooks/pretooluse-ctp.sh" 2>/dev/null \
    | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)"
check "installed hook asks for the installed 'ctp-bridge' name" "$DEC2" ask

echo ""
echo "Result: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
