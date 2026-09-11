#!/usr/bin/env bash
# test-load-env.sh — precedence rules for .env loading.
#
# Two different questions, easy to conflate, and the second one silently cost a
# real debugging session:
#
#   1. Environment vs file. The real environment always wins, so
#      `FOO=x scripts/whatever.sh` and CI overrides are never overwritten by a
#      committed-ish config file. That rule is deliberate and must not regress.
#
#   2. Duplicate keys WITHIN the file. Appending a corrected value is how people
#      actually edit a .env — and doing so did nothing, because the first
#      assignment won and the later one was skipped. No warning; the stale value
#      just kept being used. The last assignment must win, as it does in a shell
#      and in every other dotenv loader.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok()   { echo "  OK  $1"; ((PASS++)) || true; }
bad()  { echo " FAIL $1"; ((FAIL++)) || true; }
check(){ if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# load-env.sh finds the .env two levels up from its own directory, so give it a
# throwaway tree rather than letting the tests read the repo's real .env.
mkdir -p "$TMP/scripts/lib"
cp "$ROOT/scripts/lib/load-env.sh" "$TMP/scripts/lib/load-env.sh"
LIB="$TMP/scripts/lib/load-env.sh"

# val <env-file-contents> <key> [PRE=SET ...] — load in a clean subshell and
# print what the key ended up as. Uses ${key-...}, not ${key:-...}, so a variable
# deliberately set to empty is reported as empty rather than as unset.
val() {
    local body="$1" key="$2"; shift 2
    printf '%s' "$body" > "$TMP/.env"
    env -i HOME="$HOME" PATH="$PATH" "$@" bash -c \
        "source '$LIB'; printf '%s' \"\${$key-<unset>}\""
}

echo "== basic parsing =="
check "plain KEY=VALUE"        "$(val 'FOO=bar
' FOO)" bar
check "comments ignored"       "$(val '# FOO=commented
FOO=real
' FOO)" real
check "blank lines ignored"    "$(val '

FOO=bar
' FOO)" bar
check "export prefix stripped" "$(val 'export FOO=bar
' FOO)" bar
check "double quotes stripped" "$(val 'FOO="bar baz"
' FOO)" "bar baz"
check "single quotes stripped" "$(val "FOO='bar baz'
" FOO)" "bar baz"
check "trailing comment trimmed" "$(val 'FOO=bar   # a note
' FOO)" bar
check "unset key stays unset"  "$(val 'FOO=bar
' NOPE)" "<unset>"

echo "== the environment always wins =="
check "env beats file"         "$(val 'FOO=fromfile
' FOO FOO=fromenv)" fromenv
# Set-but-empty counts as set: a deliberate blank must not be refilled by the
# file behind the caller's back.
check "empty env var not refilled" "$(val 'FOO=fromfile
' FOO FOO=)" ""

echo "== duplicate keys in the file: the LAST one wins =="
# This is the regression. .env.example ships LOCAL_MODEL_ENDPOINT already set for
# a devcontainer; a host user appends the corrected value, and the appended line
# was silently ignored. The classifier then could not reach a model and failed
# closed, so everything looked "safe" while nothing ever routed.
check "second assignment wins"  "$(val 'FOO=first
FOO=second
' FOO)" second
check "third assignment wins"   "$(val 'FOO=first
FOO=second
FOO=third
' FOO)" third
check "realistic endpoint case" "$(val 'LOCAL_MODEL_ENDPOINT=http://host.docker.internal:11434
OTHER=x
LOCAL_MODEL_ENDPOINT=http://localhost:11434
' LOCAL_MODEL_ENDPOINT)" "http://localhost:11434"
check "other keys unaffected"   "$(val 'FOO=first
FOO=second
BAR=kept
' BAR)" kept
# ...and the environment still beats BOTH copies. Last-wins applies within the
# file only; it must not become a way for a file to overrule the caller.
check "env beats a duplicated file key" "$(val 'FOO=first
FOO=second
' FOO FOO=fromenv)" fromenv

echo
echo "load-env: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
