#!/usr/bin/env bash
# gate.sh — the gate's policy core (SP1a story 2.2; AD-1, AD-4, AD-7, AD-19,
# FR-10, FR-13, FR-50). This file is gate code: its digest is an input to
# policy_version.
#
# The gate must never run without its policy. Where `orch_floor_match` (Lane 1)
# treats a missing term list as "no hit", the gate treats it as a fault and
# blocks. That difference lives here: the strict loader and the strict floor
# wrapper below. `orch_floor_match` keeps its lenient behaviour for Lane 1 and
# SP4 callers only.
#
# Nothing here prints a term or a prompt line, or which term matched.
#
# API (sourced lib; prefix gate_):
#   gate_terms_check <file> [min]    counts valid and rejected entries; sets
#                                    GATE_TERMS_VALID, GATE_TERMS_REJECTED and
#                                    GATE_REJECTED_LINES (line numbers only)
#   gate_policy_load <dir> <operator>  strict load of <dir>/current; rc 4 on any
#                                    missing, empty, unreadable, or all-rejected input,
#                                    or a caller that is neither operator nor gate
#   gate_floor_match <text>          rc 0 hit, 1 no hit, 4 fault (policy not loaded
#                                    or term list gone); never "no hit" on a fault
#   gate_policy_version <terms> <prompt> <model id> <model sha256> <runtime build>
#                       <gate-code digest>
#                                    prints policy_version; rc 4 if any input is
#                                    missing, unreadable, empty, or malformed

GATE_TERM_MIN_LEN=3
GATE_IDENTITY=lane2-gate
GATE_POLICY_LOADED=""
GATE_TERM_FILE=""
GATE_PROMPT_FILE=""

# orchestrator-route.sh derives a Lane 1 default list path from $HOME; the gate
# never uses it, but a service may run with HOME unset.
: "${HOME:=/nonexistent}"
# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/orchestrator-route.sh"

# gate_terms_check <file> [min] — same parsing as orch_floor_match: trimmed,
# blank and '#' lines skipped, entries shorter than min rejected.
gate_terms_check() {
    local file="$1" min="${2:-$GATE_TERM_MIN_LEN}" line term n=0
    GATE_TERMS_VALID=0; GATE_TERMS_REJECTED=0; GATE_REJECTED_LINES=()
    [[ -f "$file" && -r "$file" ]] || return 4
    while IFS= read -r line || [[ -n "$line" ]]; do
        n=$((n + 1))
        term="${line#"${line%%[![:space:]]*}"}"
        term="${term%"${term##*[![:space:]]}"}"
        [[ -n "$term" && "$term" != \#* ]] || continue
        if (( ${#term} < min )); then
            GATE_TERMS_REJECTED=$((GATE_TERMS_REJECTED + 1))
            GATE_REJECTED_LINES+=("$n")
        else
            GATE_TERMS_VALID=$((GATE_TERMS_VALID + 1))
        fi
    done < "$file"
    return 0
}

# Only the operator and the gate identity may read the policy.
gate_reader_ok() { # gate_reader_ok <operator account>
    local me op gate
    me="$(id -u)"
    op="$(getent passwd "$1" | cut -d: -f3)"
    gate="$(getent passwd "$GATE_IDENTITY" | cut -d: -f3)"
    [[ -n "$op" && "$me" == "$op" ]] || [[ -n "$gate" && "$me" == "$gate" ]]
}

# gate_policy_load <policy-dir> <operator account> — strict. Faults (rc 4) and
# loads neither layer unless the term list has at least one valid entry and the
# classifier prompt is non-empty, both readable, and the caller may read them.
gate_policy_load() {
    local dir="$1" op="$2" terms prompt
    GATE_POLICY_LOADED=""; GATE_TERM_FILE=""; GATE_PROMPT_FILE=""
    gate_reader_ok "$op" || return 4
    terms="$dir/current/term-list.txt"; prompt="$dir/current/classifier-prompt.md"
    gate_terms_check "$terms" || return 4
    (( GATE_TERMS_VALID > 0 )) || return 4
    [[ -f "$prompt" && -r "$prompt" && -s "$prompt" ]] || return 4
    grep -q '[^[:space:]]' "$prompt" 2>/dev/null || return 4
    # GATE_PROMPT_FILE is read by the gate's classifier layer (Story 2.3).
    # shellcheck disable=SC2034
    GATE_PROMPT_FILE="$prompt"
    GATE_TERM_FILE="$terms"; GATE_POLICY_LOADED=1
}

# gate_floor_match <text> — the strict floor. orch_floor_match returns "no hit"
# for a missing list; here a missing or unreadable list is a fault, checked
# before delegating. The match itself is orch_floor_match's, with the list and
# minimum length set here, not taken from the environment.
gate_floor_match() {
    [[ "$GATE_POLICY_LOADED" == 1 && -f "$GATE_TERM_FILE" && -r "$GATE_TERM_FILE" ]] || return 4
    local rc=0
    ORCH_TERM_LIST="$GATE_TERM_FILE" ORCH_TERM_MIN_LEN="$GATE_TERM_MIN_LEN" \
        orch_floor_match "$1" 2>/dev/null || rc=$?
    case "$rc" in 0|1) return "$rc" ;; *) return 4 ;; esac
}

# gate_policy_version — sha256 over the inputs in a fixed order, each written as
# "<name> <byte length>\n<bytes>\n", so no two input sets can collide by moving
# bytes from one field to the next. Any missing, unreadable, or empty input, or a
# malformed checksum, digest, or build tag, is a fault.
gate_policy_version() {
    local terms="$1" prompt="$2" model="$3" model_sha="$4" build="$5" gate_digest="$6"
    local LC_ALL=C   # ${#var} counts bytes, matching wc -c for the files
    [[ -f "$terms" && -r "$terms" && -s "$terms" ]] || return 4
    [[ -f "$prompt" && -r "$prompt" && -s "$prompt" ]] || return 4
    [[ -n "$model" && "$model" != *$'\n'* ]] || return 4
    [[ "$model_sha" =~ ^[0-9a-f]{64}$ ]] || return 4
    [[ "$build" =~ ^(v[0-9]+\.[0-9]+\.[0-9]+|b[0-9]+)$ ]] || return 4
    [[ "$gate_digest" =~ ^[0-9a-f]{64}$ ]] || return 4
    {
        printf 'terms %s\n' "$(wc -c < "$terms" | tr -d ' ')"; cat -- "$terms"; printf '\n'
        printf 'prompt %s\n' "$(wc -c < "$prompt" | tr -d ' ')"; cat -- "$prompt"; printf '\n'
        printf 'model %s\n%s\n' "${#model}" "$model"
        printf 'model_sha256 %s\n%s\n' "${#model_sha}" "$model_sha"
        printf 'runtime_build %s\n%s\n' "${#build}" "$build"
        printf 'gate_code_digest %s\n%s\n' "${#gate_digest}" "$gate_digest"
    } | sha256sum | cut -d' ' -f1
}
