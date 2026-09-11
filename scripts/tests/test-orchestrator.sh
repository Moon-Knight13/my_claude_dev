#!/usr/bin/env bash
# test-orchestrator.sh — routing-decision tests for the G3 orchestrator spine.
# The point of these tests is THE INVARIANT: a task the router treats as
# sensitive must never resolve to the egressing (frontier) tier, even when a
# frontier model outranks every local one.
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
ORCH_MODEL=qwen-pc1|network-local|55|http://10.0.0.21:11434
EOF

# ============================================================================
echo "== decision lib (pure) =="
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/orchestrator-route.sh"
orch_load_config "$CONF"

check "registry loaded 3 models" "${#ORCH_M_NAME[@]}" 3
check "config mode is AUTO"      "$ORCH_MODE"          AUTO

# resolve_mode: override > config > default
check "override wins"           "$(orch_resolve_mode LOCAL-ONLY)" LOCAL-ONLY
check "empty override -> config" "$(orch_resolve_mode '')"        AUTO
check "garbage mode -> AUTO"    "$(orch_resolve_mode WHATEVER)"   AUTO

# classify stub: no classifier configured -> fail closed (sensitive)
check "classify stub fails closed" "$(orch_classify 'refactor this function')" sensitive
# a classifier that says nonsensitive is honoured; garbage/failure -> sensitive
CL="$TMP/cl.sh"; printf '#!/usr/bin/env bash\necho nonsensitive\n' > "$CL"; chmod +x "$CL"
check "classifier nonsensitive honoured" "$(ORCH_CLASSIFIER="$CL" orch_classify x)" nonsensitive
CLG="$TMP/clg.sh"; printf '#!/usr/bin/env bash\necho maybe\n' > "$CLG"; chmod +x "$CLG"
check "classifier garbage -> sensitive"  "$(ORCH_CLASSIFIER="$CLG" orch_classify x)" sensitive
CLF="$TMP/clf.sh"; printf '#!/usr/bin/env bash\nexit 1\n' > "$CLF"; chmod +x "$CLF"
check "classifier failure -> sensitive"  "$(ORCH_CLASSIFIER="$CLF" orch_classify x)" sensitive

# eligible_tiers: THE INVARIANT — sensitive never yields frontier
has_frontier() { case " $1 " in *" frontier "*) echo yes ;; *) echo no ;; esac; }
check "AUTO+sensitive: no frontier"     "$(has_frontier "$(orch_eligible_tiers sensitive AUTO)")"        no
check "AUTO+nonsensitive: has frontier" "$(has_frontier "$(orch_eligible_tiers nonsensitive AUTO)")"     yes
check "LOCAL-ONLY: no frontier"         "$(has_frontier "$(orch_eligible_tiers nonsensitive LOCAL-ONLY)")" no
check "CLAUDE-ONLY: has frontier"       "$(has_frontier "$(orch_eligible_tiers sensitive CLAUDE-ONLY)")"  yes

# tier_egresses
{ orch_tier_egresses frontier && echo yes || echo no; } | { read -r r; check "frontier egresses" "$r" yes; }
{ orch_tier_egresses host-local && echo yes || echo no; } | { read -r r; check "host-local no egress" "$r" no; }

# pick_model: best rank in the eligible set
tier_of() { local p; p="$(orch_pick_model "$1")" && printf '%s' "$(t=${p#*|}; echo "${t%%|*}")"; }
name_of() { local p; p="$(orch_pick_model "$1")" && printf '%s' "${p%%|*}"; }
check "all tiers -> picks frontier (rank 100)" "$(name_of 'frontier host-local network-local')" claude
# INVARIANT: locals-only eligible -> best LOCAL, NEVER the higher-ranked frontier
check "locals-only -> picks local, not frontier" "$(tier_of 'host-local network-local')" host-local
check "locals-only -> qwen-host by rank"         "$(name_of 'host-local network-local')"  qwen-host
# no eligible model -> failure (rc 1)
if orch_pick_model 'nonexistent-tier' >/dev/null 2>&1; then r=picked; else r=none; fi
check "no eligible -> none" "$r" none

# ============================================================================
echo "== end-to-end (orchestrate.sh --dry-run) =="
ORCH="$ROOT/scripts/orchestrator/orchestrate.sh"
run() { ORCH_CONF="$CONF" ORCH_LOG="$TMP/log.jsonl" bash "$ORCH" "$@" 2>/dev/null; }

# AUTO with no classifier -> fail closed -> sensitive -> local tier (NOT frontier)
out="$(run --dry-run 'delete the prod database')"
check "AUTO dry-run is sensitive"       "$(grep -o 'sensitive=[a-z]*' <<<"$out")" "sensitive=sensitive"
case "$out" in *"tier=frontier"*) bad "INVARIANT: AUTO sensitive reached frontier ($out)";; *) ok "AUTO sensitive stays off frontier";; esac

# CLAUDE-ONLY -> human asserts cloud ok -> frontier
out="$(run --mode CLAUDE-ONLY --dry-run 'summarise the public README')"
case "$out" in *"tier=frontier"*) ok "CLAUDE-ONLY selects frontier";; *) bad "CLAUDE-ONLY should select frontier ($out)";; esac

# LOCAL-ONLY -> never frontier even for a benign prompt
out="$(run --mode LOCAL-ONLY --dry-run 'summarise the public README')"
case "$out" in *"tier=frontier"*) bad "INVARIANT: LOCAL-ONLY reached frontier ($out)";; *) ok "LOCAL-ONLY stays local";; esac

# the metadata log records the decision but NOT the prompt text
run --dry-run 'a very secret sensitive prompt string' >/dev/null
if grep -q 'secret sensitive prompt' "$TMP/log.jsonl" 2>/dev/null; then
    bad "log leaked the prompt text"
else ok "log records metadata only, never the prompt"; fi

echo "== C2 sanitiser wiring (frontier dispatch) =="
MB="$TMP/bin2"; mkdir -p "$MB"
# shellcheck disable=SC2016  # $2 is the mock's own runtime arg (claude -p <prompt>), must not expand now
printf '#!/usr/bin/env bash\necho "CLAUDE_GOT:$2"\n' > "$MB/claude"; chmod +x "$MB/claude"
UPSAN="$TMP/upsan.sh";  printf '#!/usr/bin/env bash\ntr "[:lower:]" "[:upper:]"\n' > "$UPSAN"; chmod +x "$UPSAN"
FAILSAN="$TMP/failsan.sh"; printf '#!/usr/bin/env bash\nexit 1\n' > "$FAILSAN"; chmod +x "$FAILSAN"
# dead local endpoint so the sensitive-path test can't make a real model call
E=(ORCH_CONF="$CONF" ORCH_LOG="$TMP/log.jsonl" LOCAL_MODEL_ENDPOINT="http://127.0.0.1:9")
# sanitiser transforms -> claude receives the sanitised (uppercased) prompt
out="$(env "${E[@]}" PATH="$MB:$PATH" ORCH_SANITISER="$UPSAN" bash "$ORCH" --mode CLAUDE-ONLY 'hello world' 2>/dev/null)"
check "sanitised prompt reaches claude" "$out" "CLAUDE_GOT:HELLO WORLD"
# sanitiser fails + block -> refuse handoff (exit 7)
env "${E[@]}" PATH="$MB:$PATH" ORCH_SANITISER="$FAILSAN" ORCH_SANITISE_ON_FAIL=block bash "$ORCH" --mode CLAUDE-ONLY 'hello' >/dev/null 2>&1; rc=$?
check "sanitiser fail + block -> exit 7" "$rc" 7
# sanitiser fails + passthrough (default) -> claude gets the original
out="$(env "${E[@]}" PATH="$MB:$PATH" ORCH_SANITISER="$FAILSAN" bash "$ORCH" --mode CLAUDE-ONLY 'hello' 2>/dev/null)"
check "sanitiser fail passthrough -> original" "$out" "CLAUDE_GOT:hello"
# no sanitiser configured -> original reaches claude unchanged
out="$(env "${E[@]}" PATH="$MB:$PATH" bash "$ORCH" --mode CLAUDE-ONLY 'hello' 2>/dev/null)"
check "no sanitiser -> original to claude" "$out" "CLAUDE_GOT:hello"
# a SENSITIVE prompt never reaches the frontier/claude even with a sanitiser set
out="$(env "${E[@]}" PATH="$MB:$PATH" ORCH_SANITISER="$UPSAN" bash "$ORCH" --mode LOCAL-ONLY 'hello' 2>/dev/null)"
case "$out" in *CLAUDE_GOT*) bad "INVARIANT: sensitive prompt reached claude via sanitiser path";; *) ok "sensitive never reaches claude (sanitiser irrelevant)";; esac

echo "== --tools: dispatch to the local executor (S2) =="
# --tools is the second dispatch mode for the LOCAL tiers. It must not become a
# second way onto the frontier: the tier decision is made before dispatch and is
# not revisited here.
FAKE_EXEC="$TMP/fake-exec.sh"
EXEC_SEEN="$TMP/exec-seen.txt"
cat > "$FAKE_EXEC" <<EOF
#!/usr/bin/env bash
printf '%s|%s\n' "\${ORCH_CALLER:-unset}" "\$1" >> "$EXEC_SEEN"
echo "EXEC_RAN"
EOF
chmod +x "$FAKE_EXEC"

: > "$EXEC_SEEN"
out="$(env "${E[@]}" ORCH_EXECUTOR_BIN="$FAKE_EXEC" bash "$ORCH" --tools --mode LOCAL-ONLY 'fix the sensitive script' 2>/dev/null)"
check "--tools dispatches to the executor" "$out" "EXEC_RAN"
check "executor received the prompt"       "$(cut -d'|' -f2 < "$EXEC_SEEN")" "fix the sensitive script"
check "executor told the caller is human"  "$(cut -d'|' -f1 < "$EXEC_SEEN")" human

# Without --tools the local path stays reasoning-only: the executor is opt-in, so
# an existing local run does not silently gain a shell.
: > "$EXEC_SEEN"
env "${E[@]}" ORCH_EXECUTOR_BIN="$FAKE_EXEC" bash "$ORCH" --mode LOCAL-ONLY 'fix the sensitive script' >/dev/null 2>&1
check "no --tools means no executor" "$(wc -l < "$EXEC_SEEN" | tr -d ' ')" 0

# THE INVARIANT under --tools: a frontier-bound run still goes to claude, and the
# executor is not involved at all.
: > "$EXEC_SEEN"
out="$(env "${E[@]}" PATH="$MB:$PATH" ORCH_EXECUTOR_BIN="$FAKE_EXEC" bash "$ORCH" --tools --mode CLAUDE-ONLY 'summarise the public README' 2>/dev/null)"
check "--tools + frontier still reaches claude" "$out" "CLAUDE_GOT:summarise the public README"
check "--tools + frontier never runs the executor" "$(wc -l < "$EXEC_SEEN" | tr -d ' ')" 0

# A floor hit forces local; --tools must follow the floor, not the requested mode.
FTMP="$TMP/floorlist.txt"; echo "projectnimbus" > "$FTMP"
: > "$EXEC_SEEN"
out="$(env "${E[@]}" PATH="$MB:$PATH" ORCH_TERM_LIST="$FTMP" ORCH_EXECUTOR_BIN="$FAKE_EXEC" \
      bash "$ORCH" --tools --mode CLAUDE-ONLY 'rework projectnimbus deploy' 2>/dev/null)"
check "floor + --tools runs locally" "$out" "EXEC_RAN"
case "$out" in *CLAUDE_GOT*) bad "INVARIANT: floor hit still reached claude under --tools";; *) ok "floor hit never reaches claude under --tools";; esac

# The dry run says which local path would be taken, so the choice is visible
# before anything executes.
out="$(run --tools --mode LOCAL-ONLY --dry-run 'fix the sensitive script')"
contains_tools=no; case "$out" in *"exec=tools"*) contains_tools=yes ;; esac
check "dry-run reports the executor path" "$contains_tools" yes
out="$(run --mode LOCAL-ONLY --dry-run 'fix the sensitive script')"
contains_tools=no; case "$out" in *"exec=reasoning"*) contains_tools=yes ;; esac
check "dry-run reports reasoning-only by default" "$contains_tools" yes

echo
echo "orchestrator: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
