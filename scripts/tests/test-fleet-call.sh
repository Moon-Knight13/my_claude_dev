#!/usr/bin/env bash
# `cond && ok … || bad …` is safe in this file: ok and bad always return 0.
# shellcheck disable=SC2015,SC2016
# test-fleet-call.sh — the one model-call client fleet_call (SP1a story 1.3,
# #99; AD-10, FR-12, FR-17, FR-18, NFR-2, NFR-3).
# tier: ci — the model is scripts/tests/mock-llama-server.py on loopback or a
# unix socket; no real model, GPU, or network.
#
# Pins: the call sequence (/health, /props, /apply-template, /tokenize, fit
# check, /v1/chat/completions) and its output; every fault (loading, non-200,
# timeout, unreachable, no n_ctx, template or tokenize failure, fit, server
# oversize, input too big, malformed, truncated, empty, extra field, non-enum,
# completion timeout) exits >= 4 with no retry and, before the completion step,
# no completion request; endpoint policy (loopback or hub socket only, missing
# endpoint, nothing from the environment) with no network call; the pinned
# classifier settings; determinism (same input + settings -> same request
# body); the input never on any spawned process's argv; and the AD-10 lint over
# the repo with its named exemptions.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="$ROOT/scripts/lib/fleet.sh"
SETTINGS="$ROOT/scripts/hub/fleet/classifier.settings.json"
MOCK="$ROOT/scripts/tests/mock-llama-server.py"
PASS=0; FAIL=0
ok()   { echo "  OK  $1"; ((PASS++)) || true; }
bad()  { echo " FAIL $1"; ((FAIL++)) || true; }
check(){ if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }
fault(){ (( $2 >= 4 )) && ok "$1 (exit $2)" || bad "$1 (exit $2, want >= 4)"; }

for b in python3 jq curl; do
    command -v "$b" >/dev/null || { echo " FAIL $b not installed"; exit 1; }
done

TMP="$(mktemp -d)"
PIDS=()
cleanup() { local p; for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; rm -rf "$TMP"; }
trap cleanup EXIT

# --- mocks -------------------------------------------------------------------
MS="$TMP/mock"; mkdir -p "$MS"
MOCK_STATE_DIR="$MS" python3 "$MOCK" & PIDS+=($!)
for _ in $(seq 50); do [[ -s "$MS/port" ]] && break; sleep 0.1; done
PORT="$(cat "$MS/port" 2>/dev/null)"
[[ -n "$PORT" ]] || { echo " FAIL mock did not start"; exit 1; }

SOCKDIR="$TMP/sock"; mkdir -p "$SOCKDIR"; MSU="$TMP/mock-unix"; mkdir -p "$MSU"
MOCK_STATE_DIR="$MSU" MOCK_UNIX="$SOCKDIR/classifier.sock" python3 "$MOCK" & PIDS+=($!)
for _ in $(seq 50); do [[ -S "$SOCKDIR/classifier.sock" ]] && break; sleep 0.1; done

# A port with nothing listening: bind, read the number, release it.
DEAD="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"

mode()    { printf '%s' "$1" > "$MS/mode"; }
content() { printf '%s' "$1" > "$MS/content"; }
reset()   { mode ok; rm -f "$MS/content" "$MS/nctx"; : > "$MS/requests.jsonl"; }
paths()   { jq -r '"\(.method) \(.path)"' "$MS/requests.jsonl" 2>/dev/null | tr '\n' ',' ; }
completions() { grep -c '"/v1/chat/completions"' "$MS/requests.jsonl" 2>/dev/null || true; }

# --- argv logging: every command fleet_call spawns, wrapped ------------------
# Each wrapper logs its argv and execs the real binary, so the test can prove
# the input text never reaches a process's arguments.
WRAP="$TMP/bin"; mkdir -p "$WRAP"
ARGV_LOG="$TMP/argv.log"; export ARGV_LOG
for c in curl jq head iconv tr wc cat mktemp rm; do
    real="$(command -v "$c")" || continue
    printf '#!/usr/bin/env bash\nprintf "%%s %%s\\n" %q "$*" >> "$ARGV_LOG"\nexec %q "$@"\n' "$c" "$real" > "$WRAP/$c"
    chmod +x "$WRAP/$c"
done
netcalls() { grep -c '^curl ' "$ARGV_LOG" 2>/dev/null || true; }

CONF="$TMP/fleet.conf"
writeconf() { printf '%s\n' "FLEET_PROBE_TIMEOUT=1" "FLEET_SOCKET_DIR=$SOCKDIR" "$@" > "$CONF"; }
goodconf()  { writeconf "FLEET_CLASSIFIER_ENDPOINT=http://127.0.0.1:$PORT" "FLEET_CLASSIFIER_MODEL=clf-test" "$@"; }

# fc <input> [member] [settings] [sysfile] — run fleet_call as a caller would.
fc() {
    local input="$1" member="${2:-classifier}" settings="${3:-$SETTINGS}" sys="${4:-}"
    : > "$ARGV_LOG"
    local -a extra=(); [[ -n "$sys" ]] && extra=("$sys")
    OUT="$(printf '%s' "$input" | PATH="$WRAP:$PATH" bash -c \
        'source "$1"; fleet_use_config "$2"; shift 2; fleet_call "$@"' _ "$LIB" "$CONF" \
        "$member" "$settings" "${extra[@]}" 2>"$TMP/err")"
    RC=$?
}

SYS="$TMP/system.md"; printf 'You are a test classifier.\n' > "$SYS"

# =============================================================================
echo "== sequence =="
reset; goodconf
fc "ZZINPUT benign refactor" classifier "$SETTINGS" "$SYS"
check "valid call exits 0" "$RC" 0
check "output is the validated JSON verdict" "$OUT" '{"verdict":"nonsensitive"}'
check "steps in order" "$(paths)" \
    "GET /health,GET /props,POST /apply-template,POST /tokenize,POST /v1/chat/completions,"
REQ="$(jq -r 'select(.path == "/v1/chat/completions") | .body' "$MS/requests.jsonl")"
check "request: temperature 0"   "$(jq -c .temperature <<<"$REQ")" 0
check "request: fixed seed"      "$(jq -c .seed <<<"$REQ")" "$(jq -c .params.seed "$SETTINGS")"
check "request: pinned max_tokens" "$(jq -c .max_tokens <<<"$REQ")" "$(jq -c .max_tokens "$SETTINGS")"
check "request: json_schema enum" \
    "$(jq -c '.response_format | [.type, .json_schema.schema.properties.verdict.enum]' <<<"$REQ")" \
    '["json_schema",["sensitive","nonsensitive"]]'
check "request: cache and slot settings from the file" \
    "$(jq -c '[.cache_prompt, .id_slot]' <<<"$REQ")" "$(jq -c '[.params.cache_prompt, .params.id_slot]' "$SETTINGS")"
check "request: model alias from fleet config" "$(jq -r .model <<<"$REQ")" clf-test
check "request: not streamed" "$(jq -c .stream <<<"$REQ")" false
check "request: system then user message" "$(jq -c '[.messages[].role]' <<<"$REQ")" '["system","user"]'
check "request: input carried verbatim" "$(jq -r '.messages[1].content' <<<"$REQ")" "ZZINPUT benign refactor"
TOK="$(jq -r 'select(.path == "/tokenize") | .body' "$MS/requests.jsonl")"
check "tokenize counts the templated prompt" \
    "$(jq -r '.content | startswith("<|system|>")' <<<"$TOK")" true
reset; fc "no system prompt"
check "call without a system prompt exits 0" "$RC" 0
check "only a user message" \
    "$(jq -r 'select(.path == "/v1/chat/completions") | .body | fromjson | [.messages[].role] | join(",")' "$MS/requests.jsonl")" user
reset; content "sensitive draft text"
fc "x" classifier "$ROOT/scripts/hub/fleet/draft.settings.json"
check "text settings: raw content returned" "$OUT" "sensitive draft text"

echo "== unix socket endpoint =="
writeconf "FLEET_CLASSIFIER_ENDPOINT=unix:$SOCKDIR/classifier.sock" "FLEET_CLASSIFIER_MODEL=clf-test"
fc "over the socket"
check "hub unix socket call exits 0" "$RC" 0
check "socket mock served the completion" "$(grep -c '/v1/chat/completions' "$MSU/requests.jsonl" 2>/dev/null)" 1

echo "== determinism =="
reset; goodconf
fc "ZZSAME input"; fc "ZZSAME input"
B="$(jq -c 'select(.path == "/v1/chat/completions") | .body | fromjson' "$MS/requests.jsonl")"
check "two completion requests captured" "$(wc -l <<<"$B" | tr -d ' ')" 2
check "same input + settings -> same request body" "$(sed -n 1p <<<"$B")" "$(sed -n 2p <<<"$B")"

echo "== input never on argv =="
reset; goodconf
fc "ZZARGVMARKER-$RANDOM private text" classifier "$SETTINGS" "$SYS"
check "call succeeded" "$RC" 0
[[ -s "$ARGV_LOG" ]] && ok "spawned processes were logged ($(wc -l < "$ARGV_LOG" | tr -d ' '))" || bad "argv log empty"
grep -q ZZARGVMARKER "$ARGV_LOG" && bad "INPUT TEXT ON ARGV" || ok "input text on no process's argv"
grep -q ZZARGVMARKER "$MS/requests.jsonl" && ok "input text reached the model in the body" || bad "input not sent"
grep -q 'test classifier' "$ARGV_LOG" && bad "system prompt on argv" || ok "system prompt on no process's argv"

# =============================================================================
echo "== endpoint faults: no completion request =="
goodconf
for m in loading health500 hang-health noctx template-fail tokenize-fail toolong; do
    reset; mode "$m"; fc "x"
    fault "$m is a fault" "$RC"
    check "$m: no completion request" "$(completions)" 0
done
check "loading: exit 5 (endpoint)" "$( reset; mode loading; fc x; echo "$RC")" 5
check "fit check failure: exit 6" "$( reset; mode toolong; fc x; echo "$RC")" 6
reset; printf '35' > "$MS/nctx"; fc "x"
check "max_tokens counts toward the fit (prompt ~6 tokens fits n_ctx 35, + 32 does not)" "$RC" 6
check "fit failure: no completion request" "$(completions)" 0

writeconf "FLEET_CLASSIFIER_ENDPOINT=http://127.0.0.1:$DEAD" "FLEET_CLASSIFIER_MODEL=clf-test"
fc "x"; fault "unreachable endpoint is a fault" "$RC"

echo "== completion faults: one request, never retried =="
goodconf
for m in oversize malformed truncated timeout; do
    reset; mode "$m"
    if [[ "$m" == timeout ]]; then
        jq '.timeout_seconds = 1' "$SETTINGS" > "$TMP/s-timeout.json"; fc "x" classifier "$TMP/s-timeout.json"
    else
        fc "x"
    fi
    fault "$m is a fault" "$RC"
    check "$m: exactly one completion request (no retry)" "$(completions)" 1
    check "$m: nothing on stdout" "$OUT" ""
done
check "server exceed_context_size_error: exit 6" "$( reset; mode oversize; fc x; echo "$RC")" 6
check "truncated (length): exit 7" "$( reset; mode truncated; fc x; echo "$RC")" 7

echo "== reply faults =="
declare -A BAD=(
    [empty]=''
    [whitespace]='   '
    [partial]='{"verdict":"sensitive"'
    [extra-field]='{"verdict":"sensitive","why":"x"}'
    [non-enum]='{"verdict":"maybe"}'
    [wrong-key]='{"label":"sensitive"}'
    [two-objects]='{"verdict":"sensitive"}{"verdict":"sensitive"}'
    [bare-word]='nonsensitive'
    [array]='[{"verdict":"nonsensitive"}]'
    [trailing-text]='{"verdict":"nonsensitive"} ok'
)
for k in "${!BAD[@]}"; do
    reset; content "${BAD[$k]}"; fc "x"
    fault "reply $k is a fault" "$RC"
    check "reply $k: nothing on stdout" "$OUT" ""
done
reset; content '{"verdict":"sensitive"}'; fc "x"
check "a sensitive verdict is returned as is" "$OUT" '{"verdict":"sensitive"}'

echo "== input faults: no network call =="
goodconf
fc ""; fault "empty input is a fault" "$RC"; check "empty input: no network call" "$(netcalls)" 0
goodconf "FLEET_MAX_INPUT_BYTES=16"
fc "this input is longer than sixteen bytes"
check "input over the limit: exit 6, not truncated" "$RC" 6
check "input over the limit: no network call" "$(netcalls)" 0
goodconf
fc "$(printf 'bad \xff\xfe utf8')"; fault "invalid UTF-8 is a fault" "$RC"
check "invalid UTF-8: no network call" "$(netcalls)" 0

echo "== endpoint policy: no network call =="
for ep in "http://192.0.2.10:8080" "https://127.0.0.1:$PORT" "http://localhost:$PORT" \
          "http://127.0.0.1" "http://user@127.0.0.1:$PORT" "http://127.0.0.1:$PORT/v1" \
          "http://127.0.0.1.example.test:$PORT" "http://127.0.0.300:$PORT" "http://127.0.0.1:0" \
          "unix:/tmp/elsewhere.sock" "unix:$SOCKDIR/../classifier.sock" "unix:relative.sock" "ftp://127.0.0.1:21"; do
    writeconf "FLEET_CLASSIFIER_ENDPOINT=$ep" "FLEET_CLASSIFIER_MODEL=clf-test"
    fc "x"
    fault "endpoint refused: $ep" "$RC"
    check "no network call for $ep" "$(netcalls)" 0
done
writeconf "FLEET_CLASSIFIER_MODEL=clf-test"
fc "x"; fault "missing endpoint setting" "$RC"; check "missing endpoint: no network call" "$(netcalls)" 0
writeconf "FLEET_CLASSIFIER_ENDPOINT=http://127.0.0.1:$PORT"
fc "x"; fault "missing model alias" "$RC"; check "missing model: no network call" "$(netcalls)" 0
writeconf "FLEET_CLASSIFIER_ENDPOINT=http://192.0.2.10:1" "FLEET_CLASSIFIER_MODEL=clf-test" \
          "FLEET_CLASSIFIER_ENDPOINT=http://127.0.0.1:$PORT"
reset; fc "x"; check "last assignment wins" "$RC" 0

echo "== nothing from the environment =="
# A config path, endpoint, and model in the environment are all ignored: the
# lib's default config path (/etc/lane2/fleet.conf) is used, and on this test
# machine it does not set the member, so the call faults without a network call.
: > "$ARGV_LOG"
printf 'x' | PATH="$WRAP:$PATH" FLEET_CONF_FILE="$CONF" \
    FLEET_CLASSIFIER_ENDPOINT="http://127.0.0.1:$PORT" FLEET_CLASSIFIER_MODEL=clf-test \
    bash -c 'source "$1"; fleet_call classifier "$2"' _ "$LIB" "$SETTINGS" >/dev/null 2>&1
RC=$?
if [[ -r /etc/lane2/fleet.conf ]]; then
    ok "skipped: this machine has a real /etc/lane2/fleet.conf"
else
    fault "env FLEET_CONF_FILE / FLEET_CLASSIFIER_* ignored" "$RC"
    check "env-only endpoint: no network call" "$(netcalls)" 0
fi
grep -q '\${FLEET_[A-Z_]*:-' "$LIB" && bad "lib reads a FLEET_ variable from the environment" \
    || ok "lib has no \${FLEET_…:-} environment fallback"

echo "== settings =="
goodconf
for patch in '.params.n_predict = 4096' '.params.max_completion_tokens = 9' '.params.model = "other"' \
             '.params.stream = true' 'del(.max_tokens)' '.max_tokens = 0' 'del(.timeout_seconds)' \
             '.params.response_format.json_schema.schema.additionalProperties = true' \
             '.params.response_format.type = "json_object"'; do
    jq "$patch" "$SETTINGS" > "$TMP/s.json"
    fc "x" classifier "$TMP/s.json"
    fault "settings refused: $patch" "$RC"
    check "settings $patch: no network call" "$(netcalls)" 0
done
printf '{not json' > "$TMP/s.json"; fc "x" classifier "$TMP/s.json"; fault "malformed settings file" "$RC"
fc "x" classifier "$TMP/missing.json"; fault "missing settings file" "$RC"
fc "x" classifier "$SETTINGS" "$TMP/missing-system.md"; fault "missing system prompt file" "$RC"

echo "== the pinned classifier settings file =="
check "temperature 0" "$(jq -c .params.temperature "$SETTINGS")" 0
jq -e '.params.seed | type == "number" and . >= 0 and . == floor' "$SETTINGS" >/dev/null \
    && ok "fixed, non-random seed" || bad "seed missing or random (-1)"
check "enum sensitive|nonsensitive" \
    "$(jq -c '.params.response_format.json_schema.schema.properties.verdict.enum' "$SETTINGS")" '["sensitive","nonsensitive"]'
jq -e '.params | has("cache_prompt") and has("id_slot")' "$SETTINGS" >/dev/null \
    && ok "cache and slot settings pinned" || bad "cache or slot setting missing"
jq -e '.max_tokens | type == "number" and . > 0' "$SETTINGS" >/dev/null && ok "max_tokens pinned" || bad "max_tokens missing"
CALLERS="$(grep -rl 'classifier.settings.json' "$ROOT/scripts/orchestrator" "$ROOT/scripts/hub" | sed "s|$ROOT/||" | sort | tr '\n' ' ')"
check "every classifier caller uses the one settings file" "$CALLERS" \
    "scripts/hub/eval-harness.sh scripts/orchestrator/classify-sensitivity.sh scripts/orchestrator/eval-classifier.sh "

# =============================================================================
echo "== AD-10 lint: model requests only in scripts/lib/fleet.sh =="
LINT_PATTERN='/v1/|/completion(s)?([^A-Za-z0-9_.]|$)|/api/generate|/api/chat'
# path (a trailing / means a directory prefix) | the one endpoint it may use (* any) | reason
LINT_EXEMPT=(
    "scripts/lib/fleet.sh|*|the one model-call client (AD-10)"
    "scripts/tests/|*|test suites and model mocks serve or match these paths; they never call a real model"
    "scripts/ask-local.sh|/api/generate|template routing script, kept until FR-39 or #89 retires it"
    "scripts/delegate-local.sh|/api/generate|template routing script, kept until FR-39 or #89 retires it"
    "scripts/local-health.sh|/api/generate|template routing script, kept until FR-39 or #89 retires it"
    "scripts/orchestrator/classify-sensitivity.sh|/api/generate|Ollama transport, kept until Story 1.7 removes it after the soak (NFR-2)"
    "scripts/orchestrator/orchestrate.sh|/api/generate|Lane 1 orchestrator dispatch on Ollama; moves to fleet_call with the Lane 1 client"
    "scripts/orchestrator/sanitise.sh|/api/generate|Lane 1 sanitiser on Ollama; moves to fleet_call with the Lane 1 client"
    "scripts/orchestrator/execute-local.sh|/api/chat|Lane 1 executor on Ollama; moves to fleet_call with the Lane 1 client"
)
# lint_model_calls <root> < file-list — prints "file:line" per violation; rc 1 if any.
lint_model_calls() {
    local root="$1" f hit lineno text e path allow reason rest found=0
    while IFS= read -r f; do
        [[ "$f" =~ \.(md|html|jsonl|txt|svg|png|jpg|gif)$ ]] && continue
        [[ -f "$root/$f" ]] || continue
        while IFS= read -r hit; do
            lineno="${hit%%:*}"; text="${hit#*:}"
            [[ "$text" =~ ^[[:space:]]*# ]] && continue
            allow=""
            for e in "${LINT_EXEMPT[@]}"; do
                path="${e%%|*}"; rest="${e#*|}"
                if [[ "$f" == "$path" || ( "$path" == */ && "$f" == "$path"* ) ]]; then allow="${rest%%|*}"; break; fi
            done
            [[ "$allow" == "*" ]] && continue
            [[ -n "$allow" ]] && text="${text//"$allow"/}"
            grep -qE -- "$LINT_PATTERN" <<<"$text" || continue
            printf '%s:%s\n' "$f" "$lineno"; found=1
        done < <(grep -nE -- "$LINT_PATTERN" "$root/$f" 2>/dev/null)
    done
    return "$found"
}
for e in "${LINT_EXEMPT[@]}"; do
    path="${e%%|*}"; reason="${e##*|}"
    [[ -n "$reason" && "$reason" != "$path" ]] || bad "exemption without a reason: $path"
    [[ -e "$ROOT/$path" ]] || bad "stale exemption (path gone): $path"
done
ok "every exemption names a path and a reason (${#LINT_EXEMPT[@]})"
if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    V="$(git -C "$ROOT" ls-files | lint_model_calls "$ROOT")"; RC=$?
    check "repo lint passes" "$RC" 0
    [[ -z "$V" ]] || printf '      | %s\n' "$V"
else
    ok "skipped repo lint: not a git checkout"
fi
grep -q 'scripts/hub/eval-set.sh' <<<"$(printf '%s\n' "${LINT_EXEMPT[@]}")" \
    && bad "eval drafting helper is exempted" || ok "eval drafting helper is not exempted"
grep -q 'fleet_call draft' "$ROOT/scripts/hub/eval-set.sh" \
    && ok "eval drafting helper calls fleet_call" || bad "eval drafting helper does not use fleet_call"

# Self-test the lint on a synthetic tree.
LR="$TMP/lintroot"; mkdir -p "$LR/scripts/orchestrator" "$LR/scripts/tests" "$LR/docs"
printf '#!/bin/bash\ncurl -s "$EP/v1/chat/completions" -d @f\n' > "$LR/scripts/direct.sh"
printf '#!/bin/bash\n# calls /api/generate in a comment only\necho ok\n' > "$LR/scripts/comment.sh"
printf '#!/bin/bash\ncurl "$E/api/generate"\ncurl "$E/v1/chat/completions"\n' > "$LR/scripts/orchestrator/classify-sensitivity.sh"
printf 'curl "$E/api/chat"\n' > "$LR/scripts/tests/test-x.sh"
printf 'see /v1/chat/completions\n' > "$LR/docs/x.md"
printf 'curl http://127.0.0.1:1/completion\n' > "$LR/scripts/raw.sh"
printf 'source completion.zsh\n' > "$LR/scripts/zsh.sh"
V="$( (cd "$LR" && find . -type f | sed 's|^\./||' | sort) | lint_model_calls "$LR")"; RC=$?
check "lint fails on a direct request" "$RC" 1
grep -q '^scripts/direct.sh:2$' <<<"$V" && ok "lint names the offending file and line" || bad "lint did not name scripts/direct.sh ($V)"
grep -q '^scripts/raw.sh:' <<<"$V" && ok "lint catches /completion" || bad "lint missed /completion"
grep -q '^scripts/orchestrator/classify-sensitivity.sh:3$' <<<"$V" \
    && ok "an exemption covers only its named endpoint" || bad "exempt file's /v1/ call not caught ($V)"
grep -q 'classify-sensitivity.sh:2$' <<<"$V" && bad "exempt endpoint flagged" || ok "exempt endpoint not flagged"
grep -qE 'comment.sh|test-x.sh|docs/x.md|zsh.sh' <<<"$V" && bad "false positive ($V)" || ok "comments, tests, docs, and completion.zsh not flagged"

echo
echo "fleet-call: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
