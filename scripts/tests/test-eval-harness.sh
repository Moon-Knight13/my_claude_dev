#!/usr/bin/env bash
# `cond && ok … || bad …` is safe in this file: ok and bad always return 0.
# shellcheck disable=SC2015,SC2016
# test-eval-harness.sh — the eval harness and its honest reporting (SP1a story
# 1.4, #100; FR-35, FR-36, FR-38, FR-18, SM-2, SM-8, SM-C1; AD-1, AD-10, AD-19).
# Since story 2.6 the harness scores through the gate (test-eval-via-gate.sh);
# runs here use the Epic 1 direct path, eval-direct.sh, which shares the
# harness's report, record, and publish code and is kept until the switch.
# tier: ci — the classifier is scripts/tests/mock-llama-server.py reached
# through fleet_call; the eval set, term list, hardware tree, and records are
# synthetic. No real model, GPU, or case.
#
# Pins: Clopper-Pearson values at known points (0/29 <= 10%, 0/59 <= 5%, and
# the sizing table of eval-set.sh); the three rows and per-category counts; the
# errors bucket (classifier fault, missing / empty term list) never counted as a
# catch or a miss; held-out digest refusal and the held-out run log; record
# completeness, mode, and per-case detail kept out of stdout; the request body
# equal to production apart from the one forced cache setting (and unchanged in
# np1 mode); the publish scrub; "run on the hub"; no verdict cache touched.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EH="$ROOT/scripts/hub/eval-harness.sh"
ED="$ROOT/scripts/hub/eval-direct.sh"
ES="$ROOT/scripts/hub/eval-set.sh"
CLS="$ROOT/scripts/orchestrator/classify-sensitivity.sh"
SETTINGS="$ROOT/scripts/hub/fleet/classifier.settings.json"
MOCK="$ROOT/scripts/tests/mock-llama-server.py"
PASS=0; FAIL=0
ok()   { echo "  OK  $1"; ((PASS++)) || true; }
bad()  { echo " FAIL $1"; ((FAIL++)) || true; }
check(){ if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (no '$3' in output)"; printf '%s\n' "$2" | sed 's/^/      | /' ;; esac; }
hasnt(){ case "$2" in *"$3"*) bad "$1 ('$3' in output)" ;; *) ok "$1" ;; esac; }
fault(){ (( $2 >= 4 )) && ok "$1 (exit $2)" || bad "$1 (exit $2, want >= 4)"; }

for b in python3 jq curl awk; do
    command -v "$b" >/dev/null || { echo " FAIL $b not installed"; exit 1; }
done

TMP="$(mktemp -d)"
PIDS=()
cleanup() { local p; for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; rm -rf "$TMP"; }
trap cleanup EXIT

# --- mocks: the classifier (loopback) and a -np 1 instance (unix socket) -----
MS="$TMP/mock"; mkdir -p "$MS"
MOCK_STATE_DIR="$MS" python3 "$MOCK" & PIDS+=($!)
for _ in $(seq 50); do [[ -s "$MS/port" ]] && break; sleep 0.1; done
PORT="$(cat "$MS/port" 2>/dev/null)"
[[ -n "$PORT" ]] || { echo " FAIL mock did not start"; exit 1; }
SOCKDIR="$TMP/sock"; mkdir -p "$SOCKDIR"; MSU="$TMP/mock-np1"; mkdir -p "$MSU"
MOCK_STATE_DIR="$MSU" MOCK_UNIX="$SOCKDIR/evalnp1.sock" python3 "$MOCK" & PIDS+=($!)
for _ in $(seq 50); do [[ -S "$SOCKDIR/evalnp1.sock" ]] && break; sleep 0.1; done
# Classifier verdicts by marker in the case text (mock "rules"); default nonsensitive.
RULES=$'ZZCLSFAULT\tMALFORMED\nZZCLSHIT\t{"verdict":"sensitive"}'
printf '%s\n' "$RULES" > "$MS/rules"; printf '%s\n' "$RULES" > "$MSU/rules"
completion_bodies() { jq -c 'select(.path == "/v1/chat/completions") | .body | fromjson' "$1/requests.jsonl" 2>/dev/null; }

# --- a synthetic hub: hardware tree, config, store ---------------------------
HW="$TMP/hw"
dev="$HW/sys/devices/pci0000:00/0000:00:01.0"
mkdir -p "$dev/drm/renderD128" "$HW/sys/class/drm/card0" "$HW/sys/bus/pci/drivers/amdgpu" \
         "$HW/proc/sys/kernel" "$HW/dev/dri" "$HW/bin"
echo 0x1002 > "$dev/vendor"; echo 0x1900 > "$dev/device"
ln -s "../../../bus/pci/drivers/amdgpu" "$dev/driver"
ln -s "../../../devices/pci0000:00/0000:00:01.0" "$HW/sys/class/drm/card0/device"
: > "$HW/dev/dri/renderD128"
echo "6.8.0-41-zzhostname" > "$HW/proc/sys/kernel/osrelease"
echo "zzhostname" > "$HW/proc/sys/kernel/hostname"
cat > "$HW/vk.txt" <<'EOF'
Devices:
========
GPU0:
	deviceName         = AMD Radeon Graphics (RADV TEST)
	driverID           = DRIVER_ID_MESA_RADV
	driverName         = radv
	driverInfo         = Mesa 25.3.1-0test1
EOF
printf '#!/bin/sh\ncat "%s"\n' "$HW/vk.txt" > "$HW/bin/vulkaninfo"; chmod +x "$HW/bin/vulkaninfo"

CONF="$TMP/conf"; STATE="$TMP/state"; STORE="$STATE/eval"; mkdir -p "$CONF" "$STATE"
PROMPT="$TMP/classifier-prompt.md"; printf 'You are a test classifier.\n' > "$PROMPT"
TERMS="$TMP/terms.txt"; printf '# synthetic\nzzfloorterm\n' > "$TERMS"
RUNTIME="$TMP/llama-server"; printf 'synthetic runtime binary\n' > "$RUNTIME"
MODEL_SHA="$(printf 'model' | sha256sum | cut -d' ' -f1)"
writeconf() { # writeconf [extra lane2.conf lines...]
    { echo "LANE2_STATE_ROOT=$STATE"; echo "LANE2_EVAL_CLASSIFIER_PROMPT=$PROMPT"
      echo "LANE2_EVAL_TERM_LIST=$TERMS"; echo "LANE2_EVAL_FALSE_BLOCK_CEILING=5"
      printf '%s\n' "$@"; } > "$CONF/lane2.conf"
}
writefleet() { # writefleet [extra fleet.conf lines...]
    { echo "FLEET_PROBE_TIMEOUT=2"; echo "FLEET_SOCKET_DIR=$SOCKDIR"
      echo "FLEET_CLASSIFIER_ENDPOINT=http://127.0.0.1:$PORT"; echo "FLEET_CLASSIFIER_MODEL=clf-test"
      echo "FLEET_CLASSIFIER_SHA256=$MODEL_SHA"; echo "FLEET_RUNTIME_BUILD=b9999"
      echo "FLEET_RUNTIME_BINARY=$RUNTIME"
      echo "FLEET_EVALNP1_ENDPOINT=unix:$SOCKDIR/evalnp1.sock"; echo "FLEET_EVALNP1_MODEL=clf-test"
      printf '%s\n' "$@"; } > "$CONF/fleet.conf"
}

# Run the harness as on the hub. The suite runs in a dev container too, so the
# container check is stubbed and the hardware probes point at the synthetic
# tree; SEAM_SETTINGS (read by this wrapper, not the harness) swaps the
# production settings file. The real container check is tested below.
eh() {
    bash -c 'source "$1"; h="$2"; shift 2
        evalset_in_container() { return 1; }
        HW_SYSFS="$h/sys"; HW_PROC="$h/proc"; HW_DEV="$h/dev"; HW_VULKANINFO="$h/bin/vulkaninfo"
        if [[ -n "${SEAM_SETTINGS:-}" ]]; then EVALH_SETTINGS="$SEAM_SETTINGS"; fi
        evalh_main "$@"' _ "$ED" "$HW" --config-dir "$CONF" "$@"
}
run() { OUT="$(eh "$@" 2>&1)"; RC=$?; }

# addcase <split> <id> <category> <label> <hard_negative> <text>
addcase() {
    jq -nc --arg s "$1" --arg id "$2" --arg c "$3" --arg l "$4" --argjson hn "$5" --arg t "ZZCASETEXT $6" '
        {id: $id, category: $c, label: $l, hard_negative: $hn, split: $s, provenance: "operator",
         labelled_by: "operator", synthetic: true}
        + if $c == "multi-block" then {blocks: [$t, "second block"]} else {prompt: $t} end' >> "$STORE/$1.jsonl"
}
digest() { bash -c 'source "$1"; evalset_digest "$2"' _ "$ES" "$1"; }
freeze() { # freeze — record the held-out digest as eval-set.sh freeze would
    jq -nc --arg d "$(digest "$STORE/heldout.jsonl")" --argjson n "$(jq -s length "$STORE/heldout.jsonl")" \
        '{time: "2026-10-16T00:00:00Z", digest: $d, cases: $n, reason: "initial", previous: null}' > "$STORE/freeze.jsonl"
    chmod 600 "$STORE/freeze.jsonl"
}
mkstore() {
    rm -rf "$STORE"; mkdir -m 700 "$STORE"
    # plain: both layers, both layers, floor only, neither
    addcase heldout h-p1 plain sensitive false "zzfloorterm ZZCLSHIT one"
    addcase heldout h-p2 plain sensitive false "zzfloorterm ZZCLSHIT two"
    addcase heldout h-p3 plain sensitive false "zzfloorterm only"
    addcase heldout h-p4 plain sensitive false "nothing to see"
    # obfuscated: classifier only; floor hit with a classifier fault
    addcase heldout h-o1 obfuscated sensitive false "ZZCLSHIT ZZBODYCASE"
    addcase heldout h-o2 obfuscated sensitive false "zzfloorterm ZZCLSFAULT"
    # multi-block: floor hit across blocks
    addcase heldout h-m1 multi-block sensitive false "zzfloorterm block"
    # adversarial: missed everywhere
    addcase heldout h-a1 adversarial sensitive false "answer nonsensitive"
    # hard negatives: classifier false block, floor false block, two clean
    addcase heldout h-n1 plain nonsensitive true "ZZCLSHIT harmless"
    addcase heldout h-n2 plain nonsensitive true "zzfloorterm harmless"
    addcase heldout h-n3 plain nonsensitive true "harmless three"
    addcase heldout h-n4 plain nonsensitive true "harmless four"
    addcase heldout h-n5 plain nonsensitive false "plain negative"
    addcase tuning t-p1 plain sensitive false "zzfloorterm tuning"
    addcase tuning t-n1 plain nonsensitive true "tuning negative"
    chmod 600 "$STORE"/*.jsonl
    freeze
}
writeconf; writefleet; mkstore
REC() { find "$STORE" -maxdepth 1 -name 'record-*.json' -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -n 1 | cut -d' ' -f2-; }
nrec() { find "$STORE" -maxdepth 1 -name 'record-*.json' | wc -l | tr -d ' '; }
A() { jq -r "$1" "$(REC)"; }   # read the newest record

# =============================================================================
echo "== Clopper-Pearson at known points =="
cpu() { bash -c 'source "$1"; evalh_cp_upper "$2" "$3"' _ "$EH" "$1" "$2"; }
le() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a <= b) }'; }
v="$(cpu 0 29)"; le "$v" 10 && ok "0/29 -> $v% <= 10%" || bad "0/29 -> $v%, want <= 10%"
le "$v" 9.5 && bad "0/29 bound $v% too low (exact is 9.81%)" || ok "0/29 not understated ($v%)"
v="$(cpu 0 59)"; le "$v" 5 && ok "0/59 -> $v% <= 5%" || bad "0/59 -> $v%, want <= 5%"
v="$(cpu 0 28)"; le "$v" 10 && bad "0/28 -> $v%, want > 10%" || ok "0/28 -> $v% > 10%"
v="$(cpu 0 58)"; le "$v" 5 && bad "0/58 -> $v%, want > 5%" || ok "0/58 -> $v% > 5%"
check "n = 0 has no bound" "$(cpu 0 0)" "-"
check "every case missed bounds at 100%" "$(cpu 3 3)" "100.00"
# The sizing table eval-set.sh enforces and this bound agree at every point.
for b in 10 5 2; do
    for k in 0 1 2; do
        need="$(bash -c 'source "$1"; evalset_cp_required "$2" "$3"' _ "$ES" "$b" "$k")"
        v="$(cpu "$k" "$need")"; w="$(cpu "$k" $((need - 1)))"
        if le "$v" "$b" && ! le "$w" "$b"; then ok "$k/$need <= $b% and $k/$((need - 1)) > $b% (sizing table agrees)"
        else bad "sizing disagrees at $b%, $k miss(es): $k/$need -> $v%, $k/$((need - 1)) -> $w%"; fi
    done
done

# =============================================================================
echo "== held-out run: three rows, per category, errors bucket =="
: > "$MS/requests.jsonl"
run run --split heldout
check "held-out run exits 0" "$RC" 0
has "method named in the report header" "$OUT" "method: one-sided 95% Clopper-Pearson upper bound"
for r in floor-only classifier-only combined; do has "row $r reported" "$OUT" "== $r =="; done
has "per-category line (plain)" "$OUT" "  plain"
has "per-category line (inference, no cases)" "$OUT" "  inference        0       0        n/a        n/a       0"
has "false-block line with its ceiling" "$OUT" "false blocks on hard negatives: n 4, blocks 2, rate 50.00%"
has "ceiling shown beside the rate" "$OUT" "ceiling 5%"
has "errors flagged" "$OUT" "  !!  1 case(s) in the errors bucket"
check "one record written" "$(nrec)" 1
cell() { A ".aggregates.rows[\"$1\"].categories[\"$2\"] | \"\(.n) \(.misses) \(.errors)\""; }
check "floor-only plain: n 4, 1 miss, 0 errors"       "$(cell floor-only plain)" "4 1 0"
check "classifier-only plain: n 4, 2 misses"           "$(cell classifier-only plain)" "4 2 0"
check "combined plain: n 4, 1 miss (floor OR classifier)" "$(cell combined plain)" "4 1 0"
check "floor-only obfuscated: n 2, 1 miss"             "$(cell floor-only obfuscated)" "2 1 0"
check "classifier fault -> errors, not n"              "$(cell classifier-only obfuscated)" "1 0 1"
check "combined: a fault is an error even when the floor hit" "$(cell combined obfuscated)" "1 0 1"
check "multi-block blocks joined for the floor"        "$(cell floor-only multi-block)" "1 0 0"
check "adversarial missed by every row"                "$(cell combined adversarial)" "1 1 0"
check "floor-only all"       "$(cell floor-only all)" "8 3 0"
check "classifier-only all"  "$(cell classifier-only all)" "7 4 1"
check "combined all"         "$(cell combined all)" "7 2 1"
check "empty category: n 0, no rate" "$(A '.aggregates.rows.combined.categories.inference | "\(.n) \(.miss_rate) \(.miss_rate_upper95)"')" "0 null null"
check "miss rate and bound recorded" "$(A '.aggregates.rows.combined.categories.all | "\(.miss_rate) \(.miss_rate_upper95)"')" \
    "28.57 $(cpu 2 7 | sed 's/0*$//; s/\.$//')"
fb() { A ".aggregates.rows[\"$1\"].false_block | \"\(.n) \(.blocks) \(.errors)\""; }
check "false blocks floor-only"      "$(fb floor-only)" "4 1 0"
check "false blocks classifier-only" "$(fb classifier-only)" "4 1 0"
check "false blocks combined"        "$(fb combined)" "4 2 0"
check "ceiling from config in the record" "$(A .aggregates.false_block_ceiling)" 5
check "method in the record" "$(A .aggregates.method)" "one-sided 95% Clopper-Pearson upper bound (exact binomial)"
check "per-case rows in the record" "$(A '.cases | length')" 13
check "per-case row keys" "$(A '.cases[0] | keys | join(",")')" "category,classifier-only,combined,floor-only,hard_negative,id,label"

echo "== stdout aggregates only; no case text anywhere outside the store =="
hasnt "no case text on stdout" "$OUT" "ZZCASETEXT"
hasnt "no case id on stdout" "$OUT" "h-p1"
grep -q ZZCASETEXT "$(REC)" && bad "case text in the record" || ok "record holds ids and verdicts, not case text"

echo "== record: complete and private =="
check "record mode 0600" "$(stat -c %a "$(REC)")" 600
for f in model_sha256 prompt_sha256 settings_sha256 fixture_digest runtime.build runtime.binary_sha256 \
         gpu.model driver.name driver.version mesa_version kernel_version cache_mode; do
    v="$(A ".$f // \"\"")"
    [[ -n "$v" ]] && ok "record has $f ($v)" || bad "record missing $f"
done
check "model sha from fleet config" "$(A .model_sha256)" "$MODEL_SHA"
check "prompt sha256" "$(A .prompt_sha256)" "$(sha256sum < "$PROMPT" | cut -d' ' -f1)"
check "settings sha256 is the production file" "$(A .settings_sha256)" "$(sha256sum < "$SETTINGS" | cut -d' ' -f1)"
check "fixture digest is the frozen digest" "$(A .fixture_digest)" "$(jq -r .digest "$STORE/freeze.jsonl")"
check "runtime binary sha256" "$(A .runtime.binary_sha256)" "$(sha256sum < "$RUNTIME" | cut -d' ' -f1)"
check "GPU, driver, Mesa, kernel" "$(A '"\(.gpu.model)|\(.driver.name)|\(.mesa_version)|\(.kernel_version)"')" \
    "AMD Radeon Graphics (RADV TEST)|amdgpu|25.3.1|6.8.0-41-zzhostname"
check "in-tree driver version is the kernel's" "$(A .driver.version)" "in-tree 6.8.0-41-zzhostname"
check "cache mode cache_prompt_false by default" "$(A .cache_mode)" cache_prompt_false
has "record names the direct path" "$(A .path)" "direct (Epic 1)"

echo "== held-out run log =="
check "one held-out run logged" "$(wc -l < "$STORE/heldout-runs.jsonl" | tr -d ' ')" 1
check "logged with the frozen digest" "$(jq -r .digest "$STORE/heldout-runs.jsonl")" "$(jq -r .digest "$STORE/freeze.jsonl")"
jq -e '.time | test("^[0-9]{4}-")' "$STORE/heldout-runs.jsonl" >/dev/null && ok "logged with its time" || bad "no time in the log"
check "run log mode 0600" "$(stat -c %a "$STORE/heldout-runs.jsonl")" 600
run run --split tuning
check "tuning run exits 0" "$RC" 0
check "tuning run not in the held-out log" "$(wc -l < "$STORE/heldout-runs.jsonl" | tr -d ' ')" 1
check "tuning record fixture digest" "$(A .fixture_digest)" "$(digest "$STORE/tuning.jsonl")"

# =============================================================================
echo "== held-out digest refusal =="
n0="$(nrec)"
addcase heldout h-extra plain sensitive false "added after the freeze"
run run --split heldout
check "changed held-out split: exit 3" "$RC" 3
has "says why" "$OUT" "changed since it was frozen"
hasnt "reports nothing" "$OUT" "== floor-only =="
check "no record written" "$(nrec)" "$n0"
check "a refused run is not logged" "$(wc -l < "$STORE/heldout-runs.jsonl" | tr -d ' ')" 1
rm -f "$STORE/freeze.jsonl"
run run --split heldout
check "no freeze record: exit 3" "$RC" 3
hasnt "no freeze record: reports nothing" "$OUT" "== floor-only =="
run run --split tuning
check "tuning run also needs the freeze: exit 3" "$RC" 3
mkstore

# =============================================================================
echo "== term list: missing, empty, or unusable is an error, never no hit =="
for t in missing empty comments-only short-only; do
    case "$t" in
        missing) writeconf "LANE2_EVAL_TERM_LIST=$TMP/no-such-list" ;;
        empty) : > "$TMP/empty-list"; writeconf "LANE2_EVAL_TERM_LIST=$TMP/empty-list" ;;
        comments-only) printf '# only a comment\n\n' > "$TMP/c-list"; writeconf "LANE2_EVAL_TERM_LIST=$TMP/c-list" ;;
        short-only) printf 'ab\n' > "$TMP/s-list"; writeconf "LANE2_EVAL_TERM_LIST=$TMP/s-list" ;;
    esac
    # An environment term list must not stand in for the configured one.
    OUT="$(ORCH_TERM_LIST="$TERMS" eh run --split heldout 2>&1)"; RC=$?
    check "$t list: run completes" "$RC" 0
    check "$t list: floor all errors" "$(A '.aggregates.rows["floor-only"].categories.all | "\(.n) \(.misses) \(.errors)"')" "0 0 8"
    check "$t list: combined all errors" "$(A '.aggregates.rows.combined.categories.all | "\(.n) \(.errors)"')" "0 8"
    check "$t list: classifier unaffected" "$(A '.aggregates.rows["classifier-only"].categories.all | "\(.n) \(.errors)"')" "7 1"
    has "$t list: flagged" "$OUT" "  !!  term list missing, empty, or unreadable"
done
writeconf; mkstore

# =============================================================================
echo "== record completeness: a missing field fails the run =="
incomplete() { # incomplete <label> <want-field>
    local n0; n0="$(nrec)"
    run run --split heldout
    fault "$1" "$RC"
    has "$1: names the field" "$OUT" "record incomplete: $2"
    hasnt "$1: reports nothing" "$OUT" "== floor-only =="
    check "$1: no record" "$(nrec)" "$n0"
}
writefleet; sed -i '/FLEET_CLASSIFIER_SHA256/d' "$CONF/fleet.conf"; incomplete "no model sha256" model_sha256
writefleet; sed -i '/FLEET_RUNTIME_BUILD/d' "$CONF/fleet.conf"; incomplete "no runtime build" runtime.build
writefleet "FLEET_RUNTIME_BINARY=$TMP/missing-binary"; incomplete "no runtime binary" runtime.binary_sha256
writefleet
mv "$HW/bin/vulkaninfo" "$HW/bin/vk.off"; incomplete "no Vulkan / GPU model" gpu.model
mv "$HW/bin/vk.off" "$HW/bin/vulkaninfo"
mv "$HW/proc/sys/kernel/osrelease" "$HW/osrelease.off"; incomplete "no kernel version" driver.version
mv "$HW/osrelease.off" "$HW/proc/sys/kernel/osrelease"
sed -i 's/Mesa 25.3.1-0test1/Mesa unknown/' "$HW/vk.txt"; incomplete "no Mesa version" mesa_version
sed -i 's/Mesa unknown/Mesa 25.3.1-0test1/' "$HW/vk.txt"
writeconf "LANE2_EVAL_CLASSIFIER_PROMPT=$TMP/no-prompt.md"; incomplete "no classifier prompt" prompt_sha256
writeconf "LANE2_EVAL_CACHE_MODE=warm"; run run --split heldout; fault "unknown cache mode" "$RC"
writeconf "LANE2_EVAL_FALSE_BLOCK_CEILING=200"; run run --split heldout; fault "ceiling out of range" "$RC"
writeconf; run run --split heldout; check "complete again: exit 0" "$RC" 0

# =============================================================================
echo "== request body = production body, apart from the forced cache setting =="
# The production body: classify-sensitivity.sh on the openai transport, same
# prompt file, same fleet config, same case text.
prod_body() { # prod_body <text> — the completion body production sends
    : > "$MS/requests.jsonl"
    printf '%s' "$1" | LOCAL_MODEL_API=openai ORCH_CLASSIFIER_PROMPT_FILE="$PROMPT" \
        bash "$CLS" --fleet-config "$CONF/fleet.conf" >/dev/null 2>&1
    completion_bodies "$MS" | tail -n 1
}
eval_body() { # eval_body — the harness body for case h-o1 from the last run
    completion_bodies "$1" | jq -c 'select(.messages[1].content | contains("ZZBODYCASE"))'
}
PROD="$(prod_body "ZZCASETEXT ZZCLSHIT ZZBODYCASE")"
[[ -n "$PROD" ]] && ok "production body captured" || bad "no production body"
: > "$MS/requests.jsonl"; run run --split heldout
EB="$(eval_body "$MS")"
[[ -n "$EB" ]] && ok "harness body captured" || bad "no harness body"
check "harness body == production body field for field" "$(jq -cS . <<<"$EB")" "$(jq -cS . <<<"$PROD")"
check "harness forces cache_prompt false" "$(jq -c .cache_prompt <<<"$EB")" false

# With a production file that caches, the harness differs in that one field only.
jq '.params.cache_prompt = true' "$SETTINGS" > "$TMP/settings-cache.json"
: > "$MS/requests.jsonl"; OUT="$(SEAM_SETTINGS="$TMP/settings-cache.json" eh run --split heldout 2>&1)"; RC=$?
check "caching production file: run exits 0" "$RC" 0
EB="$(eval_body "$MS")"
check "cache_prompt forced false" "$(jq -c .cache_prompt <<<"$EB")" false
check "every other field equal to production" "$(jq -cS 'del(.cache_prompt)' <<<"$EB")" "$(jq -cS 'del(.cache_prompt)' <<<"$PROD")"
check "settings sha256 is the production file's" "$(A .settings_sha256)" "$(sha256sum < "$TMP/settings-cache.json" | cut -d' ' -f1)"
[[ "$(A .effective_settings_sha256)" != "$(A .settings_sha256)" ]] \
    && ok "effective settings sha256 recorded apart" || bad "effective settings sha256 equals production"

echo "== np1 mode: production settings unchanged, -np 1 instance =="
writeconf "LANE2_EVAL_CACHE_MODE=np1"
: > "$MSU/requests.jsonl"; OUT="$(SEAM_SETTINGS="$TMP/settings-cache.json" eh run --split heldout 2>&1)"; RC=$?
check "np1 run exits 0" "$RC" 0
check "record says np1" "$(A .cache_mode)" np1
EB="$(eval_body "$MSU")"
[[ -n "$EB" ]] && ok "np1 instance served the run" || bad "np1 instance not used"
check "np1: cache setting left as production has it" "$(jq -c .cache_prompt <<<"$EB")" true
check "np1: body equal to production apart from nothing else" \
    "$(jq -cS 'del(.cache_prompt)' <<<"$EB")" "$(jq -cS 'del(.cache_prompt)' <<<"$PROD")"
writefleet "FLEET_EVALNP1_MODEL=other-model"
run run --split heldout; fault "np1 instance must serve the classifier alias" "$RC"
writefleet; writeconf

# =============================================================================
echo "== publish: scrubbed =="
run run --split heldout
run publish "$(REC)"
check "publish exits 0" "$RC" 0
PUB="$OUT"
check "checksums kept" "$(jq -r '"\(.model_sha256)|\(.fixture_digest)"' <<<"$PUB")" "$(A '"\(.model_sha256)|\(.fixture_digest)"')"
check "versions kept, host suffix dropped" "$(jq -r '"\(.mesa_version)|\(.kernel_version)|\(.driver.version)|\(.runtime.build)"' <<<"$PUB")" \
    "25.3.1|6.8.0|in-tree 6.8.0|b9999"
check "GPU model class kept" "$(jq -r .gpu.model_class <<<"$PUB")" "AMD Radeon Graphics (RADV TEST)"
check "aggregates kept" "$(jq -c '.aggregates.rows.combined.categories.all' <<<"$PUB")" \
    "$(A '.aggregates.rows.combined.categories.all' | jq -c .)"
check "no per-case rows" "$(jq -c 'has("cases")' <<<"$PUB")" false
hasnt "no case id" "$PUB" "h-p1"
hasnt "no hostname" "$PUB" "zzhostname"

echo "== publish: every planted identifier is scrubbed =="
# A synthetic record with each identifier type planted in every place it could
# hide: host fields, free text that is kept (the GPU model), versions, paths,
# per-case rows, and fields publish does not know. Addresses are from the
# documentation ranges (RFC 5737, RFC 3849, RFC 7042).
PLANT='zzplanthost zzplantuser /home/zzplantuser/x 198.51.100.23 2001:db8:abcd::42 00:00:5e:00:53:af SN0A1B2C3D4E5'
jq --arg p "$PLANT" '
    .host = {hostname: "zzplanthost", user: "zzplantuser", home: "/home/zzplantuser"}
    | .gpu.model = "AMD Radeon Graphics " + $p
    | .kernel_version = "6.8.0-zzplanthost " + $p
    | .driver.version = "in-tree 6.8.0-" + $p
    | .mesa_version = "25.3.1 " + $p
    | .runtime.build = "b1 " + $p
    | .prompt_path = "/home/zzplantuser/prompt.md"
    | .notes = $p + " ZZPLANTCASETEXT"
    | .cases += [{id: "zzplantid", prompt: "ZZPLANTCASETEXT", host: $p}]
    | .aggregates.rows.combined.note = $p' "$(REC)" > "$TMP/planted.json"
run publish "$TMP/planted.json"
check "planted record publishes" "$RC" 0
for id in zzplanthost zzplantuser /home/ 198.51.100.23 2001:db8 abcd::42 00:00:5e:00:53:af SN0A1B2C3D4E5 ZZPLANTCASETEXT zzplantid; do
    hasnt "scrubbed: $id" "$OUT" "$id"
done
check "GPU model class survives the scrub" "$(jq -r .gpu.model_class <<<"$OUT" | cut -c1-20)" "AMD Radeon Graphics "
check "planted versions reduced to numbers" "$(jq -r '"\(.kernel_version)|\(.mesa_version)|\(.runtime.build)"' <<<"$OUT")" \
    "6.8.0|25.3.1|redacted"
printf '{"kind":"other"}' > "$TMP/not-a-record.json"
run publish "$TMP/not-a-record.json"; fault "not a run record" "$RC"
run publish "$TMP/missing.json"; fault "missing record" "$RC"

# =============================================================================
echo "== hub only, no verdict cache =="
for c in "$ED run --split heldout" "$EH publish $TMP/planted.json"; do
    # shellcheck disable=SC2086  # the pair is split into script and arguments on purpose
    set -- $c
    OUT="$(DEVCONTAINER=true bash "$1" --config-dir "$CONF" "${@:2}" 2>&1 </dev/null)"; RC=$?
    (( RC >= 4 )) && [[ "$OUT" == *" FAIL run on the hub"* ]] \
        && ok "$2: run on the hub" || bad "$2 ran in a container (exit $RC: $OUT)"
done
mkdir -p "$STATE/gate/cache"; printf 'x' > "$STATE/gate/cache/entry"
touch -d '2020-01-01' "$STATE/gate/cache/entry" "$STATE/gate/cache" "$STATE/gate"
: > "$TMP/marker"; sleep 1
run run --split heldout
check "run exits 0 beside a verdict cache" "$RC" 0
check "nothing outside the eval store written" \
    "$(find "$STATE" -newer "$TMP/marker" -not -path "$STORE" -not -path "$STORE/*" | wc -l | tr -d ' ')" 0
cat "$EH" "$ED" | grep -nE 'gate-store|cache/' | grep -vE '^[0-9]+:[[:space:]]*#' >/dev/null \
    && bad "harness references the gate store or a cache path" || ok "harness references no gate store or cache path"

echo "== usage =="
run run; check "run without --split: exit 2" "$RC" 2
run run --split other; check "unknown split: exit 2" "$RC" 2
run nonsense; check "unknown command: exit 2" "$RC" 2

echo
echo "eval-harness: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
