#!/usr/bin/env bash
# test-eval-privacy.sh — the evals must not print what they exist to protect (#64).
#
# Both evals are on-box tools pointed at REAL material once tuning starts: the
# classifier eval grows from real misses, and the sanitiser eval's markers are real
# internal hostnames and codenames. Anything they print lands in a terminal, in
# scrollback, and in a session transcript.
#
# So: stdout carries aggregate numbers only. Case detail goes to a private report
# under ~/.config/orchestrator/, which the C1 guard already hides from Claude.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok()   { echo "  OK  $1"; ((PASS++)) || true; }
bad()  { echo " FAIL $1"; ((FAIL++)) || true; }
check(){ if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP"
REPORT_DIR="$HOME/.config/orchestrator"

# ---------------------------------------------------------------------------
echo "== classifier eval =="
# Fixtures whose NOTE text is a distinctive string we can hunt for in output.
FIX="$TMP/fix.jsonl"
cat > "$FIX" <<'EOF'
{"prompt":"handle the zzsecretnote account","label":"sensitive","note":"zzleakynote-missed-case"}
{"prompt":"refactor the parser","label":"nonsensitive","note":"zzleakynote-false-alarm"}
EOF
# A classifier that gets BOTH wrong, so both the miss list and the false-alarm
# list are populated — those are the two places detail gets printed.
CLS="$TMP/cls.sh"
cat > "$CLS" <<'MOCK'
#!/usr/bin/env bash
case "$1" in
    *zzsecretnote*) echo nonsensitive ;;
    *)              echo sensitive ;;
esac
MOCK
chmod +x "$CLS"

OUT="$(ORCH_CLASSIFIER="$CLS" bash "$ROOT/scripts/orchestrator/eval-classifier.sh" "$FIX" 2>/dev/null)" || true

if [[ "$OUT" != *zzleakynote* ]]; then ok "stdout carries no fixture note text"; else bad "STDOUT LEAKED fixture notes"; fi
if [[ "$OUT" != *zzsecretnote* ]]; then ok "stdout carries no fixture prompt text"; else bad "STDOUT LEAKED fixture prompts"; fi
case "$OUT" in *"SENSITIVE RECALL"*) ok "stdout still reports the headline metric" ;; *) bad "headline metric missing" ;; esac
case "$OUT" in *"2 cases"*|*"(2 "*) ok "stdout still reports the case count" ;; *) bad "case count missing" ;; esac

RPT="$REPORT_DIR/eval-classifier-report.txt"
if [[ -f "$RPT" ]]; then ok "detail report written"; else bad "no detail report written"; fi
if grep -q zzleakynote "$RPT" 2>/dev/null; then ok "report contains the case detail"; else bad "report missing case detail"; fi
check "report is owner-only (600)" "$(stat -c '%a' "$RPT" 2>/dev/null)" 600
case "$OUT" in *"$RPT"*|*"eval-classifier-report.txt"*) ok "stdout points at the report" ;; *) bad "stdout does not say where detail went" ;; esac

echo "== classifier eval: private fixtures are used alongside the committed ones =="
PRIV="$REPORT_DIR/fixtures/sensitivity-eval.jsonl"
mkdir -p "$(dirname "$PRIV")"
cat > "$PRIV" <<'EOF'
{"prompt":"the zzprivatecase project","label":"sensitive","note":"zzprivnote"}
EOF
OUT2="$(ORCH_CLASSIFIER="$CLS" bash "$ROOT/scripts/orchestrator/eval-classifier.sh" "$FIX" 2>/dev/null)" || true
case "$OUT2" in *"3 cases"*) ok "private fixtures added to the committed set" ;; *) bad "private fixtures not picked up ($OUT2)" ;; esac
if [[ "$OUT2" != *zzprivnote* && "$OUT2" != *zzprivatecase* ]]; then ok "private fixture content stays off stdout"; else bad "STDOUT LEAKED private fixture"; fi

# ---------------------------------------------------------------------------
echo "== sanitiser eval =="
# A sanitiser that returns the prompt unchanged: every marker survives, so the
# leak-reporting path is exercised for every case.
SAN="$TMP/san.sh"; printf '#!/usr/bin/env bash\ncat\n' > "$SAN"; chmod +x "$SAN"
SOUT="$(ORCH_SANITISER="$SAN" bash "$ROOT/scripts/orchestrator/eval-sanitiser.sh" 2>/dev/null)" || true

if [[ "$SOUT" != *"db-prod-01.internal"* ]]; then ok "stdout carries no marker strings"; else bad "STDOUT LEAKED a marker"; fi
if [[ "$SOUT" != *"codename-Falcon"* ]]; then ok "stdout carries no codename marker"; else bad "STDOUT LEAKED a codename"; fi
if [[ "$SOUT" != *"Refactor the billing module"* ]]; then ok "stdout carries no prompt text"; else bad "STDOUT LEAKED prompt text"; fi
case "$SOUT" in *"markers stripped"*) ok "stdout still reports the metric" ;; *) bad "sanitiser metric missing" ;; esac

SRPT="$REPORT_DIR/eval-sanitiser-report.txt"
if [[ -f "$SRPT" ]]; then ok "sanitiser detail report written"; else bad "no sanitiser report written"; fi
if grep -q "db-prod-01.internal" "$SRPT" 2>/dev/null; then ok "sanitiser report contains detail"; else bad "sanitiser report missing detail"; fi
check "sanitiser report is owner-only (600)" "$(stat -c '%a' "$SRPT" 2>/dev/null)" 600

# ---------------------------------------------------------------------------
echo "== the reports are already hidden from Claude (no config needed) =="
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/ctp-guard.sh"
# Read by ctp_is_pii_path in the sourced guard lib, not in this file.
# shellcheck disable=SC2034
CTP_PII_PATHS=""   # owner's opt-in half empty, as it ships
guarded() { if ctp_is_pii_path "$1"; then echo yes; else echo no; fi; }
check "classifier report guarded" "$(guarded "$RPT")"   yes
check "sanitiser report guarded"  "$(guarded "$SRPT")"  yes
check "private fixtures guarded"  "$(guarded "$PRIV")"  yes

echo
echo "eval-privacy: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
