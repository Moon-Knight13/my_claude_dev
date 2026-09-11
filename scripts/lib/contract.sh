#!/usr/bin/env bash
# contract.sh — the disclosure boundary (E6/E9/E10, story S3, issue #63).
#
# This is the control that lets a cloud model coordinate work it is never allowed
# to see. The local executor produces an implementation artifact; what crosses to
# the cloud is not that artifact, nor a scrubbed version of it, but a DECLARED
# INTERFACE: a name, how to invoke it, its inputs, its outputs, its exit codes.
# Enough to write code that calls the thing. Nothing about what it does inside.
#
# WHY A CONTRACT AND NOT A FILTER
# A filter fails OPEN. Whatever the rewrite misses, crosses — and the sanitiser
# eval measured internal hostnames and codenames getting through. A contract fails
# CLOSED: undeclared content was never in the message, so there is nothing to
# miss. Positive disclosure, not subtraction.
#
# WHY THE HANDLE
# A path is itself disclosure. `/srv/customer/<name>/scoring/...` leaks org
# structure, client identity and project codenames even when the file's contents
# are perfectly protected. Protecting contents while disclosing location is a
# half-closed door. So an artifact is referenced by a random opaque handle, and
# the handle-to-path map is a list of real internal paths — sensitive by
# construction, kept on the box, never resolved for a caller that is not local.
#
# THE ORDER OF THE GATES, AND WHY
#   1. validate   — shape, and no path-shaped text anywhere
#   2. project    — keep ONLY declared fields (this is the positive disclosure)
#   3. term floor — the owner's private word list, matched by code
#   4. sanitise   — LLM backstop; FAILURE BLOCKS on this path (R3)
#   5. term floor — again, on the text that actually crosses
#   6. approve    — the owner reads the final text and says yes, every time (E10)
#
# Step 3 brackets step 4 deliberately. The floor is the only code-level check
# here; the sanitiser and the owner are both judgement, and both are known
# fallible. The owner may override the fallible control (step 4's bypass).
# Nobody overrides the deterministic one.
#
# API:
#   contract_init                 prepare the handle map
#   contract_handle <path>        random opaque handle for an artifact
#   contract_resolve <handle>     path, LOCALLY only (rc 2 for a cloud caller)
#   contract_validate <json>      -> CONTRACT_ERR ("" = valid)
#   contract_project <json>       prints the contract reduced to declared fields
#   contract_disclose <json>      the whole pipeline -> CONTRACT_STATUS / CONTRACT_OUT
#
# CONTRACT_STATUS is one of: disclosed · refused · blocked · floor · invalid.
# Anything other than `disclosed` leaves CONTRACT_OUT empty. There is no path
# through this file that emits something the owner did not approve.
# shellcheck disable=SC2034

_CT_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/guard-stack.sh disable=SC1091
source "${GUARD_STACK_LIB:-$_CT_SELF/guard-stack.sh}"
# shellcheck source=scripts/lib/orchestrator-route.sh disable=SC1091
source "${ORCH_ROUTE_LIB:-$_CT_SELF/orchestrator-route.sh}"
# shellcheck source=scripts/lib/executor-tools.sh disable=SC1091
source "${EXECUTOR_TOOLS_LIB:-$_CT_SELF/executor-tools.sh}"

# The map lives under the orchestrator's config directory, which the C1 guard
# denies to Claude's tools unconditionally (not opt-in, not overridable). It is a
# list of real internal paths; it is exactly the thing that must not be readable.
CONTRACT_MAP="${ORCH_HANDLE_MAP:-$HOME/.config/orchestrator/handles.tsv}"
CONTRACT_LOG="${ORCH_LOG:-.ai/orchestrator-log.jsonl}"

# The fields that may cross. This list IS the disclosure policy — anything not
# named here is dropped on the way out, whatever the local model put in it.
CONTRACT_FIELDS="name handle summary invocation inputs outputs exit_codes"

CONTRACT_ERR=""
CONTRACT_STATUS=""
CONTRACT_OUT=""
CONTRACT_APPROVED_TEXT=""

contract_init() {
    CONTRACT_MAP="${ORCH_HANDLE_MAP:-$HOME/.config/orchestrator/handles.tsv}"
    mkdir -p "$(dirname "$CONTRACT_MAP")" 2>/dev/null || true
    if [[ ! -f "$CONTRACT_MAP" ]]; then
        ( umask 077; : > "$CONTRACT_MAP" ) 2>/dev/null || true
    fi
    chmod 600 "$CONTRACT_MAP" 2>/dev/null || true
}

# contract_handle <path> — a random opaque id for an artifact.
#
# Random, not sequential and not derived from the path (R16). Sequential ids
# publish how many artifacts exist and how fast they appear; derived ids let
# anyone who can guess a path confirm it. Neither is a property worth handing to
# the other side of this boundary.
contract_handle() {
    local map="${ORCH_HANDLE_MAP:-$CONTRACT_MAP}" hx enc
    mkdir -p "$(dirname "$map")" 2>/dev/null || true
    [[ -f "$map" ]] || ( umask 077; : > "$map" ) 2>/dev/null || true
    hx="$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
    [[ -n "$hx" ]] || return 1
    enc="$(printf '%s' "$1" | base64 2>/dev/null | tr -d '\n')"
    printf '%s\t%s\n' "$hx" "$enc" >> "$map"
    chmod 600 "$map" 2>/dev/null || true
    printf '%s' "$hx"
}

# contract_resolve <handle> — the real path, for LOCAL use.
#   rc 1  unknown handle
#   rc 2  the caller is not local — resolving would hand over the path the handle
#         exists to hide, which is the one thing this boundary is for.
contract_resolve() {
    exec_caller_is_human || return 2
    local map="${ORCH_HANDLE_MAP:-$CONTRACT_MAP}" enc
    enc="$(awk -F'\t' -v k="$1" '$1==k {print $2; exit}' "$map" 2>/dev/null)"
    [[ -n "$enc" ]] || return 1
    printf '%s' "$enc" | base64 -d 2>/dev/null
}

# --- validation --------------------------------------------------------------
# No slashes, anywhere, in any declared value. A blunt rule on purpose: it is
# checkable by code with no judgement in it, and it fails closed. A contract that
# genuinely needs to say "not applicable" can say it in words; a contract that
# wants to say `/srv/customer/acme` cannot say it at all.
_contract_has_path() { # _contract_has_path <json>
    printf '%s' "$1" | jq -e '
        [.. | strings] | map(select(test("/"))) | length > 0' >/dev/null 2>&1
}

contract_validate() { # contract_validate <json>
    CONTRACT_ERR=""
    local j="$1" v
    if ! printf '%s' "$j" | jq -e 'type=="object"' >/dev/null 2>&1; then
        CONTRACT_ERR="not a JSON object"; return 0
    fi
    for v in name handle invocation; do
        if [[ -z "$(printf '%s' "$j" | jq -r --arg k "$v" '.[$k] // "" | tostring')" ]]; then
            CONTRACT_ERR="contract is missing a required field: $v"; return 0
        fi
    done
    local h; h="$(printf '%s' "$j" | jq -r '.handle')"
    if [[ ! "$h" =~ ^[0-9a-f]{16}$ ]]; then
        CONTRACT_ERR="handle is not an opaque 16-hex identifier"; return 0
    fi
    if _contract_has_path "$(contract_project "$j")"; then
        CONTRACT_ERR="a declared value contains a filesystem path; a path is itself disclosure"
        return 0
    fi
    return 0
}

# contract_project <json> — the contract reduced to declared fields.
#
# This is the positive-disclosure step, and the reason the boundary fails closed:
# a field the local model invented — a note, a debug trail, a rationale — is not
# scrubbed, it is simply never copied into the thing that crosses.
contract_project() {
    printf '%s' "$1" | jq -cS --arg fields "$CONTRACT_FIELDS" \
        'with_entries(select(.key as $k | ($fields | split(" ")) | index($k))) | del(..|nulls)' 2>/dev/null
}

# --- the two judgement surfaces ----------------------------------------------
# Both are replaceable by design: the executor's tests drive them directly. Both
# require a controlling TTY, so an automated caller cannot answer for the owner.

# contract_approve <final text> — E10. The owner reads the text AS IT WOULD
# CROSS, after sanitising, and says yes. Every contract, not just the first.
contract_approve() {
    CONTRACT_APPROVED_TEXT="$1"
    exec_tty_ok || return 1
    local ans=""
    {
        printf '\n=== CONTRACT TO DISCLOSE TO THE CLOUD MODEL ===\n%s\n' "$1"
        printf '=== this is exactly what crosses. approve? [y/N] '
    } > /dev/tty
    IFS= read -r ans < /dev/tty || return 1
    case "$ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# contract_bypass_prompt <raw text> — R3. The sanitiser failed. A flaky local
# model must not halt work permanently, so the owner may disclose the
# UNSANITISED contract — per instance, at a terminal, having read it first. There
# is deliberately no configuration flag: nothing here can be left switched on.
contract_bypass_prompt() {
    exec_tty_ok || return 1
    local ans=""
    {
        printf '\n=== SANITISER UNAVAILABLE — RAW CONTRACT ===\n%s\n' "$1"
        printf '=== disclose this UNSANITISED? the word list still applies. [y/N] '
    } > /dev/tty
    IFS= read -r ans < /dev/tty || return 1
    case "$ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# --- log ----------------------------------------------------------------------
# Metadata only: what happened to a disclosure, never the contract text, never a
# path, never which term matched.
_contract_log() { # _contract_log <status> <sanitiser-state> <handle>
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
    mkdir -p "$(dirname "$CONTRACT_LOG")" 2>/dev/null || true
    jq -cn --arg ts "$ts" --arg st "$1" --arg san "$2" --arg h "$3" \
        '{ts:$ts, event:"disclosure", status:$st, sanitiser:$san, handle:$h}' \
        >> "$CONTRACT_LOG" 2>/dev/null || true
}

# --- the pipeline -------------------------------------------------------------
contract_disclose() { # contract_disclose <proposed contract json>
    CONTRACT_STATUS=""; CONTRACT_OUT=""
    local proposed="$1" proj final san_state handle

    contract_validate "$proposed"
    if [[ -n "$CONTRACT_ERR" ]]; then
        CONTRACT_STATUS="invalid"; _contract_log invalid none ""; return 0
    fi
    proj="$(contract_project "$proposed")"
    handle="$(printf '%s' "$proj" | jq -r '.handle // ""')"

    # Floor on the draft: stop before the contract is shown to anything else.
    if orch_floor_match "$proj"; then
        CONTRACT_STATUS="floor"; _contract_log floor none "$handle"; return 0
    fi

    final=""; san_state=""
    if [[ -n "${ORCH_SANITISER:-}" && -x "${ORCH_SANITISER}" ]] \
        && final="$(printf '%s' "$proj" | "$ORCH_SANITISER" 2>/dev/null)" && [[ -n "$final" ]]; then
        san_state="applied"
    else
        # R3: on this path a sanitiser failure BLOCKS. The contract is derived
        # directly from sensitive material, so "pass the original through" — the
        # defensible default on the C2 prompt path, where a classifier had already
        # cleared the text — is not defensible here.
        if contract_bypass_prompt "$proj"; then
            final="$proj"; san_state="bypassed"
        else
            CONTRACT_STATUS="blocked"; _contract_log blocked failed "$handle"; return 0
        fi
    fi

    # R2: the floor again, on the text that actually crosses. The sanitiser is an
    # LLM rewrite; it can introduce words as well as remove them, and the bypass
    # above skips it entirely. Neither of those may skip this.
    if orch_floor_match "$final"; then
        CONTRACT_STATUS="floor"; _contract_log floor "$san_state" "$handle"; return 0
    fi

    if contract_approve "$final"; then
        CONTRACT_OUT="$final"; CONTRACT_STATUS="disclosed"
        _contract_log disclosed "$san_state" "$handle"
    else
        CONTRACT_STATUS="refused"; _contract_log refused "$san_state" "$handle"
    fi
    return 0
}
