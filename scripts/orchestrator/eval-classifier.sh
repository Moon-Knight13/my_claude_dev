#!/usr/bin/env bash
# eval-classifier.sh — measure the sensitivity classifier against labelled
# fixtures. Runs against a LIVE local model, so this is an on-box manual tool, not
# a CI gate (the deterministic contract is covered by scripts/tests/test-classifier.sh).
#
# The headline metric is SENSITIVE RECALL: of the truly-sensitive cases, how many
# the classifier caught. A miss here (false negative) is a potential leak — that
# is the number to drive toward 100% by tuning the classifier prompt.
#
# PRIVACY: stdout carries AGGREGATE NUMBERS ONLY. Per-case detail — which cases
# were missed, which were false alarms — goes to a private report file instead.
# Once you start tuning, the fixtures describe real material, and anything printed
# here lands in a terminal, in scrollback and in a session transcript. The report
# lives under ~/.config/orchestrator/, which the C1 guard already hides from
# Claude's tools with no configuration needed.
#
# Usage: eval-classifier.sh [fixtures.jsonl]
#        eval-classifier.sh --parallel-verify [--fleet-config FILE] [fixtures...]
#          (hub only; both transports, see evalcls_parallel_verify below)
#   Env: ORCH_CLASSIFIER (defaults to the sibling classify-sensitivity.sh),
#        ORCH_EVAL_FIXTURES (private fixtures, ADDED to the committed set),
#        ORCH_EVAL_REPORT   (where per-case detail is written),
#        plus the classifier's own ORCH_CLASSIFIER_* / LOCAL_MODEL_* knobs.
set -uo pipefail

_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/fleet.sh disable=SC1091
source "$_HERE/../lib/fleet.sh"
# Multi-block cases (docs/SP1A_EVAL_SET.md) are scored as their blocks joined.
EVALCLS_PROMPT_JQ='.prompt // (.blocks // [] | join("\n\n"))'

evalcls_score() { # evalcls_score [fixtures.jsonl]
    FIX="${1:-$_HERE/../tests/fixtures/sensitivity-eval.jsonl}"
    CLS="${ORCH_CLASSIFIER:-$_HERE/classify-sensitivity.sh}"
    # Private fixtures are ADDED to the committed set, not a replacement: the shipped
    # synthetic cases stay as regression coverage while real ones accumulate privately.
    PRIV_FIX="${ORCH_EVAL_FIXTURES:-$HOME/.config/orchestrator/fixtures/sensitivity-eval.jsonl}"
    REPORT="${ORCH_EVAL_REPORT:-$HOME/.config/orchestrator/eval-classifier-report.txt}"

    [[ -f "$FIX" ]] || { echo "eval: fixtures not found: $FIX" >&2; return 1; }
    [[ -x "$CLS" || -f "$CLS" ]] || { echo "eval: classifier not found: $CLS" >&2; return 1; }

    priv_note=""
    [[ -f "$PRIV_FIX" ]] && priv_note=" + private"

    TP=0; FP=0; TN=0; FN=0; N=0
    declare -a MISSES=() FALARMS=()

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -n "$line" ]] || continue
        jq -e "$EVALCLS_PROMPT_JQ | type == \"string\"" <<<"$line" >/dev/null 2>&1 || continue
        label="$(jq -r '.label'  <<<"$line" 2>/dev/null)"
        note="$(jq -r '.note // ""' <<<"$line" 2>/dev/null)"
        [[ "$label" == "sensitive" || "$label" == "nonsensitive" ]] || continue
        # The prompt goes to the classifier on stdin, never argv.
        verdict="$(jq -j "$EVALCLS_PROMPT_JQ" <<<"$line" 2>/dev/null | bash "$CLS" 2>/dev/null)"
        N=$((N+1))
        if [[ "$label" == "sensitive" ]]; then
            if [[ "$verdict" == "sensitive" ]]; then TP=$((TP+1)); else FN=$((FN+1)); MISSES+=("$note"); fi
        else
            if [[ "$verdict" == "nonsensitive" ]]; then TN=$((TN+1)); else FP=$((FP+1)); FALARMS+=("$note"); fi
        fi
    done < <(cat "$FIX" 2>/dev/null; [[ -f "$PRIV_FIX" ]] && cat "$PRIV_FIX" 2>/dev/null)

    _pct() { local n="$1" d="$2"; (( d == 0 )) && { printf 'n/a'; return; }; printf '%d%%' $(( 100 * n / d )); }

    echo "=== sensitivity classifier eval ($N cases) ==="
    echo
    echo "                 predicted"
    echo "               sens   nonsens"
    printf "actual sens    %4d   %4d\n" "$TP" "$FN"
    printf "     nonsens   %4d   %4d\n" "$FP" "$TN"
    echo
    echo "SENSITIVE RECALL (caught / all sensitive):  $(_pct "$TP" $((TP+FN)))   <-- headline; misses = potential leaks"
    echo "sensitive precision (correct / flagged):    $(_pct "$TP" $((TP+FP)))"
    echo "overall accuracy:                            $(_pct $((TP+TN)) "$N")"
    echo
    # Per-case detail goes to the private report, never to stdout. Written owner-only
    # and under the always-guarded orchestrator config directory.
    mkdir -p "$(dirname "$REPORT")" 2>/dev/null || true
    {
        umask 077
        {
            echo "=== sensitivity classifier eval detail — $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
            echo "cases: $N   recall: $(_pct "$TP" $((TP+FN)))   fixtures: $FIX${priv_note}"
            echo
            if (( FN > 0 )); then
                echo "MISSED SENSITIVE (potential leaks) — tune the prompt for these:"
                for m in "${MISSES[@]}"; do echo "   - $m"; done
            else
                echo "no missed sensitive cases."
            fi
            if (( FP > 0 )); then
                echo
                echo "false alarms (kept local unnecessarily — friction, not a leak):"
                for f in "${FALARMS[@]}"; do echo "   - $f"; done
            fi
        } > "$REPORT" 2>/dev/null
    } || true

    if (( FN > 0 )); then
        echo "missed sensitive cases: $FN   <-- each one is a potential leak"
    else
        echo "no missed sensitive cases."
    fi
    (( FP > 0 )) && echo "false alarms: $FP   (kept local unnecessarily — friction, not a leak)"
    echo
    echo "per-case detail (which cases, and why) written to:"
    echo "  $REPORT"
    echo "It is owner-only and hidden from Claude's tools. Nothing case-specific is"
    echo "printed here, because this output goes to your terminal and transcript."
    # Non-zero exit if any sensitive case leaked, so a wrapper/CI-on-box can gate.
    (( FN == 0 ))
}

# --- parallel-verify (SP1a story 1.3; NFR-2, FR-38) ---------------------------
# Runs every case through the classifier under BOTH transports (ollama and
# openai/fleet_call), pointed by the operator at the same pinned model file, and
# records per-case verdict equality in a hub-only record. A run with zero
# differing verdicts and zero faults also appends the zero-diff record that
# Story 1.7 needs before the Ollama path may be removed. Stdout: counts only.
#
# Always uses the sibling classify-sensitivity.sh (never ORCH_CLASSIFIER) and
# the pinned classifier settings file. Fleet config: --fleet-config FILE
# (default /etc/lane2/fleet.conf); it must set FLEET_CLASSIFIER_ENDPOINT,
# FLEET_CLASSIFIER_MODEL, FLEET_CLASSIFIER_SHA256 (the model file checksum
# recorded with the run), and may set FLEET_STATE_DIR (default
# /var/lib/lane2/fleet; created 0700, records 0600).
# Exit: 0 zero-diff record written; 3 a difference, a fault, or no cases;
# 2 usage; 4 config or store fault.
evalcls_pv_die() { printf ' FAIL %s\n' "$2" >&2; exit "$1"; }

evalcls_parallel_verify() {
    local cfg="" cls="$_HERE/classify-sensitivity.sh" settings="$_HERE/../hub/fleet/classifier.settings.json"
    local -a fix=()
    while (( $# )); do
        case "$1" in
            --fleet-config) [[ -n "${2:-}" ]] || evalcls_pv_die 2 "usage: --parallel-verify [--fleet-config FILE] [fixtures...]"
                            cfg="$2"; shift 2 ;;
            -*) evalcls_pv_die 2 "usage: --parallel-verify [--fleet-config FILE] [fixtures...]" ;;
            *)  fix+=("$1"); shift ;;
        esac
    done
    if (( ${#fix[@]} == 0 )); then
        fix=("$_HERE/../tests/fixtures/sensitivity-eval.jsonl")
        local priv="${ORCH_EVAL_FIXTURES:-$HOME/.config/orchestrator/fixtures/sensitivity-eval.jsonl}"
        [[ -f "$priv" ]] && fix+=("$priv")
    fi
    local f
    for f in "${fix[@]}"; do [[ -f "$f" && -r "$f" ]] || evalcls_pv_die 4 "fixtures unreadable: $f"; done

    fleet_in_container && evalcls_pv_die 4 "run on the hub"
    [[ -n "$cfg" ]] && fleet_use_config "$cfg"
    fleet_load_config || evalcls_pv_die 4 "fleet config missing or unreadable"
    local model model_sha state prompt_sha settings_sha fix_sha
    model="$(fleet_member_model classifier)" || evalcls_pv_die 4 "FLEET_CLASSIFIER_MODEL missing or malformed"
    model_sha="$(fleet_conf FLEET_CLASSIFIER_SHA256 | tr 'A-F' 'a-f')"
    [[ "$model_sha" =~ ^[0-9a-f]{64}$ ]] || evalcls_pv_die 4 "FLEET_CLASSIFIER_SHA256 must be the model file sha256"
    state="$(fleet_conf FLEET_STATE_DIR /var/lib/lane2/fleet)"
    [[ "$state" == /* ]] || evalcls_pv_die 4 "FLEET_STATE_DIR must be absolute"
    prompt_sha="$(bash "$cls" --prompt-sha256 </dev/null)"
    [[ "$prompt_sha" =~ ^[0-9a-f]{64}$ ]] || evalcls_pv_die 4 "could not checksum the classifier prompt"
    settings_sha="$(sha256sum < "$settings" | cut -d' ' -f1)"
    fix_sha="$(cat -- "${fix[@]}" | sha256sum | cut -d' ' -f1)"

    ( umask 077; mkdir -p "$state/parallel-verify" ) || evalcls_pv_die 4 "cannot create $state"
    [[ "$(stat -c '%a %u' "$state")" == "700 $(id -u)" ]] \
        || evalcls_pv_die 4 "$state must be mode 0700 and owned by you"

    local stamp rows line id v_o v_n rc_o rc_n eq n=0 equal=0 differ=0 faults=0
    stamp="$(date -u +%Y%m%dT%H%M%SZ)-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
    rows="$(umask 077; mktemp)" || evalcls_pv_die 4 "no temp file"
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -n "$line" ]] || continue
        jq -e "$EVALCLS_PROMPT_JQ | type == \"string\"" <<<"$line" >/dev/null 2>&1 || continue
        n=$((n + 1))
        id="$(jq -r '.id // empty' <<<"$line" 2>/dev/null)"; [[ -n "$id" ]] || id="case-$n"
        v_o="$(jq -j "$EVALCLS_PROMPT_JQ" <<<"$line" 2>/dev/null \
               | LOCAL_MODEL_API=ollama bash "$cls" --report-faults 2>/dev/null)"; rc_o=$?
        v_n="$(jq -j "$EVALCLS_PROMPT_JQ" <<<"$line" 2>/dev/null \
               | LOCAL_MODEL_API=openai bash "$cls" --report-faults ${cfg:+--fleet-config "$cfg"} 2>/dev/null)"; rc_n=$?
        if (( rc_o != 0 || rc_n != 0 )); then
            faults=$((faults + 1)); eq=false
        elif [[ "$v_o" == "$v_n" ]]; then
            equal=$((equal + 1)); eq=true
        else
            differ=$((differ + 1)); eq=false
        fi
        jq -nc --arg id "$id" --arg o "$v_o" --arg n "$v_n" --argjson eq "$eq" \
               --argjson fo "$([[ $rc_o -ne 0 ]] && echo true || echo false)" \
               --argjson fn "$([[ $rc_n -ne 0 ]] && echo true || echo false)" \
               '{id: $id, ollama: $o, openai: $n, equal: $eq, fault_ollama: $fo, fault_openai: $fn}' >> "$rows"
    done < <(cat -- "${fix[@]}")

    local rec="$state/parallel-verify/pv-$stamp.jsonl" rec_sha zero=false
    (( n > 0 && differ == 0 && faults == 0 )) && zero=true
    (
        umask 077
        exec 9>>"$state/.lock"
        flock -w 10 9 || exit 4
        {
            jq -nc --arg time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg model "$model" \
                   --arg model_sha "$model_sha" --arg prompt_sha "$prompt_sha" \
                   --arg settings_sha "$settings_sha" --arg fix_sha "$fix_sha" \
                   --argjson n "$n" --argjson eq "$equal" --argjson d "$differ" --argjson f "$faults" \
                   --argjson zero "$zero" \
                   '{kind: "parallel-verify", time: $time, transports: ["ollama", "openai"],
                     model: $model, model_sha256: $model_sha, prompt_sha256: $prompt_sha,
                     settings_sha256: $settings_sha, fixtures_sha256: $fix_sha,
                     cases: $n, equal: $eq, differ: $d, faults: $f, zero_diff: $zero}'
            cat "$rows"
        } > "$rec"
        if [[ "$zero" == true ]]; then
            rec_sha="$(sha256sum < "$rec" | cut -d' ' -f1)"
            jq -nc --arg time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg rec "$(basename "$rec")" \
                   --arg rec_sha "$rec_sha" --arg model "$model" --arg model_sha "$model_sha" \
                   --arg prompt_sha "$prompt_sha" --arg settings_sha "$settings_sha" \
                   --arg fix_sha "$fix_sha" --argjson n "$n" \
                   '{kind: "zero-diff", time: $time, record: $rec, record_sha256: $rec_sha,
                     model: $model, model_sha256: $model_sha, prompt_sha256: $prompt_sha,
                     settings_sha256: $settings_sha, fixtures_sha256: $fix_sha, cases: $n}' \
                >> "$state/zero-diff.jsonl"
            chmod 600 "$state/zero-diff.jsonl"
        fi
    ) || { rm -f "$rows"; evalcls_pv_die 4 "could not write the record"; }
    rm -f "$rows"

    echo "parallel-verify: $n cases, $equal equal, $differ differ, $faults faults"
    echo "record: $rec"
    if [[ "$zero" == true ]]; then
        printf '  OK  zero-diff record written: %s\n' "$state/zero-diff.jsonl"
        return 0
    fi
    printf ' FAIL no zero-diff record written (%s differ, %s faults, %s cases)\n' "$differ" "$faults" "$n"
    return 3
}

evalcls_main() {
    if [[ "${1:-}" == --parallel-verify ]]; then
        shift
        evalcls_parallel_verify "$@"
        return
    fi
    evalcls_score "$@"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    evalcls_main "$@"
fi
