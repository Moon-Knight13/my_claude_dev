#!/usr/bin/env bash
# test-term-floor.sh — the deterministic term-list floor (#65).
#
# The floor exists to catch what the LLM judge misses. That only holds if the
# LLM is NOT what checks it, so these tests pin two things above all:
#   1. a listed term forces `sensitive` with the classifier never invoked, and
#      in EVERY mode — including CLAUDE-ONLY, where the human asserted the
#      opposite and the classifier is skipped entirely;
#   2. the matched term never appears in a verdict, on stderr, or in the log —
#      a control built to prevent disclosure must not become the discloser.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok()   { echo "  OK  $1"; ((PASS++)) || true; }
bad()  { echo " FAIL $1"; ((FAIL++)) || true; }
check(){ if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
CONF="$TMP/orch.conf"
cat > "$CONF" <<'EOF'
ORCH_MODE=AUTO
ORCH_MODEL=claude|frontier|100|
ORCH_MODEL=qwen-host|host-local|60|http://host.docker.internal:11434
EOF

TERMS="$TMP/terms.txt"
cat > "$TERMS" <<'EOF'
# private term list — comments and blanks are ignored
Bluefin
atlas
acme-corp

VERYSECRETPROJECT
EOF

# shellcheck source=/dev/null
source "$ROOT/scripts/lib/orchestrator-route.sh"
orch_load_config "$CONF"

# hit <prompt> -> "hit" | "miss"
hit() { if ORCH_TERM_LIST="$TERMS" orch_floor_match "$1"; then echo hit; else echo miss; fi; }

echo "== the floor matches listed terms =="
check "exact term"                 "$(hit 'deploy the Bluefin service')"        hit
check "case-insensitive (lower)"   "$(hit 'deploy the bluefin service')"        hit
check "case-insensitive (upper)"   "$(hit 'deploy the BLUEFIN service')"        hit
check "term with a hyphen"         "$(hit 'onboard acme-corp today')"           hit
check "term at start of prompt"    "$(hit 'atlas needs a refactor')"            hit
check "term at end of prompt"      "$(hit 'the project is called atlas')"       hit
check "term before punctuation"    "$(hit 'is atlas, or not?')"                 hit
check "unlisted prompt"            "$(hit 'refactor the parser module')"        miss

echo "== word-boundary, not substring (an unbounded match routes everything local) =="
check "atlas does not match atlassian"  "$(hit 'we use atlassian tools')"       miss
check "atlas does not match catalyst"   "$(hit 'the catalyst pattern')"         miss
check "atlas does not match atlases"    "$(hit 'two atlases on the shelf')"     miss

echo "== list hygiene =="
check "comment lines ignored"      "$(hit 'a private term list comment')"       miss
check "blank lines ignored"        "$(hit '')"                                  miss
EMPTY="$TMP/empty.txt"; : > "$EMPTY"
if ORCH_TERM_LIST="$EMPTY" orch_floor_match 'anything at all'; then bad "empty list must not match"; else ok "empty list -> floor inactive"; fi
if ORCH_TERM_LIST="$TMP/does-not-exist" orch_floor_match 'anything at all'; then bad "missing list must not match"; else ok "missing list -> floor inactive, not an error"; fi

echo "== minimum term length is enforced at load, loudly =="
SHORT="$TMP/short.txt"; printf 'ab\nBluefin\n' > "$SHORT"
_err="$(ORCH_TERM_LIST="$SHORT" orch_floor_match 'the letters ab appear here' 2>&1 >/dev/null)" || true
if ORCH_TERM_LIST="$SHORT" orch_floor_match 'the letters ab appear here'; then bad "too-short term must not match"; else ok "too-short term is not used for matching"; fi
if [[ -n "$_err" ]]; then ok "too-short term is rejected loudly (stderr)"; else bad "too-short term rejected silently"; fi
if ORCH_TERM_LIST="$SHORT" orch_floor_match 'deploy Bluefin now'; then ok "valid terms still work alongside a rejected one"; else bad "valid term lost"; fi

echo "== the floor never names the term it matched =="
_out="$(ORCH_TERM_LIST="$TERMS" orch_floor_match 'deploy the Bluefin service' 2>&1)" || true
if [[ "$_out" != *[Bb]luefin* ]]; then ok "match output does not contain the term"; else bad "match output leaked the term"; fi

# ============================================================================
echo "== front door: the floor overrides the mode (R1) =="
ORCH="$ROOT/scripts/orchestrator/orchestrate.sh"
LOG="$TMP/log.jsonl"
# A classifier that would say 'nonsensitive' — proves the floor does not consult it.
CL="$TMP/cl.sh"; printf '#!/usr/bin/env bash\ntouch "%s/classifier-was-called"\necho nonsensitive\n' "$TMP" > "$CL"; chmod +x "$CL"

run() { # run <mode> <prompt> -> dry-run decision line
    rm -f "$TMP/classifier-was-called"
    ORCH_CONF="$CONF" ORCH_LOG="$LOG" ORCH_TERM_LIST="$TERMS" ORCH_CLASSIFIER="$CL" \
        bash "$ORCH" --mode "$1" --dry-run "$2" 2>/dev/null
}
field() { printf '%s' "$1" | tr ' ' '\n' | grep "^$2=" | cut -d= -f2; }

_r="$(run CLAUDE-ONLY 'deploy the Bluefin service')"
check "CLAUDE-ONLY + term -> sensitive" "$(field "$_r" sensitive)" sensitive
check "CLAUDE-ONLY + term -> local tier" "$(field "$_r" tier)"     host-local
if [[ ! -f "$TMP/classifier-was-called" ]]; then ok "floor short-circuits: classifier never called"; else bad "classifier was called"; fi

_r="$(run CLAUDE-ONLY 'refactor the parser module')"
check "CLAUDE-ONLY, no term -> nonsensitive" "$(field "$_r" sensitive)" nonsensitive
check "CLAUDE-ONLY, no term -> frontier"     "$(field "$_r" tier)"      frontier

_r="$(run AUTO 'deploy the Bluefin service')"
check "AUTO + term -> sensitive"   "$(field "$_r" sensitive)" sensitive
check "AUTO + term -> local tier"  "$(field "$_r" tier)"      host-local

_r="$(run LOCAL-ONLY 'deploy the Bluefin service')"
check "LOCAL-ONLY + term -> sensitive" "$(field "$_r" sensitive)" sensitive
check "LOCAL-ONLY + term -> local"     "$(field "$_r" tier)"      host-local

echo "== the log records the floor without naming the term =="
if grep -q '"floor":true' "$LOG" 2>/dev/null; then ok "log records that the floor fired"; else bad "log does not record the floor"; fi
if ! grep -qi 'bluefin' "$LOG" 2>/dev/null; then ok "log never contains the term"; else bad "LOG LEAKED THE TERM"; fi
if ! grep -qi 'deploy the' "$LOG" 2>/dev/null; then ok "log never contains the prompt"; else bad "log leaked the prompt"; fi

echo "== stderr never names the term =="
_e="$(ORCH_CONF="$CONF" ORCH_LOG="$LOG" ORCH_TERM_LIST="$TERMS" ORCH_CLASSIFIER="$CL" \
      bash "$ORCH" --mode CLAUDE-ONLY --dry-run 'deploy the Bluefin service' 2>&1 >/dev/null)" || true
if [[ "$_e" != *[Bb]luefin* ]]; then ok "stderr does not name the term"; else bad "stderr leaked the term"; fi

# ============================================================================
# The orchestrator's own private files are protected WITHOUT the owner having to
# configure anything. A setup step you can forget is a control that fails open —
# and the term list is the single most sensitive file on the box.
echo "== private orchestrator files are guarded by default =="
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/ctp-guard.sh"

# Deliberately load a config that sets CTP_PII_PATHS to something ELSE. A default
# VALUE would be replaced by this and silently vanish; a built-in list must not be.
OWNCONF="$TMP/own.conf"; printf 'CTP_PII_PATHS=~/org-data/**\n' > "$OWNCONF"
ctp_load_config "$OWNCONF"

guarded() { if ctp_is_pii_path "$1"; then echo yes; else echo no; fi; }
check "term list guarded by default"        "$(guarded "$HOME/.config/orchestrator/term-list.txt")"       yes
check "classifier prompt guarded by default" "$(guarded "$HOME/.config/orchestrator/classifier-prompt.md")" yes
check "sanitiser prompt guarded by default"  "$(guarded "$HOME/.config/orchestrator/sanitiser-prompt.md")"  yes
check "owner's own PII path still guarded"   "$(guarded "$HOME/org-data/clients.csv")"                      yes
check "unrelated file not guarded"           "$(guarded "$HOME/notes.txt")"                                 no
check "repo's generic default NOT guarded"   "$(guarded "$ROOT/scripts/orchestrator/term-list.example.txt")" no

# And with NO config loaded at all — the opt-in list empty, as it ships.
ctp_load_config /nonexistent-conf-file 2>/dev/null || true
# Read by ctp_is_pii_path in the sourced guard lib, not in this file.
# shellcheck disable=SC2034
CTP_PII_PATHS=""
check "guarded even with empty CTP_PII_PATHS" "$(guarded "$HOME/.config/orchestrator/term-list.txt")" yes

echo
echo "term-floor: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
