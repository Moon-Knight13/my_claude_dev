#!/usr/bin/env bash
# test-git-guard.sh — classification tests for the destructive-git gate (2b).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok()   { echo "  OK  $1"; ((PASS++)) || true; }
bad()  { echo " FAIL $1"; ((FAIL++)) || true; }
check(){ if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }

# shellcheck source=scripts/lib/cmd-segment.sh
source "$ROOT/scripts/lib/cmd-segment.sh"
# shellcheck source=scripts/lib/git-guard.sh
source "$ROOT/scripts/lib/git-guard.sh"

dec() { case "$(gitguard_classify "$1")" in ask:*) echo ask ;; deny:*) echo deny ;; *) echo none ;; esac; }

echo "== force-push =="
check "push --force"          "$(dec 'git push --force origin main')"      ask
check "push -f"               "$(dec 'git push -f')"                       ask
check "push --force-with-lease" "$(dec 'git push --force-with-lease')"     ask
check "push (plain)"          "$(dec 'git push origin main')"             none
check "push (bare)"           "$(dec 'git push')"                         none

echo "== reset --hard =="
check "reset --hard"          "$(dec 'git reset --hard HEAD~1')"          ask
check "reset --hard (bare)"   "$(dec 'git reset --hard')"                ask
check "reset --soft"          "$(dec 'git reset --soft HEAD~1')"          none
check "reset (mixed default)" "$(dec 'git reset HEAD file')"              none

echo "== clean =="
check "clean -fdx"            "$(dec 'git clean -fdx')"                   ask
check "clean -fd"            "$(dec 'git clean -fd')"                    ask
check "clean -f"             "$(dec 'git clean -f')"                     ask
check "clean -xdf (reorder)"  "$(dec 'git clean -xdf')"                   ask
check "clean --force"         "$(dec 'git clean --force -d')"             ask
check "clean -n (dry-run)"    "$(dec 'git clean -n')"                     none

echo "== branch -D =="
check "branch -D"             "$(dec 'git branch -D feature')"            ask
check "branch --delete --force" "$(dec 'git branch --delete --force x')"  ask
check "branch -d (safe)"      "$(dec 'git branch -d feature')"            none
check "branch (list)"         "$(dec 'git branch -a')"                    none
check "branch (create)"       "$(dec 'git branch feature')"              none

echo "== checkout/switch --force =="
check "checkout --force"      "$(dec 'git checkout --force main')"        ask
check "checkout -f"           "$(dec 'git checkout -f')"                  ask
check "switch --force"        "$(dec 'git switch --force x')"             ask
check "checkout (plain)"      "$(dec 'git checkout main')"               none

echo "== env prefix + global flags =="
check "env prefix + force"    "$(dec 'GIT_DIR=/x git push --force')"      ask
check "-C repo + force"       "$(dec 'git -C /repo push --force')"        ask
check "-c cfg + commit"       "$(dec 'git -c user.name=x commit -m msg')" none

echo "== not git / data (no false positives) =="
check "status"               "$(dec 'git status')"                       none
check "commit msg mentions reset --hard" "$(dec "git commit -m 'reset --hard now'")" none
check "echo of a force push"  "$(dec 'echo git push --force')"           none
check "grep for force push"   "$(dec "grep -r 'git push --force' .")"     none
check "diff/log"             "$(dec 'git log --oneline')"                none

echo "== allow-list exemption =="
_cfg="$(mktemp)"; trap 'rm -f "$_cfg"' EXIT
echo 'GITGUARD_ALLOWLIST=force-push' > "$_cfg"
gitguard_load_config "$_cfg"
check "force-push exempted -> none" "$(dec 'git push --force')"           none
check "reset-hard still gated"      "$(dec 'git reset --hard')"           ask

echo
echo "git-guard: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
