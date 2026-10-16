#!/usr/bin/env bash
# Self-test for scripts/tests/run-all.sh (issue #88): a broken suite must make the
# run fail; a listed known failure must not; a listed suite that now passes must be
# flagged as stale; LOCAL_MODEL_API must reach the suites. Uses throwaway fixture
# suites in a temp dir — it never runs the real suites, so it cannot recurse.
#
# Usage: bash scripts/tests/test-run-all.sh
# Exit: 0 pass, non-zero = number of failures.
# shellcheck disable=SC2015  # `cond && ok || bad` is intentional: ok() never fails
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$HERE/run-all.sh"
fails=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fails=$((fails + 1)); }

mk() { # mk <dir> <name> <exit-code>
    mkdir -p "$1"
    printf '#!/usr/bin/env bash\necho "fixture %s"\nexit %s\n' "$2" "$3" > "$1/$2"
}
run() { # run <dir> [known-file] -> sets OUT RC
    OUT="$(TESTS_DIR="$1" KNOWN_FAILURES="${2:-$1/none.txt}" GITHUB_STEP_SUMMARY='' GITHUB_ACTIONS='' \
        bash "$RUNNER" 2>&1)"
    RC=$?
}

# 1. All suites pass -> exit 0
mk "$TMP/green" test-a.sh 0; mk "$TMP/green" test-b.sh 0
run "$TMP/green"
[[ $RC -eq 0 && "$OUT" == *"2 passed, 0 failed"* ]] && ok "all green -> exit 0" || bad "all green -> exit 0 (rc=$RC)"

# 2. One deliberately broken suite -> run fails and names it
mk "$TMP/red" test-ok.sh 0; mk "$TMP/red" test-broken.sh 1
run "$TMP/red"
[[ $RC -ne 0 ]] && ok "broken suite -> non-zero exit" || bad "broken suite -> non-zero exit"
[[ "$OUT" == *"FAIL test-broken.sh"* ]] && ok "broken suite is named" || bad "broken suite is named"

# 3. Listed known failure -> reported, run still passes
mk "$TMP/known" test-ok.sh 0; mk "$TMP/known" test-flaky.sh 1
printf '# comment\n\ntest-flaky.sh #999 tracked reason\n' > "$TMP/known/kf.txt"
run "$TMP/known" "$TMP/known/kf.txt"
[[ $RC -eq 0 && "$OUT" == *"known failure (#999 tracked reason)"* ]] && ok "known failure -> reported, exit 0" \
    || bad "known failure -> reported, exit 0 (rc=$RC)"

# 4. Listed suite that now passes -> flagged stale, run still passes
mk "$TMP/stale" test-fixed.sh 0
printf 'test-fixed.sh #998 was broken\n' > "$TMP/stale/kf.txt"
run "$TMP/stale" "$TMP/stale/kf.txt"
[[ $RC -eq 0 && "$OUT" == *"passed but is listed as a known failure"* ]] && ok "stale known-failure entry flagged" \
    || bad "stale known-failure entry flagged (rc=$RC)"

# 5. A broken suite NOT on the list still fails even when the list exists
mk "$TMP/mixed" test-flaky.sh 1; mk "$TMP/mixed" test-new-break.sh 1
printf 'test-flaky.sh #999 tracked\n' > "$TMP/mixed/kf.txt"
run "$TMP/mixed" "$TMP/mixed/kf.txt"
[[ $RC -ne 0 && "$OUT" == *"FAIL test-new-break.sh"* ]] && ok "unlisted failure still fails the run" \
    || bad "unlisted failure still fails the run (rc=$RC)"

# 6. LOCAL_MODEL_API reaches the suites (future transport matrix)
mkdir -p "$TMP/api"
# shellcheck disable=SC2016  # literal $ written into the fixture
printf '#!/usr/bin/env bash\n[[ "$LOCAL_MODEL_API" == openai ]]\n' > "$TMP/api/test-api.sh"
OUT="$(TESTS_DIR="$TMP/api" KNOWN_FAILURES=/dev/null LOCAL_MODEL_API=openai GITHUB_STEP_SUMMARY='' GITHUB_ACTIONS='' \
    bash "$RUNNER" 2>&1)"; RC=$?
[[ $RC -eq 0 ]] && ok "LOCAL_MODEL_API passed through to suites" || bad "LOCAL_MODEL_API passed through to suites"

# 7. A hanging suite times out and fails
mkdir -p "$TMP/hang"; printf '#!/usr/bin/env bash\nsleep 30\n' > "$TMP/hang/test-hang.sh"
OUT="$(TESTS_DIR="$TMP/hang" KNOWN_FAILURES=/dev/null SUITE_TIMEOUT=1 GITHUB_STEP_SUMMARY='' GITHUB_ACTIONS='' \
    bash "$RUNNER" 2>&1)"; RC=$?
[[ $RC -ne 0 && "$OUT" == *"timed out after 1s"* ]] && ok "hanging suite times out and fails" \
    || bad "hanging suite times out and fails (rc=$RC)"

echo
if (( fails == 0 )); then echo "run-all self-test: all passed."; else echo "$fails failure(s)."; fi
exit "$fails"
