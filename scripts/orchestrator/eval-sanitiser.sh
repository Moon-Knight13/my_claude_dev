#!/usr/bin/env bash
# eval-sanitiser.sh — measure whether sanitise.sh actually strips known
# identifiers before a cloud handoff. Runs against a LIVE local model, so it is an
# on-box manual tool, not a CI gate (the contract is covered by test-sanitiser.sh).
#
# Metric: MARKER SURVIVAL. Each case carries a prompt plus identifier strings that
# must NOT appear in the sanitised output. A surviving marker is a leak-through.
# Objective even for an LLM sanitiser (exact-string check).
set -uo pipefail

_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAN="${ORCH_SANITISER:-$_HERE/sanitise.sh}"

# case = "<prompt>@@<marker>|<marker>|..."  (markers are exact strings)
cases=(
  "Refactor the billing module owned by Jane Roe (jane.roe@example.com).@@Jane Roe|jane.roe@example.com"
  "Fix the slow query on db-prod-01.internal at 10.4.9.2.@@db-prod-01.internal|10.4.9.2"
  "Our customer Wayne Industries is on plan tier 3; summarise usage.@@Wayne Industries"
  "Update the connector using token sk-internal-9f3a2b and retry.@@sk-internal-9f3a2b"
  "Document the codename-Falcon service owned by bob.smith@example.com.@@codename-Falcon|bob.smith@example.com"
)

total=0; stripped=0; failed=0
for c in "${cases[@]}"; do
    prompt="${c%%@@*}"; markers="${c#*@@}"
    out="$(printf '%s' "$prompt" | bash "$SAN" 2>/dev/null)" || { echo "!! sanitise FAILED: ${prompt:0:60}"; failed=$((failed+1)); continue; }
    echo "--------------------------------------------------------------------"
    echo "before: $prompt"
    echo "after : $out"
    IFS='|' read -ra MK <<<"$markers"
    for m in "${MK[@]}"; do
        total=$((total+1))
        if grep -qF -- "$m" <<<"$out"; then
            echo "  LEAK: '$m' survived"
        else
            stripped=$((stripped+1))
        fi
    done
done

echo "===================================================================="
echo "markers stripped: $stripped/$total    sanitise failures: $failed"
echo "(a surviving marker = a leak-through; tune the sanitiser prompt for it)"
# non-zero exit if anything leaked or a call failed, so a wrapper can gate
(( stripped == total && failed == 0 ))
