#!/usr/bin/env bash
# test-ctp-bridge-config.sh — tests for ctp_resolve_conf() fallback chain.
#
# Verifies that .ctp-bridge.conf is found from worktrees via the git-common-dir
# fallback, and that the priority order is correct.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok()   { echo "  OK  $1"; ((PASS++)) || true; }
bad()  { echo " FAIL $1"; ((FAIL++)) || true; }
check(){ if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ORIG_HOME="$HOME"
ORIG_PWD="$PWD"

# shellcheck source=/dev/null
source "$ROOT/scripts/lib/ctp-guard.sh"

# ============================================================================
echo "== ctp_resolve_conf: fallback chain =="

# --- env override wins -------------------------------------------------------
FAKE_CONF="$TMP/env-override.conf"
touch "$FAKE_CONF"
check "env override returns CTP_BRIDGE_CONF" \
    "$(CTP_BRIDGE_CONF="$FAKE_CONF" ctp_resolve_conf)" "$FAKE_CONF"

# --- PWD fallback ------------------------------------------------------------
mkdir -p "$TMP/pwd-test"
touch "$TMP/pwd-test/.ctp-bridge.conf"
unset CTP_BRIDGE_CONF
cd "$TMP/pwd-test" || exit
check "PWD fallback" "$(ctp_resolve_conf)" "$TMP/pwd-test/.ctp-bridge.conf"
cd "$ORIG_PWD" || exit

# --- git toplevel fallback ---------------------------------------------------
REPO="$TMP/repo-toplevel"
mkdir -p "$REPO/sub"
( cd "$REPO" && git init -q && touch .ctp-bridge.conf ) >/dev/null 2>&1
unset CTP_BRIDGE_CONF
cd "$REPO/sub" || exit
check "git toplevel fallback" "$(ctp_resolve_conf)" "$REPO/.ctp-bridge.conf"
cd "$ORIG_PWD" || exit

# --- git-common-dir fallback (worktree simulation) ---------------------------
MAIN="$TMP/main-repo"
WT="$TMP/worktree"
mkdir -p "$MAIN"
( cd "$MAIN" && git init -q && git config user.email "test@test" && git config user.name "test" && git commit --allow-empty -m "init" -q && touch .ctp-bridge.conf && git worktree add -q "$WT" -b test-wt HEAD ) >/dev/null 2>&1
unset CTP_BRIDGE_CONF
cd "$WT" || exit
check "git-common-dir fallback (worktree)" "$(ctp_resolve_conf)" "$MAIN/.ctp-bridge.conf"
cd "$ORIG_PWD" || exit

# --- CLAUDE_PROJECT_DIR fallback ---------------------------------------------
PROJECT="$TMP/claude-project"
mkdir -p "$PROJECT"
touch "$PROJECT/.ctp-bridge.conf"
unset CTP_BRIDGE_CONF
cd "$TMP" || exit  # no config, no git
check "CLAUDE_PROJECT_DIR fallback" \
    "$(CLAUDE_PROJECT_DIR="$PROJECT" ctp_resolve_conf)" "$PROJECT/.ctp-bridge.conf"
cd "$ORIG_PWD" || exit

# --- HOME fallback -----------------------------------------------------------
FAKE_HOME="$TMP/fake-home"
mkdir -p "$FAKE_HOME"
touch "$FAKE_HOME/.ctp-bridge.conf"
unset CTP_BRIDGE_CONF
unset CLAUDE_PROJECT_DIR 2>/dev/null || true
export HOME="$FAKE_HOME"
cd "$TMP" || exit  # no config, no git
check "HOME fallback" "$(ctp_resolve_conf)" "$FAKE_HOME/.ctp-bridge.conf"
export HOME="$ORIG_HOME"
cd "$ORIG_PWD" || exit

# --- none found → returns 1 -------------------------------------------------
unset CTP_BRIDGE_CONF
unset CLAUDE_PROJECT_DIR 2>/dev/null || true
export HOME="$TMP/no-home"
cd "$TMP" || exit
if ctp_resolve_conf >/dev/null 2>&1; then bad "no config should fail"; else ok "no config returns 1"; fi
export HOME="$ORIG_HOME"
cd "$ORIG_PWD" || exit

# --- priority: PWD over git toplevel -----------------------------------------
PRIO="$TMP/prio-repo"
mkdir -p "$PRIO/sub"
( cd "$PRIO" && git init -q && echo "# root" > .ctp-bridge.conf && echo "# sub" > sub/.ctp-bridge.conf ) >/dev/null 2>&1
unset CTP_BRIDGE_CONF
cd "$PRIO/sub" || exit
check "PWD wins over git toplevel" "$(ctp_resolve_conf)" "$PRIO/sub/.ctp-bridge.conf"
cd "$ORIG_PWD" || exit

# ============================================================================
echo
echo "config resolution: $PASS passed, $FAIL failed"
exit "$FAIL"
