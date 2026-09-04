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
#   orchestrate.sh [--mode LOCAL-ONLY|CLAUDE-ONLY|AUTO] [--dry-run] <prompt...>
#   echo "<prompt>" | orchestrate.sh [--mode ...] [--dry-run]
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

MODE_OVERRIDE=""; DRY_RUN=0; ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode) MODE_OVERRIDE="${2:-}"; shift 2 ;;
        --mode=*) MODE_OVERRIDE="${1#*=}"; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --) shift; ARGS+=("$@"); break ;;
        *) ARGS+=("$1"); shift ;;
    esac
done

PROMPT="${ARGS[*]:-}"
if [[ -z "$PROMPT" && ! -t 0 ]]; then PROMPT="$(cat)"; fi
[[ -n "$PROMPT" ]] || { echo "orchestrate.sh: no prompt given" >&2; exit 2; }

orch_load_config "$ORCH_CONF"
MODE="$(orch_resolve_mode "$MODE_OVERRIDE")"

# Classify only when AUTO needs it; the manual modes ARE the human's verdict.
case "$MODE" in
    LOCAL-ONLY)  SENSITIVE="sensitive" ;;
    CLAUDE-ONLY) SENSITIVE="nonsensitive" ;;   # human asserts cloud is acceptable
    *)           SENSITIVE="$(orch_classify "$PROMPT")" ;;
esac

TIERS="$(orch_eligible_tiers "$SENSITIVE" "$MODE")"
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
printf '{"ts":"%s","mode":"%s","sensitive":"%s","tier":"%s","model":"%s","dry_run":%s}\n' \
    "$_ts" "$MODE" "$SENSITIVE" "$P_TIER" "$P_NAME" "$([[ "$DRY_RUN" == 1 ]] && echo true || echo false)" \
    >> "$ORCH_LOG" 2>/dev/null || true

if [[ "$DRY_RUN" == 1 ]]; then
    printf 'mode=%s sensitive=%s -> tier=%s model=%s (rank %s)\n' "$MODE" "$SENSITIVE" "$P_TIER" "$P_NAME" "$P_RANK"
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
        # Reasoning-only local call (Ollama generate). The local shell-executor
        # path (D1 fallback) is a later slice.
        local_ep="${P_ENDPOINT:-$LOCAL_MODEL_ENDPOINT}"
        curl -sfS "${local_ep}/api/generate" \
            -H "Content-Type: application/json" \
            -d "$(jq -n --arg model "$P_NAME" --arg prompt "$PROMPT" '{model:$model, prompt:$prompt, stream:false}')" \
            | jq -r '.response' ;;
    *)
        echo "orchestrate.sh: unknown tier '$P_TIER'" >&2; exit 6 ;;
esac
