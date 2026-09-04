#!/usr/bin/env bash
# eval-classifier.sh — measure the sensitivity classifier against labelled
# fixtures. Runs against a LIVE local model, so this is an on-box manual tool, not
# a CI gate (the deterministic contract is covered by scripts/tests/test-classifier.sh).
#
# The headline metric is SENSITIVE RECALL: of the truly-sensitive cases, how many
# the classifier caught. A miss here (false negative) is a potential leak — that
# is the number to drive toward 100% by tuning the classifier prompt.
#
# Usage: eval-classifier.sh [fixtures.jsonl]
#   Env: ORCH_CLASSIFIER (defaults to the sibling classify-sensitivity.sh),
#        plus the classifier's own ORCH_CLASSIFIER_* / LOCAL_MODEL_* knobs.
set -uo pipefail

_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIX="${1:-$_HERE/../tests/fixtures/sensitivity-eval.jsonl}"
CLS="${ORCH_CLASSIFIER:-$_HERE/classify-sensitivity.sh}"

[[ -f "$FIX" ]] || { echo "eval: fixtures not found: $FIX" >&2; exit 1; }
[[ -x "$CLS" || -f "$CLS" ]] || { echo "eval: classifier not found: $CLS" >&2; exit 1; }

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
done < "$FIX"

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
if (( FN > 0 )); then
    echo "!! MISSED SENSITIVE (leaks) — tune the prompt for these:"
    for m in "${MISSES[@]}"; do echo "   - $m"; done
else
    echo "no missed sensitive cases."
fi
if (( FP > 0 )); then
    echo "false alarms (kept local unnecessarily — friction, not a leak):"
    for f in "${FALARMS[@]}"; do echo "   - $f"; done
fi
# Non-zero exit if any sensitive case leaked, so a wrapper/CI-on-box can gate.
(( FN == 0 ))
