#!/usr/bin/env bash
# gate-health.sh — the gate's `health` op and the bulk form of its `eval` op
# (SP1a story 2.6; AD-1, AD-2, AD-19, AD-20, FR-23, FR-36). Sourced by
# scripts/hub/gate-handler after scripts/lib/gate.sh. This file is gate code:
# its digest is an input to policy_version.
#
# Neither op writes a cache entry, a retained payload, or an operator log line.
# Nothing here prints a term, a probe, or a case.
#
# API (sourced lib; prefix gate_):
#   gate_header_ok <header file> <op>
#                     rc 0 when the header is well formed for <op>:
#                     health: exactly {v, op}
#                     eval:   {v, op, layers} plus an optional "manifest"
#   gate_load_budget <gate.conf> <deadline>
#                     sets GATE_EVAL_BUDGET (the bulk eval budget, seconds) and
#                     GATE_WORK_LIMIT (the handler's outer limit); rc 4 when invalid
#   gate_watchdog_arm <seconds> <tmpdir>
#                     the per-request deadline inside the handler's work process;
#                     on expiry writes <tmpdir>/timeout and stops the work
#   gate_watchdog_disarm
#   gate_health_probes <policy dir> <fleet conf>
#                     runs the operator's two probes; sets GATE_HEALTH_VERDICT,
#                     GATE_HEALTH_REASON, GATE_HEALTH_DETAIL (JSON)
#   gate_eval_manifest <manifest dir> <state root> <layers> <fleet conf>
#                     runs each requested layer on every case of a hub-produced
#                     manifest; sets GATE_EVAL_CODES (two characters per case),
#                     GATE_EVAL_VERDICT, GATE_EVAL_REASON; rc 4 on a bad manifest
#   gate_eval_inputs <policy_version>
#                     prints the JSON a bulk eval reports about its inputs
#
# Probes. Two files in the operator's policy repository (never this one):
#   health-probe-sensitive.txt  must block through the classifier, with no floor hit
#   health-probe-negative.txt   must allow
# A probe that hits the floor fails health ("probe hits floor"), so the floor
# alone can never pass it.
#
# Manifest. A directory under <state root>/manifests/ written by the hub caller:
# case files named 000001, 000002, ... (contiguous, regular files, no links),
# nothing else. Codes per case, in order: first character the floor, second the
# classifier; h hit, c clear, e could not run, - not requested.

GATE_PROBE_SENSITIVE=health-probe-sensitive.txt
GATE_PROBE_NEGATIVE=health-probe-negative.txt
GATE_EVAL_MAX_CASES=1500          # two characters each must fit the answer line
GATE_EVAL_BUDGET_DEFAULT=600
GATE_WATCHDOG=""

gate_header_ok() {
    local h="$1" op="$2"
    case "$op" in
        health)
            jq -e '(keys - ["v", "op"]) == []' "$h" >/dev/null 2>&1 ;;
        eval)
            # A bulk eval names the policy_version it expects; the gate checks it
            # and never sends one back (Story 2.5).
            jq -e '(keys - ["v", "op", "layers", "manifest", "policy_version"]) == []
                   and (.layers | type) == "array" and (.layers | length) > 0
                   and (.layers | length) == (.layers | unique | length)
                   and all(.layers[]; . == "floor" or . == "classifier")
                   and (if has("manifest")
                        then (.manifest | type) == "string"
                             and (.policy_version | type) == "string"
                             and (.policy_version | test("^[0-9a-f]{64}$"))
                        else (has("policy_version") | not) end)' "$h" >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}

# --- deadlines ---------------------------------------------------------------

# shellcheck disable=SC2034  # read by gate-handler
# The bulk eval budget lives in gate.conf (AD-20: bulk ops have their own
# budgets in hub config). It is at least the per-request deadline.
gate_load_budget() {
    local conf="$1" dl="$2" b
    b="$(lane2_conf_file_get "$conf" GATE_EVAL_BUDGET)"; b="${b:-$GATE_EVAL_BUDGET_DEFAULT}"
    [[ "$b" =~ ^[1-9][0-9]{0,3}$ ]] && (( b >= dl && b <= 9000 )) || return 4
    GATE_EVAL_BUDGET="$b"
    # The mount scan (Story 3.2) has its own bulk budget.
    b="$(lane2_conf_file_get "$conf" GATE_SCAN_BUDGET)"; b="${b:-900}"
    [[ "$b" =~ ^[1-9][0-9]{0,3}$ ]] && (( b >= dl && b <= 9000 )) || return 4
    GATE_SCAN_BUDGET="$b"
    # The outer limit covers the longest op; the watchdog enforces GATE_DEADLINE
    # on every request, re-armed with its own budget by a bulk op.
    GATE_WORK_LIMIT=$(( GATE_EVAL_BUDGET > GATE_SCAN_BUDGET ? GATE_EVAL_BUDGET : GATE_SCAN_BUDGET ))
}

# The watchdog runs in the work process's group (timeout(1) made it a group
# leader), so stopping the group ends the work and anything it started, and
# never the connection's handler. Its descriptors are closed so it can never
# hold the connection open.
gate_watchdog_arm() {
    local s="$1" t="$2"
    ( sleep "$s"; : > "$t/timeout"; kill -TERM 0 ) </dev/null >/dev/null 2>&1 &
    GATE_WATCHDOG=$!
    disown "$GATE_WATCHDOG" 2>/dev/null || true
    trap 'gate_watchdog_disarm' EXIT
}

gate_watchdog_disarm() {
    [[ -n "$GATE_WATCHDOG" ]] && kill "$GATE_WATCHDOG" 2>/dev/null
    GATE_WATCHDOG=""
    return 0
}

# --- health ------------------------------------------------------------------

# gate_health_probe <file> <want: block|allow> <fleet conf> — prints one result:
# ok, missing, non-text, hits-floor, classifier-fault, oversize, wrong-verdict.
gate_health_probe() {
    local f="$1" want="$2" conf="$3" rc=0
    [[ -f "$f" && ! -L "$f" && -r "$f" && -s "$f" ]] || { echo missing; return 0; }
    gate_is_text "$f" || { echo non-text; return 0; }
    gate_floor_match "$(cat -- "$f")" || rc=$?
    case "$rc" in 0) echo hits-floor; return 0 ;; 1) ;; *) echo missing; return 0 ;; esac
    rc=0; gate_classify "$f" "$conf" || rc=$?
    case "$rc" in
        0) [[ "$want" == allow ]] && echo ok || echo wrong-verdict ;;
        3) [[ "$want" == block ]] && echo ok || echo wrong-verdict ;;
        *) [[ "$GATE_FAULT" == fault:oversize ]] && echo oversize || echo classifier-fault ;;
    esac
}

# shellcheck disable=SC2034  # results are read by gate-handler
gate_health_probes() {
    local dir="$1" conf="$2" s n
    s="$(gate_health_probe "$dir/$GATE_PROBE_SENSITIVE" block "$conf")"
    n="$(gate_health_probe "$dir/$GATE_PROBE_NEGATIVE" allow "$conf")"
    GATE_HEALTH_DETAIL="$(jq -nc --arg s "$s" --arg n "$n" '{probes: {sensitive: $s, negative: $n}}')"
    GATE_HEALTH_VERDICT=allow; GATE_HEALTH_REASON=""
    [[ "$s" == ok && "$n" == ok ]] && return 0
    GATE_HEALTH_VERDICT=block
    case " $s $n " in
        *" classifier-fault "*|*" oversize "*|*" wrong-verdict "*) GATE_HEALTH_REASON=fault:classifier ;;
        *) GATE_HEALTH_REASON=fault:policy ;;
    esac
    return 0
}

# --- bulk eval ---------------------------------------------------------------

# gate_manifest_ok <dir> <state root> — the manifest is hub-produced: it lives in
# the manifests store, is a real directory, and holds only contiguous case files.
# Sets GATE_EVAL_N. The gate reads it under its own identity.
gate_manifest_ok() {
    local dir="$1" root="$2" store name n=0 e
    store="$root/manifests"
    [[ "$dir" =~ ^/[A-Za-z0-9._/-]+$ && "$dir" != *..* ]] || return 4
    [[ "${dir%/*}" == "$store" && "${dir##*/}" =~ ^[A-Za-z0-9._-]+$ ]] || return 4
    [[ -d "$store" && ! -L "$store" && -d "$dir" && ! -L "$dir" ]] || return 4
    while IFS= read -r -d '' e; do
        name="${e##*/}"
        [[ "$name" =~ ^[0-9]{6}$ && -f "$e" && ! -L "$e" ]] || return 4
        n=$((n + 1))
        (( n <= GATE_EVAL_MAX_CASES )) || return 4
    done < <(find "$dir" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
    local i
    for (( i = 1; i <= n; i++ )); do [[ -f "$dir/$(printf '%06d' "$i")" ]] || return 4; done
    GATE_EVAL_N="$n"
}

# shellcheck disable=SC2034  # results are read by gate-handler
gate_eval_manifest() {
    local dir="$1" root="$2" layers="$3" conf="$4" i f fc cc rc size codes=""
    GATE_EVAL_CODES=""; GATE_EVAL_VERDICT=block; GATE_EVAL_REASON=""
    gate_manifest_ok "$dir" "$root" || return 4
    for (( i = 1; i <= GATE_EVAL_N; i++ )); do
        f="$dir/$(printf '%06d' "$i")"
        fc=-; cc=-
        size="$(wc -c < "$f" 2>/dev/null | tr -d ' ')"
        if [[ -z "$size" ]] || (( size == 0 || size > GATE_MAX_REQUEST )) || ! gate_is_text "$f"; then
            [[ " $layers " == *" floor "* ]] && fc=e
            [[ " $layers " == *" classifier "* ]] && cc=e
            codes+="$fc$cc"; continue
        fi
        if [[ " $layers " == *" floor "* ]]; then
            rc=0; gate_floor_match "$(cat -- "$f")" || rc=$?
            case "$rc" in 0) fc=h ;; 1) fc=c ;; *) fc=e ;; esac
        fi
        if [[ " $layers " == *" classifier "* ]]; then
            rc=0; gate_classify "$f" "$conf" || rc=$?
            case "$rc" in 0) cc=c ;; 3) cc=h ;; *) cc=e ;; esac
        fi
        codes+="$fc$cc"
    done
    GATE_EVAL_CODES="$codes"
    if [[ "$codes" =~ ^[c-]*$ ]]; then GATE_EVAL_VERDICT=allow; return 0; fi
    if [[ "$codes" =~ ^(..)*h ]]; then GATE_EVAL_REASON=hit:floor
    elif [[ "$codes" == *h* ]]; then GATE_EVAL_REASON=hit:classifier
    else GATE_EVAL_REASON=fault:classifier; fi
    return 0
}

# What a bulk eval reports about its inputs: only the public settings file. The
# policy_version is the caller's to state and the gate's to check (header); no op
# returns it, the prompt, or anything derived from them (Story 2.5).
gate_eval_inputs() {
    jq -nc --arg s "$(sha256sum < "$GATE_CLASSIFIER_SETTINGS" | cut -d' ' -f1)" \
        --argjson c "$(jq -c '.params | if has("cache_prompt") then .cache_prompt else true end' "$GATE_CLASSIFIER_SETTINGS" 2>/dev/null || echo true)" \
        '{settings_sha256: $s, cache_prompt: $c}'
}
