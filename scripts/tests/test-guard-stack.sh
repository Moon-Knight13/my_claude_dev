#!/usr/bin/env bash
# test-guard-stack.sh — contract tests for the composed guard stack.
#
# The stack is the SINGLE policy shared by two enforcement points: the PreToolUse
# hook (fronting Claude's tools) and the local-model executor (which does not go
# through Claude and so does not inherit that hook). These tests pin the public
# contract both callers depend on:
#   - the verdict shape ("" | ask:<reason> | deny:<reason>) returned by GLOBAL
#   - the caller-mode parameter, and that C1 is the ONLY layer that varies by it
#   - the approval argv side channel
# The hook's end-to-end behaviour is covered by test-ctp-bridge.sh; this file
# covers the library directly, including the executor mode that has no hook path.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok()   { echo "  OK  $1"; ((PASS++)) || true; }
bad()  { echo " FAIL $1"; ((FAIL++)) || true; }
check(){ if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
CONF="$TMP/ctp.conf"
cat > "$CONF" <<EOF
CTP_CONTAINER=catapult-test
CTP_SECRET_PATHS=/var/tmp/vlt_pf ~/.ssh/**
CTP_PII_PATHS=~/org-data/** /srv/customer/**
EOF
export CTP_BRIDGE_CONF="$CONF"
export CTP_BRIDGE_STATE="$TMP/state"
export HOME=/home/tester

# shellcheck source=scripts/lib/guard-stack.sh disable=SC1091
source "$ROOT/scripts/lib/guard-stack.sh"

# kind <verdict-global> — reduce a verdict to its decision word
kind() { case "$GUARD_STACK_VERDICT" in ask:*) echo ask ;; deny:*) echo deny ;; "") echo none ;; *) echo malformed ;; esac; }
cmd()  { guard_stack_classify_command "$1"; kind; }
pth()  { guard_stack_classify_path "$1";    kind; }

# want <description> <condition-result-rc> — rc 0 passes
want() { if [[ "$1" == 0 ]]; then ok "$2"; else bad "$2"; fi; }

echo "== load contract =="
guard_stack_load hook;     want "$?" "load hook mode"
guard_stack_load executor; want "$?" "load executor mode"
guard_stack_load nonsense; check "unknown mode rejected" "$?" 2
guard_stack_load;          want "$?" "default mode loads"
check "default mode is hook" "$GUARD_STACK_MODE" hook

# ---------------------------------------------------------------------------
echo "== C1 PII paths: the ONE layer that varies by mode =="
guard_stack_load hook
check "hook: PII path (Read) -> deny"      "$(pth '/home/tester/org-data/pii.csv')"        deny
check "hook: PII path (Bash) -> deny"      "$(cmd 'cat /home/tester/org-data/pii.csv')"    deny
check "hook: PII glob dir -> deny"         "$(pth '/srv/customer/acme/notes.md')"          deny
guard_stack_load executor
check "executor: PII path (Read) -> none"  "$(pth '/home/tester/org-data/pii.csv')"        none
check "executor: PII path (Bash) -> none"  "$(cmd 'cat /home/tester/org-data/pii.csv')"    none
check "executor: PII glob dir -> none"     "$(pth '/srv/customer/acme/notes.md')"          none

echo "== secret paths: denied in BOTH modes (reading Org data is the job; credentials are not) =="
for m in hook executor; do
    guard_stack_load "$m"
    check "$m: vault file (Read) -> deny"  "$(pth '/var/tmp/vlt_pf')"                      deny
    check "$m: ssh key (Read) -> deny"     "$(pth '/home/tester/.ssh/id_ed25519')"         deny
    check "$m: vault via Bash -> deny"     "$(cmd 'cat /var/tmp/vlt_pf')"                  deny
done

echo "== every other layer is mode-INVARIANT =="
for m in hook executor; do
    guard_stack_load "$m"
    check "$m: bare ctp -> deny"           "$(cmd 'ctp host deploy box')"                  deny
    check "$m: docker exec bypass -> deny" "$(cmd 'docker exec catapult-test zsh -c ctp')" deny
    check "$m: make start -> deny"         "$(cmd 'make start')"                           deny
    check "$m: rm -rf -> ask"              "$(cmd 'rm -rf /data')"                         ask
    check "$m: terraform destroy -> ask"   "$(cmd 'terraform destroy')"                    ask
    check "$m: git push --force -> ask"    "$(cmd 'git push --force origin main')"         ask
    check "$m: git clean -f -> ask"        "$(cmd 'git clean -fd')"                        ask
    check "$m: benign -> none"             "$(cmd 'ls -la && git status')"                 none
    check "$m: commit msg not a command"   "$(cmd 'git commit -m "drop the users table"')" none
done

# ---------------------------------------------------------------------------
echo "== verdict shape =="
guard_stack_load hook
guard_stack_classify_command 'rm -rf /data'
if [[ "$GUARD_STACK_VERDICT" == ask:*[![:space:]]* ]]; then ok "ask carries a non-empty reason"; else bad "ask reason empty"; fi
guard_stack_classify_command 'ctp host deploy box'
if [[ "$GUARD_STACK_VERDICT" == deny:*[![:space:]]* ]]; then ok "deny carries a non-empty reason"; else bad "deny reason empty"; fi
guard_stack_classify_command 'ls -la'
if [[ -z "$GUARD_STACK_VERDICT" ]]; then ok "no opinion is the empty string"; else bad "no opinion not empty"; fi
guard_stack_classify_command ''
if [[ -z "$GUARD_STACK_VERDICT" ]]; then ok "empty command -> no opinion"; else bad "empty command"; fi
guard_stack_classify_path ''
if [[ -z "$GUARD_STACK_VERDICT" ]]; then ok "empty path -> no opinion"; else bad "empty path"; fi

# Regression guard: _split_segments appends to _SEGMENTS, so without a per-call
# reset the SECOND classification in a process re-judges the FIRST call's segments
# and returns its verdict. Invisible to the one-shot hook; fatal for the executor,
# which classifies every command in a loop.
echo "== verdict is reset between calls (no stale carry-over) =="
guard_stack_classify_command 'rm -rf /data'
guard_stack_classify_command 'ls -la'
if [[ -z "$GUARD_STACK_VERDICT" ]]; then ok "command verdict reset"; else bad "stale command verdict"; fi
guard_stack_classify_command 'ctp host deploy box'
guard_stack_classify_command 'echo hello'
if [[ -z "$GUARD_STACK_VERDICT" ]]; then ok "deny does not leak into next call"; else bad "stale deny verdict"; fi
guard_stack_classify_command 'ls -la'
guard_stack_classify_command 'rm -rf /data'
if [[ "$GUARD_STACK_VERDICT" == ask:* ]]; then ok "later call still gated after a benign one"; else bad "gate lost after benign call"; fi
guard_stack_classify_path '/var/tmp/vlt_pf'
guard_stack_classify_path '/workspace/README.md'
if [[ -z "$GUARD_STACK_VERDICT" ]]; then ok "path verdict reset"; else bad "stale path verdict"; fi

echo "== approval argv side channel =="
guard_stack_classify_command 'scripts/ctp-bridge.sh project update-inventory'
check "wrapper ask sets argv"   "${GUARD_STACK_APPROVAL_ARGV[*]:-}" "project update-inventory"
guard_stack_classify_command 'scripts/ctp-bridge.sh project update-inventory 2>&1'
check "argv strips redirection" "${GUARD_STACK_APPROVAL_ARGV[*]:-}" "project update-inventory"
guard_stack_classify_command 'rm -rf /data'
check "non-wrapper ask: no argv" "${#GUARD_STACK_APPROVAL_ARGV[@]}" 0
guard_stack_classify_command 'ls -la'
check "no opinion: no argv"      "${#GUARD_STACK_APPROVAL_ARGV[@]}" 0

echo "== segmentation is used, not raw string matching =="
guard_stack_load hook
check "rm inside a quoted string" "$(cmd 'echo "rm -rf /x"')"                 none
# shellcheck disable=SC2016  # the $(...) is intentional literal test data
check "rm in a subshell IS gated" "$(cmd 'echo "$(rm -rf /x)"')"              ask
check "env prefix does not hide"  "$(cmd 'GIT_DIR=/x git clean -f')"          ask
check "second segment gated (ask)"  "$(cmd 'ls; dropdb prod')"                ask
check "second segment gated (deny)" "$(cmd 'ls; ctp host deploy box')"        deny

echo
echo "guard-stack: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
