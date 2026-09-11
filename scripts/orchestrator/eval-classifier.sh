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
#   Env: ORCH_CLASSIFIER (defaults to the sibling classify-sensitivity.sh),
#        ORCH_EVAL_FIXTURES (private fixtures, ADDED to the committed set),
#        ORCH_EVAL_REPORT   (where per-case detail is written),
#        plus the classifier's own ORCH_CLASSIFIER_* / LOCAL_MODEL_* knobs.
set -uo pipefail

_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIX="${1:-$_HERE/../tests/fixtures/sensitivity-eval.jsonl}"
CLS="${ORCH_CLASSIFIER:-$_HERE/classify-sensitivity.sh}"
# Private fixtures are ADDED to the committed set, not a replacement: the shipped
# synthetic cases stay as regression coverage while real ones accumulate privately.
PRIV_FIX="${ORCH_EVAL_FIXTURES:-$HOME/.config/orchestrator/fixtures/sensitivity-eval.jsonl}"
REPORT="${ORCH_EVAL_REPORT:-$HOME/.config/orchestrator/eval-classifier-report.txt}"

[[ -f "$FIX" ]] || { echo "eval: fixtures not found: $FIX" >&2; exit 1; }
[[ -x "$CLS" || -f "$CLS" ]] || { echo "eval: classifier not found: $CLS" >&2; exit 1; }

priv_note=""
[[ -f "$PRIV_FIX" ]] && priv_note=" + private"

TP=0; FP=0; TN=0; FN=0; N=0
declare -a MISSES=() FALARMS=()

while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    prompt="$(jq -r '.prompt' <<<"$line" 2>/dev/null)" || continue
    label="$(jq -r '.label'  <<<"$line" 2>/dev/null)"
    note="$(jq -r '.note // ""' <<<"$line" 2>/dev/null)"
    [[ "$label" == "sensitive" || "$label" == "nonsensitive" ]] || continue
    verdict="$(bash "$CLS" "$prompt" 2>/dev/null)"
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
