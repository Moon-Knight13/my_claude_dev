#!/usr/bin/env bash
# orchestrate.sh — G3 local-model orchestrator front door (MVP spine).
#
# Takes a prompt, decides WHERE it should run under the safety invariant, and
# dispatches it: a sensitive task stays on the local fleet and never touches the
# cloud; a non-sensitive task may hand off to the most capable eligible model
# (e.g. Claude via `claude -p`, where the A/B gates + caveman still apply).
#
# This is the MVP spine: mode switch + eligible-tier resolver (the invariant) +
# claude -p handoff + local reasoning-only. Deferred to later slices: the real
# local-LLM sensitivity classifier (stubbed fail-closed here), the sanitiser,
# the LiteLLM multi-machine pool, and the local shell-executor path. See
# _bmad-output/planning-artifacts/architecture-g3-local-orchestrator.md.
#
# Usage:
#   orchestrate.sh [--mode LOCAL-ONLY|CLAUDE-ONLY|AUTO] [--tools] [--dry-run] <prompt...>
#   orchestrate.sh --split [--mode ...] [--dry-run] <task...>
#   echo "<prompt>" | orchestrate.sh [--mode ...] [--tools] [--dry-run]
#
# --tools selects the LOCAL path's second dispatch mode: the executor
# (execute-local.sh), which can run shell and file work on the box instead of
# only reasoning about it. It changes nothing about WHERE a task is allowed to
# run — the tier is already decided by the time dispatch happens — so it cannot
# put a sensitive prompt on the frontier.
#
# --split hands the whole task to split.sh (#77): a LOCAL model proposes which
# parts stay here and which Claude may write, the owner approves the plan, and
# Claude sees only the declared interface of the local half. The task as a whole
# is never classified or sent anywhere — the planner is chosen from the local
# tiers only, and each part is judged on its own.
set -euo pipefail

_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# load-env first (env still wins), then the decision lib.
# shellcheck source=scripts/lib/load-env.sh disable=SC1090,SC1091
source "$_HERE/../lib/load-env.sh"
# shellcheck source=scripts/lib/orchestrator-route.sh disable=SC1091
source "$_HERE/../lib/orchestrator-route.sh"

ORCH_CONF="${ORCH_CONF:-$HOME/.config/orchestrator.conf}"
ORCH_LOG="${ORCH_LOG:-.ai/orchestrator-log.jsonl}"
LOCAL_MODEL_ENDPOINT="${LOCAL_MODEL_ENDPOINT:-http://host.docker.internal:11434}"

MODE_OVERRIDE=""; DRY_RUN=0; TOOLS=0; SPLIT=0; ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode) MODE_OVERRIDE="${2:-}"; shift 2 ;;
        --mode=*) MODE_OVERRIDE="${1#*=}"; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --tools) TOOLS=1; shift ;;
        --split) SPLIT=1; shift ;;
        --) shift; ARGS+=("$@"); break ;;
        *) ARGS+=("$1"); shift ;;
    esac
done

PROMPT="${ARGS[*]:-}"
if [[ -z "$PROMPT" && ! -t 0 ]]; then PROMPT="$(cat)"; fi
[[ -n "$PROMPT" ]] || { echo "orchestrate.sh: no prompt given" >&2; exit 2; }

orch_load_config "$ORCH_CONF"
MODE="$(orch_resolve_mode "$MODE_OVERRIDE")"

if [[ "$SPLIT" == 1 ]]; then
    # The planner reads the whole task, so it is picked exactly as a LOCAL-ONLY
    # prompt would be: the frontier is not in the eligible set at all.
    _pick="$(orch_pick_model "$(orch_eligible_tiers sensitive LOCAL-ONLY)")" || {
        echo "orchestrate.sh: no local model to plan with (check $ORCH_CONF)" >&2; exit 3; }
    _name="${_pick%%|*}"; _ep="${_pick##*|}"
    _split_args=(--mode "$MODE")
    [[ "$DRY_RUN" == 1 ]] && _split_args+=(--dry-run)
    exec env ORCH_SPLIT_MODEL="$_name" ORCH_SPLIT_ENDPOINT="${_ep:-$LOCAL_MODEL_ENDPOINT}" \
             ORCH_LOG="$ORCH_LOG" "${ORCH_SPLIT_BIN:-$_HERE/split.sh}" "${_split_args[@]}" -- "$PROMPT"
fi

# THE DETERMINISTIC FLOOR (#65) — ahead of mode resolution's effect, and ahead of
# the classifier. A term from the owner's private list forces `sensitive` in EVERY
# mode, including CLAUDE-ONLY.
#
# CLAUDE-ONLY is precisely where this matters: it skips classification entirely on
# the human's assertion that the prompt is fine for the cloud — an assertion made
# from memory. The list exists because memory fails. So the floor overrides it, and
# the owner must edit the list to proceed rather than talk past it.
#
# It never reports WHICH term matched (see orch_floor_match); `floor` below is a
# boolean for exactly that reason.
FLOOR=false
if orch_floor_match "$PROMPT"; then FLOOR=true; fi

# Classify only when AUTO needs it; the manual modes ARE the human's verdict.
# A floor hit short-circuits: no classifier call, no model in the decision path.
if [[ "$FLOOR" == true ]]; then
    SENSITIVE="sensitive"
else
    case "$MODE" in
        LOCAL-ONLY)  SENSITIVE="sensitive" ;;
        CLAUDE-ONLY) SENSITIVE="nonsensitive" ;;   # human asserts cloud is acceptable
        *)           SENSITIVE="$(orch_classify "$PROMPT")" ;;
    esac
fi

# CLAUDE-ONLY hands the resolver every tier by design (the human acting as
# classifier). A floor hit removes that authority, so tiers resolve as if the human
# had chosen LOCAL-ONLY. The real mode is still what gets logged — the log records
# what the human asked for and that the floor overrode it, not a rewritten history.
TIER_MODE="$MODE"
[[ "$FLOOR" == true ]] && TIER_MODE="LOCAL-ONLY"

TIERS="$(orch_eligible_tiers "$SENSITIVE" "$TIER_MODE")"
PICK="$(orch_pick_model "$TIERS")" || { echo "orchestrate.sh: no eligible model in tiers: $TIERS (check $ORCH_CONF)" >&2; exit 3; }
P_NAME="${PICK%%|*}"; _r="${PICK#*|}"; P_TIER="${_r%%|*}"; _r="${_r#*|}"; P_RANK="${_r%%|*}"; P_ENDPOINT="${_r#*|}"

# The invariant, asserted at the last moment before dispatch: a sensitive task
# must NEVER resolve to a tier that egresses. Belt-and-braces over the resolver.
if [[ "$SENSITIVE" == "sensitive" ]] && orch_tier_egresses "$P_TIER"; then
    echo "orchestrate.sh: INVARIANT VIOLATION — sensitive task resolved to egressing tier '$P_TIER'; refusing" >&2
    exit 4
fi

# Metadata-only log: mode/verdict/tier/model — NEVER the prompt (it may be the
# sensitive content this whole control exists to protect).
mkdir -p "$(dirname "$ORCH_LOG")" 2>/dev/null || true
_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
printf '{"ts":"%s","mode":"%s","sensitive":"%s","floor":%s,"tier":"%s","model":"%s","tools":%s,"dry_run":%s}\n' \
    "$_ts" "$MODE" "$SENSITIVE" "$FLOOR" "$P_TIER" "$P_NAME" \
    "$([[ "$TOOLS" == 1 ]] && echo true || echo false)" \
    "$([[ "$DRY_RUN" == 1 ]] && echo true || echo false)" \
    >> "$ORCH_LOG" 2>/dev/null || true

if [[ "$DRY_RUN" == 1 ]]; then
    printf 'mode=%s sensitive=%s -> tier=%s model=%s (rank %s) exec=%s\n' \
        "$MODE" "$SENSITIVE" "$P_TIER" "$P_NAME" "$P_RANK" \
        "$([[ "$TOOLS" == 1 ]] && echo tools || echo reasoning)"
    exit 0
fi

# --- dispatch ---------------------------------------------------------------
case "$P_TIER" in
    frontier)
        # Handoff to Claude headless. A/B gates + caveman apply on this path for
        # free (the PreToolUse hook + commit guard front the CLI). Only a
        # NON-sensitive prompt ever reaches here.
        command -v claude >/dev/null 2>&1 || { echo "orchestrate.sh: 'claude' CLI not found for frontier handoff" >&2; exit 5; }
        SEND="$PROMPT"
        # C2 sanitiser (opt-in): strip incidental identifiers before egress. It is
        # defense-in-depth on top of the classifier, not the gate. If it cannot
        # sanitise, ORCH_SANITISE_ON_FAIL decides: passthrough (default — the
        # classifier already cleared this prompt) or block.
        if [[ -n "${ORCH_SANITISER:-}" && -x "${ORCH_SANITISER}" ]]; then
            if _san="$(printf '%s' "$PROMPT" | "$ORCH_SANITISER")" && [[ -n "$_san" ]]; then
                SEND="$_san"
            else
                case "${ORCH_SANITISE_ON_FAIL:-passthrough}" in
                    block) echo "orchestrate.sh: sanitiser failed and ORCH_SANITISE_ON_FAIL=block; refusing handoff" >&2; exit 7 ;;
                    *)     echo "orchestrate.sh: sanitiser failed; passing original through (classifier already cleared it)" >&2 ;;
                esac
            fi
        fi
        exec claude -p "$SEND" ;;
    host-local|network-local)
        local_ep="${P_ENDPOINT:-$LOCAL_MODEL_ENDPOINT}"
        # --tools: hand the task to the executor (enforcement point #2) so a
        # sensitive task that NEEDS tools can actually be done here, instead of
        # degrading to reasoning about work it cannot perform. Opt-in, because a
        # shell is a bigger thing to hand a model than a question is.
        #
        # The executor gates every command through guard-stack.sh itself; this
        # script does not pre-approve anything on its way there. ORCH_CALLER says
        # who is on the other end, which is what decides whether the executor is
        # willing to answer at all (R8).
        if [[ "$TOOLS" == 1 ]]; then
            _exec_bin="${ORCH_EXECUTOR_BIN:-$_HERE/execute-local.sh}"
            [[ -x "$_exec_bin" ]] || { echo "orchestrate.sh: executor not found or not executable: $_exec_bin" >&2; exit 8; }
            exec env ORCH_CALLER="${ORCH_CALLER:-human}" \
                     ORCH_EXEC_ENDPOINT="$local_ep" \
                     ORCH_EXEC_MODEL="$P_NAME" \
                     ORCH_LOG="$ORCH_LOG" \
                     "$_exec_bin" "$PROMPT"
        fi
        # Reasoning-only local call (Ollama generate) — the default local path.
        curl -sfS "${local_ep}/api/generate" \
            -H "Content-Type: application/json" \
            -d "$(jq -n --arg model "$P_NAME" --arg prompt "$PROMPT" '{model:$model, prompt:$prompt, stream:false}')" \
            | jq -r '.response' ;;
    *)
        echo "orchestrate.sh: unknown tier '$P_TIER'" >&2; exit 6 ;;
esac
