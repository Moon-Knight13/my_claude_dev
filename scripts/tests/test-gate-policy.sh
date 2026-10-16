#!/usr/bin/env bash
# `cond && ok … || bad …` is safe in this file: ok and bad always return 0.
# shellcheck disable=SC2015
# test-gate-policy.sh — the private policy repository, the strict policy loader,
# and policy_version (SP1a story 2.2, #105; AD-1, AD-7, AD-19, FR-10, FR-13,
# FR-23, FR-50).
# tier: ci — a local bare-repo fixture with synthetic terms; no root.
#
# Every synthetic term starts "zz" and the short ones "zq", so the suite can
# check that no output, event, or record ever carries one.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LANE2="$ROOT/scripts/hub/lane2"
LIB="$ROOT/scripts/lib/lane2.sh"
GATE="$ROOT/scripts/lib/gate.sh"
PASS=0; FAIL=0
ok()   { echo "  OK  $1"; ((PASS++)) || true; }
bad()  { echo " FAIL $1"; ((FAIL++)) || true; }
check(){ if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (no '$3' in output)"; printf '%s\n' "$2" | sed 's/^/      | /' ;; esac; }
hasnt(){ case "$2" in *"$3"*) bad "$1 ('$3' found)" ;; *) ok "$1" ;; esac; }
noterms() { # noterms <label> <text> — no synthetic term or short entry leaked
    if grep -qiE 'zz[a-z]+|zq' <<<"$2"; then bad "$1: a term leaked"; else ok "$1: no term in it"; fi
}

TMP="$(mktemp -d)"; trap 'chmod -R u+rwX "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
G() { git -c user.name=t -c user.email=t@example.invalid -c init.defaultBranch=main "$@"; }

# --- fixture policy repository ----------------------------------------------
P="$TMP/policy"; PB="$TMP/policy.git"
G init -q "$P"; G init -q --bare "$PB"
pol_commit() { # pol_commit <msg> — commit the work tree and push to the bare repo
    G -C "$P" add -A; G -C "$P" commit -qm "$1" --allow-empty; G -C "$P" push -q "$PB" HEAD:main
}
printf '# synthetic policy\nzzalpha\nzzbravo\nzzcharlie\nzq\n' > "$P/term-list.txt"
printf 'Classify the text. Reply sensitive or nonsensitive.\n' > "$P/classifier-prompt.md"
pol_commit good1

# --- hub layout --------------------------------------------------------------
CONF="$TMP/etc"; STATE="$TMP/state"; PREFIX="$TMP/opt"
mkdir -p "$CONF" "$PREFIX/c1/scripts/lib" "$STATE"; chmod 755 "$STATE"
echo 'echo gate' > "$PREFIX/c1/scripts/lib/gate.sh"; ln -s c1 "$PREFIX/current"
SHA="$(printf 'a%.0s' {1..64})"
writeconf() {
    { echo "LANE2_OPERATOR=$(id -un)"; echo "LANE2_PREFIX=$PREFIX"; echo "LANE2_STATE_ROOT=$STATE"
      echo "LANE2_POLICY_REPO=file://$PB"; } > "$CONF/lane2.conf"
    printf 'FLEET_CLASSIFIER_MODEL=classifier-fixture\nFLEET_CLASSIFIER_SHA256=%s\nFLEET_RUNTIME_BUILD=b1234\n' "$SHA" > "$CONF/fleet.conf"
}
writeconf

# Function overrides spliced into each `bash -c`; expanded there, not here.
# shellcheck disable=SC2016
OVR='
    lane2_in_container() { return 1; }
    lane2_uid() { id -u; }
    lane2_gid() { id -g; }
    lane2_chown() { :; }
    lane2_is_operator() { [[ -z "${T_NOTOP:-}" ]]; }
    if [[ -z "${T_REAL_REPO:-}" ]]; then lane2_check_policy_repo() { [[ "$1" == file://* ]]; }; fi
    LANE2_GIT_FILE_PROTOCOL=always'
bash -c "source \"\$1\"; $OVR; lane2_ensure_stores \"\$2\" >/dev/null" _ "$LANE2" "$STATE" \
    || { echo " FAIL could not create fixture stores"; exit 1; }
EVENTS="$STATE/events/policy.jsonl"
STORE="$STATE/gate-policy"

L() { bash -c "source \"\$1\"; shift; $OVR; lane2_main \"\$@\"" _ "$LANE2" --config-dir "$CONF" "$@"; }
run() { OUT="$(L policy update 2>&1)"; RC=$?; }
cur() { readlink "$STORE/current" 2>/dev/null || echo none; }
ev() { grep -c "\"event\":\"$1\"" "$EVENTS" 2>/dev/null || true; }

# =============================================================================
echo "== update =="
run
check "update exits 0" "$RC" 0
C1="$(G -C "$P" rev-parse HEAD)"
check "current -> the fetched commit" "$(cur)" "trees/$C1"
has "short entry rejected by line number" "$OUT" "term-list line 5 rejected (under 3 characters)"
has "reports counts" "$OUT" "validated: 3 term(s), 1 rejected"
noterms "update output" "$OUT"
S="$STORE/state.json"
check "state: terms" "$(jq -r .terms "$S")" 3
check "state: rejected" "$(jq -r .rejected_short "$S")" 1
check "state: removed" "$(jq -r .removed_since_previous "$S")" 0
PV1="$(jq -r .policy_version "$S")"
[[ "$PV1" =~ ^[0-9a-f]{64}$ ]] && ok "policy_version computed" || bad "policy_version missing ($PV1)"
check "rejection recorded as a count" "$(jq -sr 'map(select(.event=="policy_terms_rejected"))[0].count' "$EVENTS")" 1
check "policy change event" "$(ev policy)" 1
noterms "event log" "$(cat "$EVENTS")"
hasnt "event log carries no policy_version" "$(cat "$EVENTS")" "$PV1"
check "term list is 0640 (gate group reads)" "$(stat -c %a "$STORE/current/term-list.txt")" 640
check "policy store still 2750" "$(stat -c %a "$STORE")" 2750

echo "== same content: same policy_version, no event =="
run
check "re-run exits 0" "$RC" 0
check "same policy_version" "$(jq -r .policy_version "$S")" "$PV1"
check "no new policy event" "$(ev policy)" 1
has "says unchanged" "$OUT" "policy_version unchanged"

echo "== removal counts and change =="
printf 'zzalpha\nzzcharlie\nzzdelta\nzzecho\n' > "$P/term-list.txt"; pol_commit good2
C2="$(G -C "$P" rev-parse HEAD)"
run
check "update exits 0" "$RC" 0
check "removed counted (zzbravo gone)" "$(jq -r .removed_since_previous "$S")" 1
has "reports the removal count" "$OUT" "removed since previous policy: 1"
PV2="$(jq -r .policy_version "$S")"
[[ "$PV2" != "$PV1" ]] && ok "policy_version changes with the term list" || bad "policy_version unchanged after a change"
check "second policy event" "$(ev policy)" 2
check "event carries counts" "$(jq -sr 'map(select(.event=="policy"))[1] | "\(.terms) \(.rejected) \(.removed)"' "$EVENTS")" "4 0 1"
noterms "removal output" "$OUT"
[[ -d "$STORE/trees/$C1" && -d "$STORE/trees/$C2" ]] && ok "previous tree kept as the snapshot" || bad "trees: $(ls "$STORE/trees")"
printf 'zzalpha\nzzcharlie\nzzdelta\n' > "$P/term-list.txt"; pol_commit good3
C3="$(G -C "$P" rev-parse HEAD)"
run
[[ ! -d "$STORE/trees/$C1" && -d "$STORE/trees/$C2" && -d "$STORE/trees/$C3" ]] \
    && ok "only current and previous trees kept" || bad "trees: $(ls "$STORE/trees")"

# =============================================================================
echo "== a failed fetch or validation keeps the previous policy =="
GOOD="$(cur)"; GOODPV="$(jq -r .policy_version "$S")"; NEV="$(wc -l < "$EVENTS")"
fails() { # fails <label> <expected FAIL text>
    run
    check "$1: exits 4" "$RC" 4
    has "$1: names the step" "$OUT" "$2"
    check "$1: previous policy in force" "$(cur)" "$GOOD"
    noterms "$1 output" "$OUT"
}
writeconf; sed -i "s|^LANE2_POLICY_REPO=.*|LANE2_POLICY_REPO=file://$TMP/missing.git|" "$CONF/lane2.conf"
fails "unreachable repo" " FAIL fetch:"
writeconf
: > "$P/term-list.txt"; pol_commit empty-terms
fails "empty term list" " FAIL validate: term list has no usable entry"
printf '# only comments\nzq\nzy\n' > "$P/term-list.txt"; pol_commit short-only
fails "comments and short entries only" " FAIL validate: term list has no usable entry (2 rejected)"
G -C "$P" rm -q term-list.txt; pol_commit no-terms
fails "missing term list" " FAIL validate: term-list.txt missing or unreadable"
printf 'zzalpha\n' > "$P/term-list.txt"; : > "$P/classifier-prompt.md"; pol_commit empty-prompt
fails "empty prompt" " FAIL validate: classifier-prompt.md missing or empty"
G -C "$P" rm -q classifier-prompt.md; pol_commit no-prompt
fails "missing prompt" " FAIL validate: classifier-prompt.md missing or empty"
printf 'Classify.\n' > "$P/classifier-prompt.md"; mkdir -p "$P/fixtures"
printf '{"prompt":"zzalpha"}\n' > "$P/fixtures/cases.jsonl"; pol_commit plaintext-fixture
fails "plaintext fixture" " FAIL validate: 1 plaintext fixture file(s)"
G -C "$P" rm -q fixtures/cases.jsonl; echo x > "$P/notes.txt"; pol_commit unknown-file
fails "unexpected file" " FAIL validate: 1 unexpected file(s)"
check "failures logged no policy event" "$(wc -l < "$EVENTS")" "$NEV"
check "failures left policy_version as it was" "$(jq -r .policy_version "$S")" "$GOODPV"
G -C "$P" rm -q notes.txt; mkdir -p "$P/fixtures"; printf 'binary-ish' > "$P/fixtures/cases.jsonl.gpg"; pol_commit encrypted-fixture
run
check "an encrypted fixture is accepted" "$RC" 0

echo "== refusals =="
OUT="$(DEVCONTAINER=true bash "$LANE2" --config-dir "$CONF" policy update 2>&1)"; RC=$?
check "inside a container (exit 4)" "$RC" 4
has "says run on the hub" "$OUT" " FAIL run on the hub"
OUT="$(T_NOTOP=1 L policy update 2>&1)"; RC=$?
check "not the operator (exit 4)" "$RC" 4
has "says operator" "$OUT" "must run as the operator"
sed -i "s|^LANE2_POLICY_REPO=.*|LANE2_POLICY_REPO=$PB|" "$CONF/lane2.conf"
OUT="$(T_REAL_REPO=1 L policy update 2>&1)"; RC=$?
check "local-path policy repo (exit 4)" "$RC" 4
has "says local paths are refused" "$OUT" "local paths are refused"
writeconf
chmod 2770 "$STORE"; run
check "policy store with a looser mode (exit 4)" "$RC" 4
chmod 2750 "$STORE"
writeconf; sed -i "s|^LANE2_STATE_ROOT=.*|LANE2_STATE_ROOT=$HOME/lane2-state|" "$CONF/lane2.conf"
run
check "state root inside the operator's home (exit 4)" "$RC" 4
writeconf
for u in "git@example.invalid:me/policy.git" "ssh://git@example.invalid/me/policy.git" "https://example.invalid/me/policy.git"; do
    bash -c 'source "$1"; lane2_check_policy_repo "$2"' _ "$LIB" "$u" && ok "accepts $u" || bad "refused $u"
done
for u in "$PB" "file://$PB" "./policy" "https://u:tok@example.invalid/p.git"; do
    bash -c 'source "$1"; lane2_check_policy_repo "$2"' _ "$LIB" "$u" && bad "accepted $u" || ok "refuses $u"
done

# =============================================================================
echo "== strict loader and floor vs lenient orch_floor_match =="
PD="$TMP/pd"; mkdir -p "$PD/t"; ln -s t "$PD/current"
printf 'zzalpha\n' > "$PD/t/term-list.txt"; printf 'Classify.\n' > "$PD/t/classifier-prompt.md"
ME="$(id -un)"
gl() { bash -c 'source "$1"; gate_policy_load "$2" "$3"' _ "$GATE" "$PD" "${1:-$ME}"; }
gl && ok "valid policy loads" || bad "valid policy refused"
gl nobody; check "a caller that is neither operator nor gate is refused" "$?" 4
mv "$PD/t/term-list.txt" "$PD/t/x"; gl; check "missing term list faults" "$?" 4
: > "$PD/t/term-list.txt"; gl; check "empty term list faults" "$?" 4
printf '# c\nzq\n' > "$PD/t/term-list.txt"; gl; check "comments and short entries only fault" "$?" 4
mv "$PD/t/x" "$PD/t/term-list.txt"; chmod 000 "$PD/t/term-list.txt"; gl; check "unreadable term list faults" "$?" 4
chmod 644 "$PD/t/term-list.txt"
: > "$PD/t/classifier-prompt.md"; gl; check "empty prompt faults" "$?" 4
rm "$PD/t/classifier-prompt.md"; gl; check "missing prompt faults" "$?" 4
printf 'Classify.\n' > "$PD/t/classifier-prompt.md"

floor() { # floor <mode> <text>: prints rc of strict (gate) or lenient (orch) floor
    bash -c '
        source "$1"
        case "$2" in
            strict-unloaded) gate_floor_match "$4" ;;
            strict) gate_policy_load "$3" "$5" || exit 9; gate_floor_match "$4" ;;
            strict-vanished) cp -r "$3" "$3.v"; gate_policy_load "$3.v" "$5" || exit 9
                             rm -f "$3.v/current/term-list.txt"; gate_floor_match "$4" ;;
            lenient-missing) ORCH_TERM_LIST=/nonexistent/list orch_floor_match "$4" ;;
            lenient) ORCH_TERM_LIST="$3/current/term-list.txt" orch_floor_match "$4" ;;
        esac; echo "rc=$?"' _ "$GATE" "$1" "$PD" "$2" "$ME" 2>/dev/null | tail -1
}
check "lenient: missing list means no hit" "$(floor lenient-missing 'about zzalpha')" "rc=1"
check "strict: policy not loaded is a fault" "$(floor strict-unloaded 'about zzalpha')" "rc=4"
check "lenient: hit" "$(floor lenient 'about zzalpha')" "rc=0"
check "strict: hit" "$(floor strict 'about zzalpha')" "rc=0"
check "strict: no hit" "$(floor strict 'about nothing')" "rc=1"
check "strict: term list gone after load is a fault, not no-hit" "$(floor strict-vanished 'about zzalpha')" "rc=4"
check "strict: environment cannot point the floor elsewhere" \
    "$(ORCH_TERM_LIST=/nonexistent ORCH_TERM_MIN_LEN=99 bash -c 'source "$1"; gate_policy_load "$2" "$3"; gate_floor_match "about zzalpha"; echo "rc=$?"' _ "$GATE" "$PD" "$ME" 2>/dev/null)" "rc=0"

echo "== policy_version =="
T="$PD/t/term-list.txt"; PR="$PD/t/classifier-prompt.md"; GD="$(printf 'b%.0s' {1..64})"
pv() { bash -c 'source "$1"; shift; gate_policy_version "$@"' _ "$GATE" "$@" 2>/dev/null; }
V="$(pv "$T" "$PR" model "$SHA" b1234 "$GD")"
[[ "$V" =~ ^[0-9a-f]{64}$ ]] && ok "computes a sha256" || bad "no version ($V)"
check "stable for the same inputs" "$(pv "$T" "$PR" model "$SHA" b1234 "$GD")" "$V"
cp "$T" "$TMP/t2"; echo zzextra >> "$TMP/t2"
[[ "$(pv "$TMP/t2" "$PR" model "$SHA" b1234 "$GD")" != "$V" ]] && ok "changes with the term list" || bad "term list not an input"
cp "$PR" "$TMP/p2"; echo more >> "$TMP/p2"
[[ "$(pv "$T" "$TMP/p2" model "$SHA" b1234 "$GD")" != "$V" ]] && ok "changes with the prompt" || bad "prompt not an input"
[[ "$(pv "$T" "$PR" model2 "$SHA" b1234 "$GD")" != "$V" ]] && ok "changes with the model id" || bad "model not an input"
[[ "$(pv "$T" "$PR" model "$(printf 'c%.0s' {1..64})" b1234 "$GD")" != "$V" ]] && ok "changes with the model checksum" || bad "checksum not an input"
[[ "$(pv "$T" "$PR" model "$SHA" v1.2.3 "$GD")" != "$V" ]] && ok "changes with the runtime build" || bad "build not an input"
[[ "$(pv "$T" "$PR" model "$SHA" b1234 "$SHA")" != "$V" ]] && ok "changes with the gate-code digest" || bad "gate digest not an input"
pv /nonexistent "$PR" model "$SHA" b1234 "$GD" >/dev/null; check "missing term list faults" "$?" 4
pv "$T" /nonexistent model "$SHA" b1234 "$GD" >/dev/null; check "missing prompt faults" "$?" 4
: > "$TMP/empty"; pv "$TMP/empty" "$PR" model "$SHA" b1234 "$GD" >/dev/null; check "empty term list faults" "$?" 4
pv "$T" "$PR" "" "$SHA" b1234 "$GD" >/dev/null; check "missing model id faults" "$?" 4
pv "$T" "$PR" model short b1234 "$GD" >/dev/null; check "malformed checksum faults" "$?" 4
pv "$T" "$PR" model "$SHA" latest "$GD" >/dev/null; check "malformed build tag faults" "$?" 4
pv "$T" "$PR" model "$SHA" b1234 "" >/dev/null; check "missing gate digest faults" "$?" 4
chmod 000 "$T"; pv "$T" "$PR" model "$SHA" b1234 "$GD" >/dev/null; check "unreadable term list faults" "$?" 4; chmod 644 "$T"
GCALLS="$(cd "$ROOT" && grep -rlE 'gate_policy_version' scripts --exclude-dir=tests 2>/dev/null | sort | tr '\n' ' ')"
check "policy_version computed only by the gate lib, lane2, and the gate (start of each request)" "$GCALLS" \
    "scripts/hub/gate-handler scripts/hub/lane2 scripts/lib/gate.sh "

# =============================================================================
echo "== public-repo hygiene =="
TRACKED="$(git -C "$ROOT" ls-files)"
check "only the example term list is tracked" \
    "$(grep -iE '(^|/)[^/]*term-?list[^/]*$' <<<"$TRACKED" | grep -vxF scripts/orchestrator/term-list.example.txt || true)" ""
check "no policy classifier prompt tracked" "$(grep -E '(^|/)classifier-prompt\.md$' <<<"$TRACKED" || true)" ""
REPOSET="$(git -C "$ROOT" grep -nE 'LANE2_POLICY_REPO=[^<[:space:]"]' -- ':!scripts/tests' 2>/dev/null || true)"
check "no policy repository URL tracked" "$REPOSET" ""
PVHEX="$(git -C "$ROOT" grep -niE 'policy_version[^0-9a-f]{0,40}[0-9a-f]{64}' -- ':!scripts/tests' 2>/dev/null || true)"
check "no policy_version value tracked" "$PVHEX" ""
CIHITS="$(git -C "$ROOT" grep -lE 'gate-policy|term-list\.txt|LANE2_POLICY_REPO|policy_version' -- .github .devcontainer scripts/hub/container 2>/dev/null || true)"
check "CI and container definitions never reference the policy" "$CIHITS" ""
DOC="$ROOT/docs/SP1A_GATE.md"
grep -q 'policy_version.*term-list derivative' "$DOC" 2>/dev/null \
    && ok "docs state policy_version is a term-list derivative" || bad "docs do not say policy_version is a term-list derivative"

echo
echo "gate-policy: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
