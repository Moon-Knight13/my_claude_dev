#!/usr/bin/env bash
# run-all.sh — run every scripts/tests/test-*.sh suite and report per suite.
#
# Used by CI (.github/workflows/tests.yml) and by hand. Each suite runs in its own
# process with a timeout; a suite passes when it exits 0. Output of failing suites
# is printed in full so the CI log shows why.
#
# Known failures: scripts/tests/known-failures.txt lists suites that fail for a
# tracked reason (one per line: `<suite> <issue-ref> <reason>`). They still run
# and are reported, but do not fail the run. If a listed suite PASSES, the run
# says so loudly so the stale entry gets removed. Anything not listed that fails
# makes the run fail.
#
# Transports: the local-model API under test is passed through as
# LOCAL_MODEL_API (default: ollama). CI runs this script once per transport in a
# matrix: `ollama` (Ollama mock) and `openai` (llama-server mock through
# fleet_call, scripts/tests/mock-llama-server.py). Suites with a transport
# branch (test-classifier.sh) pick their leg from it; suites for Ollama-only
# legacy scripts run the same way in both legs.
#
# Usage: bash scripts/tests/run-all.sh [suite-name-substring ...]
# Env:   TESTS_DIR (default: this directory), SUITE_TIMEOUT (seconds, default 300),
#        KNOWN_FAILURES (default: $TESTS_DIR/known-failures.txt)
# Exit:  0 all suites passed or known-failing; 1 any unexpected failure.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="${TESTS_DIR:-$HERE}"
SUITE_TIMEOUT="${SUITE_TIMEOUT:-300}"
KNOWN_FAILURES="${KNOWN_FAILURES:-$TESTS_DIR/known-failures.txt}"
export LOCAL_MODEL_API="${LOCAL_MODEL_API:-ollama}"

known_ref() { # known_ref <suite> -> prints "<issue-ref> <reason>" if listed
    [[ -f "$KNOWN_FAILURES" ]] || return 1
    awk -v s="$1" '$1==s { $1=""; sub(/^ /,""); print; found=1 } END { exit !found }' \
        <(grep -vE '^[[:space:]]*(#|$)' "$KNOWN_FAILURES")
}

summary() { [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && printf '%s\n' "$1" >> "$GITHUB_STEP_SUMMARY"; return 0; }

shopt -s nullglob
suites=("$TESTS_DIR"/test-*.sh)
if (( $# > 0 )); then
    filtered=()
    for s in "${suites[@]}"; do
        for f in "$@"; do [[ "$(basename "$s")" == *"$f"* ]] && { filtered+=("$s"); break; }; done
    done
    suites=("${filtered[@]}")
fi
(( ${#suites[@]} > 0 )) || { echo "run-all: no suites matched in $TESTS_DIR" >&2; exit 1; }

echo "run-all: ${#suites[@]} suite(s), LOCAL_MODEL_API=$LOCAL_MODEL_API, timeout ${SUITE_TIMEOUT}s each"
summary "### scripts/tests — LOCAL_MODEL_API=$LOCAL_MODEL_API"
summary ""
summary "| Suite | Result | Time |"
summary "|---|---|---|"

pass=0; fail=0; known=0; stale=0
for s in "${suites[@]}"; do
    name="$(basename "$s")"
    start=$(date +%s)
    out="$(timeout "$SUITE_TIMEOUT" bash "$s" 2>&1)"; rc=$?
    secs=$(( $(date +%s) - start ))
    if ref="$(known_ref "$name")"; then
        if (( rc == 0 )); then
            stale=$((stale + 1))
            printf '  !!  %-34s passed but is listed as a known failure (%s) — remove it from %s\n' \
                "$name" "$ref" "$(basename "$KNOWN_FAILURES")"
            summary "| \`$name\` | ⚠️ passes — remove known-failure entry ($ref) | ${secs}s |"
        else
            known=$((known + 1))
            printf '  --  %-34s known failure (%s), rc=%s, %ss\n' "$name" "$ref" "$rc" "$secs"
            summary "| \`$name\` | known failure ($ref) | ${secs}s |"
        fi
        continue
    fi
    if (( rc == 0 )); then
        pass=$((pass + 1))
        printf '  OK  %-34s %ss\n' "$name" "$secs"
        summary "| \`$name\` | ✅ pass | ${secs}s |"
    else
        fail=$((fail + 1))
        (( rc == 124 )) && why="timed out after ${SUITE_TIMEOUT}s" || why="rc=$rc"
        printf ' FAIL %-34s %s, %ss\n' "$name" "$why" "$secs"
        summary "| \`$name\` | ❌ FAIL ($why) | ${secs}s |"
        if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
            echo "::group::$name output"; printf '%s\n' "$out"; echo "::endgroup::"
            echo "::error title=$name failed::$why (LOCAL_MODEL_API=$LOCAL_MODEL_API)"
        else
            printf '%s\n' "$out" | sed 's/^/        /'
        fi
    fi
done

echo
echo "run-all: $pass passed, $fail failed, $known known failure(s), $stale stale known-failure entr(y/ies)"
summary ""
summary "**$pass passed, $fail failed, $known known failure(s), $stale stale entr(y/ies)**"
(( fail == 0 ))
