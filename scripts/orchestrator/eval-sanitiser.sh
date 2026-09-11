#!/usr/bin/env bash
# eval-sanitiser.sh — measure whether sanitise.sh actually strips known
# identifiers before a cloud handoff. Runs against a LIVE local model, so it is an
# on-box manual tool, not a CI gate (the contract is covered by test-sanitiser.sh).
#
# Metric: MARKER SURVIVAL. Each case carries a prompt plus identifier strings that
# must NOT appear in the sanitised output. A surviving marker is a leak-through.
# Objective even for an LLM sanitiser (exact-string check).
#
# PRIVACY: stdout carries AGGREGATE NUMBERS ONLY. The before/after text and the
# surviving markers go to a private report instead. The shipped cases are invented,
# but the whole point of tuning is to add YOUR markers — real internal hostnames and
# codenames — and printing a surviving marker to the terminal is printing the thing
# you are trying to keep off a cloud model, into your scrollback and transcript.
# The report lives under ~/.config/orchestrator/, already hidden from Claude's tools.
#
#   Env: ORCH_SANITISER, ORCH_EVAL_SAN_REPORT (where detail is written)
set -uo pipefail

_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAN="${ORCH_SANITISER:-$_HERE/sanitise.sh}"
REPORT="${ORCH_EVAL_SAN_REPORT:-$HOME/.config/orchestrator/eval-sanitiser-report.txt}"

# case = "<prompt>@@<marker>|<marker>|..."  (markers are exact strings)
cases=(
  "Refactor the billing module owned by Jane Roe (jane.roe@example.com).@@Jane Roe|jane.roe@example.com"
  "Fix the slow query on db-prod-01.internal at 10.4.9.2.@@db-prod-01.internal|10.4.9.2"
  "Our customer Wayne Industries is on plan tier 3; summarise usage.@@Wayne Industries"
  "Update the connector using token sk-internal-9f3a2b and retry.@@sk-internal-9f3a2b"
  "Document the codename-Falcon service owned by bob.smith@example.com.@@codename-Falcon|bob.smith@example.com"
)

mkdir -p "$(dirname "$REPORT")" 2>/dev/null || true
umask 077
: > "$REPORT" 2>/dev/null || true
_rpt() { printf '%s\n' "$*" >> "$REPORT" 2>/dev/null || true; }
_rpt "=== sanitiser eval detail — $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

total=0; stripped=0; failed=0; leaked=0; case_no=0
for c in "${cases[@]}"; do
    case_no=$((case_no+1))
    prompt="${c%%@@*}"; markers="${c#*@@}"
    if ! out="$(printf '%s' "$prompt" | bash "$SAN" 2>/dev/null)"; then
        # Case NUMBER on stdout; the prompt itself only ever reaches the report.
        echo "case $case_no: sanitise FAILED"
        _rpt ""; _rpt "case $case_no: sanitise FAILED"; _rpt "  before: $prompt"
        failed=$((failed+1)); continue
    fi
    _rpt ""
    _rpt "case $case_no"
    _rpt "  before: $prompt"
    _rpt "  after : $out"
    IFS='|' read -ra MK <<<"$markers"
    for m in "${MK[@]}"; do
        total=$((total+1))
        if grep -qF -- "$m" <<<"$out"; then
            _rpt "  LEAK: '$m' survived"
            leaked=$((leaked+1))
        else
            stripped=$((stripped+1))
        fi
    done
done

echo "===================================================================="
echo "markers stripped: $stripped/$total    sanitise failures: $failed"
echo "(a surviving marker = a leak-through; tune the sanitiser prompt for it)"
if (( leaked > 0 )); then
    echo "markers that survived: $leaked   <-- see the report for which"
fi
echo
echo "per-case detail (before/after text, and which markers survived) written to:"
echo "  $REPORT"
echo "It is owner-only and hidden from Claude's tools. The markers are not printed"
echo "here, because this output goes to your terminal and transcript."
# non-zero exit if anything leaked or a call failed, so a wrapper can gate
(( stripped == total && failed == 0 ))
