#!/usr/bin/env bash
# `cond && ok … || bad …` is safe in this file: ok and bad always return 0.
# shellcheck disable=SC2015,SC2016
# test-eval-via-gate.sh — the eval harness through the gate's `eval` op, the
# switch from the direct path, and gate latency (SP1a story 2.6, #109; AD-1,
# AD-19, AD-20, FR-18, FR-36, NFR-1, NFR-3).
# tier: ci — the real gate handler behind a real unix socket (gate-fixture.sh)
# with the llama-server mock as the classifier; synthetic terms (zzalpha,
# zzbravo), eval set, and hardware tree. No real model, GPU, or case.
#
# Pins: the three rows built from the gate's per-layer results; the record
# format unchanged except policy_version (the gate's own), which publish
# scrubs; batches and the bulk budget; manifest checks in the gate; a gate that
# does not answer reaches no layer; the lint (the harness reaches no layer
# outside the gate); compare (identical, a difference count blocks the switch,
# not comparable); latency records with NFR-1 and gate-deadline FAILs.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EH="$ROOT/scripts/hub/eval-harness.sh"
ED="$ROOT/scripts/hub/eval-direct.sh"
ES="$ROOT/scripts/hub/eval-set.sh"
PASS=0; FAIL=0
ok()   { echo "  OK  $1"; ((PASS++)) || true; }
bad()  { echo " FAIL $1"; ((FAIL++)) || true; }
check(){ if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (no '$3' in output)"; printf '%s\n' "$2" | sed 's/^/      | /' ;; esac; }
hasnt(){ case "$2" in *"$3"*) bad "$1 ('$3' found)" ;; *) ok "$1" ;; esac; }
fault(){ (( $2 >= 4 )) && ok "$1 (exit $2)" || bad "$1 (exit $2, want >= 4)"; }

# shellcheck source=/dev/null
source "$ROOT/scripts/tests/gate-fixture.sh"
gf_setup
[[ -S "$SOCK" ]] || { echo " FAIL gate socket did not come up"; exit 1; }
printf 'ZZCLSFAULT\tMALFORMED\nZZSENSITIVE\t{"verdict":"sensitive"}\n' > "$MS/rules"

# --- hardware tree (the record's GPU, driver, Mesa, kernel) ------------------
HW="$TMP/hw"; dev="$HW/sys/devices/pci0000:00/0000:00:01.0"
mkdir -p "$dev/drm/renderD128" "$HW/sys/class/drm/card0" "$HW/sys/bus/pci/drivers/amdgpu" \
         "$HW/proc/sys/kernel" "$HW/dev/dri" "$HW/bin"
echo 0x1002 > "$dev/vendor"; echo 0x1900 > "$dev/device"
ln -s "../../../bus/pci/drivers/amdgpu" "$dev/driver"
ln -s "../../../devices/pci0000:00/0000:00:01.0" "$HW/sys/class/drm/card0/device"
: > "$HW/dev/dri/renderD128"
echo "6.8.0-41-generic" > "$HW/proc/sys/kernel/osrelease"
echo "zzhostname" > "$HW/proc/sys/kernel/hostname"
printf 'Devices:\n========\nGPU0:\n\tdeviceName         = AMD Radeon Graphics (RADV TEST)\n\tdriverID           = DRIVER_ID_MESA_RADV\n\tdriverName         = radv\n\tdriverInfo         = Mesa 25.3.1-0test1\n' > "$HW/vk.txt"
printf '#!/bin/sh\ncat "%s"\n' "$HW/vk.txt" > "$HW/bin/vulkaninfo"; chmod +x "$HW/bin/vulkaninfo"

# --- hub config and stores ----------------------------------------------------
RUNTIME="$TMP/llama-server"; printf 'synthetic runtime binary\n' > "$RUNTIME"
STORE="$STATE/eval"; MAN="$STATE/manifests"
mkdir -m 700 "$STORE"; mkdir -m 2750 "$MAN"
POL="$STATE/gate-policy/current"
econf() { # econf [GATE_/FLEET_ lines...] — the gate fixture's config plus eval keys
    gf_conf "GATE_HUB_SOCKET=$SOCK" "FLEET_RUNTIME_BINARY=$RUNTIME" "GATE_EVAL_BUDGET=60" "$@"
    { echo "LANE2_EVAL_FALSE_BLOCK_CEILING=5"; echo "LANE2_EVAL_TERM_LIST=$POL/term-list.txt"
      echo "LANE2_EVAL_CLASSIFIER_PROMPT=$POL/classifier-prompt.md"
      local kv; for kv in "$@"; do [[ "$kv" == LANE2_* ]] && echo "$kv"; done; } >> "$CONF/lane2.conf"
}
econf

addcase() { # addcase <split> <id> <category> <label> <hard_negative> <text>
    jq -nc --arg s "$1" --arg id "$2" --arg c "$3" --arg l "$4" --argjson hn "$5" --arg t "ZZCASETEXT $6" '
        {id: $id, category: $c, label: $l, hard_negative: $hn, split: $s, provenance: "operator",
         labelled_by: "operator", synthetic: true}
        + if $c == "multi-block" then {blocks: [$t, "second block"]} else {prompt: $t} end' >> "$STORE/$1.jsonl"
}
addcase heldout h-p1 plain sensitive false "zzalpha ZZSENSITIVE one"
addcase heldout h-p2 plain sensitive false "zzalpha only"
addcase heldout h-p3 plain sensitive false "ZZSENSITIVE only"
addcase heldout h-p4 plain sensitive false "nothing to see"
addcase heldout h-o1 obfuscated sensitive false "zzbravo ZZCLSFAULT"
addcase heldout h-m1 multi-block sensitive false "zzalpha first block"
addcase heldout h-n1 plain nonsensitive true "ZZSENSITIVE harmless"
addcase heldout h-n2 plain nonsensitive true "harmless words"
addcase tuning t-p1 plain sensitive false "zzalpha tuning"
addcase tuning t-n1 plain nonsensitive true "tuning negative"
chmod 600 "$STORE"/*.jsonl
DIGEST="$(bash -c 'source "$1"; evalset_digest "$2"' _ "$ES" "$STORE/heldout.jsonl")"
jq -nc --arg d "$DIGEST" '{time: "2026-10-16T00:00:00Z", digest: $d, cases: 8, reason: "initial", previous: null}' > "$STORE/freeze.jsonl"
chmod 600 "$STORE/freeze.jsonl"

# Run a harness as on the hub: container check stubbed, hardware probes on the
# synthetic tree. SEAM_BATCH (read by this wrapper) shrinks the batch size.
h() { # h <script> [args...]
    local s="$1"; shift
    bash -c 'source "$1"; hw="$2"; shift 2
        evalset_in_container() { return 1; }
        HW_SYSFS="$hw/sys"; HW_PROC="$hw/proc"; HW_DEV="$hw/dev"; HW_VULKANINFO="$hw/bin/vulkaninfo"
        if [[ -n "${SEAM_BATCH:-}" ]]; then EVALH_BATCH="$SEAM_BATCH"; fi
        evalh_restart_unit() { echo "$1" >> "$(dirname "$HW_SYSFS")/restarts"; }
        evalh_classifier_ready() { return 0; }
        evalh_main "$@"' _ "$s" "$HW" --config-dir "$CONF" "$@"
}
run()  { OUT="$(h "$EH" "$@" 2>&1)"; RC=$?; }
REC() { find "$STORE" -maxdepth 1 -name "${1:-record}-*.json" -printf '%T@ %p\n' | sort -n | tail -n 1 | cut -d' ' -f2-; }
nrec() { find "$STORE" -maxdepth 1 -name 'record-*.json' | wc -l | tr -d ' '; }
A() { jq -r "$1" "$(REC)"; }
PV="$(bash -c 'source "$1"; lane2_load_config "$2/lane2.conf"; CONFDIR="$2"; STATE="$3"; PREFIX="$4"
    policy_version_now "$(lane2_tree_digest "$4/current" "${LANE2_GATE_CODE[@]}")"' \
    _ "$ROOT/scripts/hub/lane2" "$CONF" "$STATE" "$PREFIX")"
[[ "$PV" =~ ^[0-9a-f]{64}$ ]] || { echo " FAIL fixture policy_version did not compute"; exit 1; }
# As `lane2 policy update` leaves it; the direct path reads it from here.
jq -nc --arg pv "$PV" '{commit: "p1", policy_version: $pv}' > "$STATE/gate-policy/state.json"
touch -d '2020-01-01' "$STATE/gate-policy/state.json"

# =============================================================================
echo "== a held-out run through the gate =="
: > "$MS/requests.jsonl"
run run --split heldout
check "run exits 0" "$RC" 0
for r in floor-only classifier-only combined; do has "row $r reported" "$OUT" "== $r =="; done
has "errors flagged" "$OUT" "  !!  1 case(s) in the errors bucket"
check "one record" "$(nrec)" 1
check "record path is the gate" "$(A .path)" "gate: hub-socket eval op, layers floor and classifier (AD-1, AD-20)"
check "record carries the gate's policy_version" "$(A .policy_version)" "$PV"
hasnt "no policy_version on stdout" "$OUT" "$PV"
row() { A ".cases[] | select(.id == \"$1\") | \"\(.[\"floor-only\"]) \(.[\"classifier-only\"]) \(.combined)\""; }
check "both layers hit"               "$(row h-p1)" "block block block"
check "floor only"                    "$(row h-p2)" "block allow block"
check "classifier only"               "$(row h-p3)" "allow block block"
check "missed by both"                "$(row h-p4)" "allow allow allow"
check "classifier fault is an error"  "$(row h-o1)" "block error error"
check "multi-block joined"            "$(row h-m1)" "block allow block"
check "hard negative false block"     "$(row h-n1)" "allow block block"
cell() { A ".aggregates.rows[\"$1\"].categories[\"$2\"] | \"\(.n) \(.misses) \(.errors)\""; }
check "floor-only all"       "$(cell floor-only all)" "6 2 0"
check "classifier-only all"  "$(cell classifier-only all)" "5 3 1"
check "combined all"         "$(cell combined all)" "5 1 1"
check "false blocks combined" "$(A '.aggregates.rows.combined.false_block | "\(.n) \(.blocks)"')" "2 1"
check "each case reached the classifier once, through the gate" \
    "$(grep -c '"/v1/chat/completions"' "$MS/requests.jsonl")" 8

echo "== record format: unchanged apart from policy_version =="
check "record keys" "$(A 'keys | join(",")')" \
    "aggregates,cache_mode,cases,driver,effective_settings_sha256,fixture_digest,fleet_member,format,gpu,host,kernel_version,kind,mesa_version,model,model_sha256,path,policy_version,prompt_sha256,runtime,settings_sha256,split,term_list_usable,time"
check "prompt sha256 is the policy prompt's (from the gate)" "$(A .prompt_sha256)" "$(sha256sum < "$POL/classifier-prompt.md" | cut -d' ' -f1)"
check "settings sha256 is the production file's" "$(A .settings_sha256)" "$(sha256sum < "$ROOT/scripts/hub/fleet/classifier.settings.json" | cut -d' ' -f1)"
check "cache mode" "$(A .cache_mode)" cache_prompt_false
check "record mode 0600" "$(stat -c %a "$(REC)")" 600
grep -q ZZCASETEXT "$(REC)" && bad "case text in the record" || ok "no case text in the record"
check "manifest directories removed" "$(find "$MAN" -mindepth 1 | wc -l | tr -d ' ')" 0
check "nothing written outside the eval and manifests stores" \
    "$(find "$STATE" -newer "$STORE/freeze.jsonl" -type f -not -path "$STORE/*" | wc -l | tr -d ' ')" 0

echo "== publish scrubs policy_version =="
run publish "$(REC)"
check "publish exits 0" "$RC" 0
check "no policy_version field" "$(jq -c 'has("policy_version")' <<<"$OUT")" false
hasnt "policy_version value scrubbed" "$OUT" "$PV"

echo "== batches =="
GATE_REC="$(REC)"
OUT="$(SEAM_BATCH=3 h "$EH" run --split heldout 2>&1)"; RC=$?
check "batched run exits 0" "$RC" 0
check "batches of 3 give the same per-case results" "$(A '.cases | map(del(.id)) | tojson')" "$(jq -r '.cases | map(del(.id)) | tojson' "$GATE_REC")"

# =============================================================================
echo "== a gate that does not answer reaches no layer =="
n0="$(nrec)"; : > "$MS/requests.jsonl"
econf "GATE_HUB_SOCKET=$TMP/no-such.sock"
run run --split heldout
fault "gate down: run stops" "$RC"
has "names policy_version" "$OUT" "record incomplete: policy_version"
check "no record" "$(nrec)" "$n0"
check "no model request at all" "$(wc -l < "$MS/requests.jsonl" | tr -d ' ')" 0
econf
mv "$POL/term-list.txt" "$TMP/terms.off"
run run --split heldout; fault "gate policy missing: run stops" "$RC"
has "says why" "$OUT" "fault:policy"
mv "$TMP/terms.off" "$POL/term-list.txt"
econf "LANE2_EVAL_CACHE_MODE=np1"; run run --split heldout; fault "np1 is the direct path only" "$RC"
econf "GATE_EVAL_BUDGET=abc"; run run --split heldout; fault "bad bulk budget" "$RC"
econf "GATE_EVAL_BUDGET=5"; run run --split heldout; fault "budget below the gate deadline: the gate refuses (fault:config)" "$RC"
econf

echo "== the bulk budget, not the per-request deadline, bounds a bulk eval =="
mkm() { rm -rf "$MAN/t"; mkdir -m 2750 "$MAN/t"; }
ask() { RC=0; gate_client "$SOCK" 40 "$1" < <(printf '%s' "${2:-}") || RC=$?; RESP="$GATE_CLIENT_RESPONSE"; }
H='{"v":1,"op":"eval","layers":["floor","classifier"],"manifest":"'"$MAN"'/t"}'
mkm; printf 'slow case' > "$MAN/t/000001"
econf "GATE_DEADLINE=2" "GATE_EVAL_BUDGET=30"; gf_mode timeout
ask "$H"
check "a 5 s case under a 2 s deadline completes within the budget" "$(jq -r .detail.cases <<<"$RESP")" "cc"
econf "GATE_DEADLINE=2" "GATE_EVAL_BUDGET=3"
ask "$H"
check "over the budget: fault:timeout" "$(jq -r .detail.reason <<<"$RESP")" "fault:timeout"
ask '{"v":1,"op":"eval","layers":["classifier"]}' "slow single payload"
check "a single payload keeps the per-request deadline" "$(jq -r .detail.reason <<<"$RESP")" "fault:timeout"
gf_mode ok; econf

echo "== manifest checks in the gate =="
mreason() { ask "$1" "${2:-}"; jq -r '.detail.reason // ""' <<<"$RESP"; }
mkm; printf 'a' > "$MAN/t/000001"; printf 'b' > "$MAN/t/000002"
ask "$H"; check "well-formed manifest: two cases" "$(jq -r .detail.cases <<<"$RESP")" "cccc"
check "inputs reported" "$(jq -r '.detail.inputs | keys | join(",")' <<<"$RESP")" "cache_prompt,policy_version,prompt_sha256,settings_sha256"
check "payload with a manifest: block" "$(mreason "$H" "x")" fault:protocol
mkdir -p "$TMP/elsewhere"
check "manifest outside the store: block" "$(mreason '{"v":1,"op":"eval","layers":["floor"],"manifest":"'"$TMP"'/elsewhere"}')" fault:protocol
check "manifest with ..: block" "$(mreason '{"v":1,"op":"eval","layers":["floor"],"manifest":"'"$MAN"'/../eval"}')" fault:protocol
mkm; printf 'a' > "$MAN/t/000002"
check "non-contiguous cases: block" "$(mreason "$H")" fault:protocol
mkm; ln -s "$POL/term-list.txt" "$MAN/t/000001"
check "a symlinked case: block" "$(mreason "$H")" fault:protocol
mkm; printf 'a' > "$MAN/t/notes.txt"
check "a foreign file: block" "$(mreason "$H")" fault:protocol
ln -s t "$MAN/link"
check "a symlinked manifest: block" "$(mreason '{"v":1,"op":"eval","layers":["floor"],"manifest":"'"$MAN"'/link"}')" fault:protocol
check "manifest not a string: block" "$(mreason '{"v":1,"op":"eval","layers":["floor"],"manifest":1}')" fault:protocol
rm -rf "$MAN/t" "$MAN/link"

# =============================================================================
echo "== lint: the harness reaches no layer outside the gate =="
LINT='orch_floor_match|orch_classify|fleet_call|gate_floor_match|gate_classify|orchestrator-route\.sh|lib/gate\.sh|classify-sensitivity|\bcurl\b|/v1/|/completion|term-list|classifier-prompt|LANE2_EVAL_TERM_LIST|LANE2_EVAL_CLASSIFIER_PROMPT|eval-direct'
lint() { grep -nE -- "$LINT" "$1" | grep -vE '^[0-9]+:[[:space:]]*#'; }
V="$(lint "$EH")"
[[ -z "$V" ]] && ok "eval-harness.sh: no layer reached outside the gate" || { bad "eval-harness.sh reaches a layer outside the gate"; printf '%s\n' "$V" | sed 's/^/      | /'; }
cp "$EH" "$TMP/planted.sh"; printf 'x="$(fleet_call classifier s < f)"\n' >> "$TMP/planted.sh"
[[ -n "$(lint "$TMP/planted.sh")" ]] && ok "the lint catches a planted direct call" || bad "lint missed a planted fleet_call"
SRC="$(grep -rnE 'eval-direct\.sh' "$ROOT/scripts" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' \
    | grep -vE '^[^:]*/tests/|^[^:]*/hub/eval-direct\.sh:' || true)"
check "nothing but tests uses the direct path" "$SRC" ""

# =============================================================================
echo "== compare: direct path vs gate =="
OUT="$(h "$ED" run --split heldout 2>&1)"; RC=$?
check "direct run exits 0" "$RC" 0
DIRECT="$(REC)"
check "direct record names its path" "$(jq -r .path "$DIRECT" | cut -c1-15)" "direct (Epic 1)"
check "direct record's policy_version equals the gate's" "$(jq -r .policy_version "$DIRECT")" "$PV"
run compare "$DIRECT" "$GATE_REC"
check "identical per-case results: exit 0" "$RC" 0
has "says identical" "$OUT" "  OK  identical per-case results for every row"
CMP="$(REC compare)"
check "compare record 0600" "$(stat -c %a "$CMP")" 600
check "compare record: zero differences" "$(jq -r .differences "$CMP")" 0
jq '.cases |= map(if .id == "h-p4" then .["classifier-only"] = "block" | .combined = "block" else . end)' "$GATE_REC" > "$TMP/gate-diff.json"
run compare "$DIRECT" "$TMP/gate-diff.json"
check "a difference blocks the switch: exit 3" "$RC" 3
has "difference count" "$OUT" " FAIL 2 difference(s): the switch from the direct path is blocked"
check "count by row in the record" "$(jq -c .by_row "$(REC compare)")" '{"floor-only":0,"classifier-only":1,"combined":1}'
jq '.fixture_digest = "0"' "$GATE_REC" > "$TMP/gate-other.json"
run compare "$DIRECT" "$TMP/gate-other.json"; fault "different split: not comparable" "$RC"
printf '# synthetic\nzzalpha\n' > "$TMP/other-terms.txt"
econf "LANE2_EVAL_TERM_LIST=$TMP/other-terms.txt"
OUT="$(h "$ED" run --split heldout 2>&1)"
check "direct run on another term list: no policy_version" "$(jq -r .policy_version "$(REC)")" null
run compare "$(REC)" "$GATE_REC"; fault "another term list: not comparable" "$RC"
econf
jq '.policy_version = null' "$DIRECT" > "$TMP/direct-nopv.json"
run compare "$TMP/direct-nopv.json" "$GATE_REC"; fault "no policy_version: not comparable" "$RC"
run compare "$GATE_REC" "$DIRECT"; fault "records in the wrong order" "$RC"
run compare "$DIRECT"; check "compare usage: exit 2" "$RC" 2

# =============================================================================
echo "== latency through the hub socket =="
econf "GATE_MAX_REQUEST=1048576"; printf '131072' > "$MS/nctx"
: > "$MS/requests.jsonl"
run latency --runs 3
check "latency exits 0" "$RC" 0
LAT="$(REC latency)"
[[ -n "$LAT" ]] && ok "latency record written" || bad "no latency record"
check "latency record 0600" "$(stat -c %a "$LAT")" 600
check "three sizes, warm" "$(jq -c '[.results[] | "\(.tokens)/\(.mode)/\(.runs)"]' "$LAT")" '["1000/warm/3","5000/warm/3","20000/warm/3"]'
check "p50, p95, max are numbers" "$(jq -c '[.results[] | (.p50_s, .p95_s, .max_s) | type] | unique' "$LAT")" '["number"]'
check "NFR-1 and deadline checks pass on the mock" "$(jq -c '[.checks[].status] | unique' "$LAT")" '["OK"]'
check "deadline from gate.conf" "$(jq -r .gate_deadline_s "$LAT")" 10
has "p95 at 20k against the gate deadline" "$OUT" "  OK  gate_deadline_p95_20k (warm)"
check "every request went through the gate (3 sizes x (1 warm-up + 3))" \
    "$(grep -c '"/v1/chat/completions"' "$MS/requests.jsonl")" 12
hasnt "no input text in the record" "$(cat "$LAT")" "config file"
rm -f "$HW/restarts"
run latency --runs 2 --cold
check "cold run exits 0" "$RC" 0
check "cold: a restart before every cold run" "$(wc -l < "$HW/restarts" | tr -d ' ')" 6
check "warm and cold recorded" "$(jq -c '[.results[].mode] | unique' "$(REC latency)")" '["cold","warm"]'
econf "GATE_MAX_REQUEST=1048576" "GATE_DEADLINE=2"; gf_mode timeout
run latency --runs 1
check "timeouts: run still completes" "$RC" 0
check "p95 at 20k over the gate deadline is FAIL in the record" \
    "$(jq -r '.checks[] | select(.check == "gate_deadline_p95_20k") | .status' "$(REC latency)")" FAIL
has "and FAIL on stdout" "$OUT" " FAIL gate_deadline_p95_20k (warm)"
check "timeouts counted as faults" "$(jq -c '[.results[].faults]' "$(REC latency)")" '[1,1,1]'
gf_mode ok; econf; rm -f "$MS/nctx"
run latency --runs 0; check "latency usage: exit 2" "$RC" 2

echo
echo "eval-via-gate: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
