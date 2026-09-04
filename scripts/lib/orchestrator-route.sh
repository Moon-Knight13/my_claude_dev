#!/usr/bin/env bash
# orchestrator-route.sh — the routing DECISION logic for the G3 local-model
# orchestrator front door. Pure functions, no I/O, so the safety invariant is
# unit-testable in isolation from any model call.
#
# THE INVARIANT (non-negotiable, structural — see architecture-g3):
#   Sensitivity gates tier eligibility BEFORE capability ranking. A sensitive
#   task is NEVER eligible for the frontier (cloud) tier, however capable — the
#   cloud endpoint is simply absent from the eligible set, so the picker cannot
#   choose it. This keeps Org PII/IP off a cloud model as a property of the code,
#   not a prompt the model could be talked out of.
#
# Model tiers:
#   frontier       cloud, egresses (e.g. Claude) — eligible ONLY for non-sensitive
#   host-local     a model on the developer's own machine — never egresses
#   network-local  a model on another machine in the local network — never egresses
#
# API:
#   orch_load_config <file>              parse ORCH_MODE + the ORCH_MODEL registry
#   orch_resolve_mode <override>         override > config > default(AUTO); validated
#   orch_classify <prompt>               "sensitive"|"nonsensitive" (MVP: stub)
#   orch_eligible_tiers <sensitive> <mode>   the eligible tier set (the invariant)
#   orch_pick_model <eligible-tiers>     best-rank model in an eligible tier
#   orch_tier_egresses <tier>            0 if the tier leaves the box (frontier)

ORCH_MODE="AUTO"
# Parallel arrays form the model registry (bash 4+).
ORCH_M_NAME=(); ORCH_M_TIER=(); ORCH_M_RANK=(); ORCH_M_ENDPOINT=()

# _orch_valid_tier <tier> — the only tiers the router understands.
_orch_valid_tier() { case "$1" in frontier|host-local|network-local) return 0 ;; *) return 1 ;; esac; }

orch_load_config() { # orch_load_config <file>
    local f="${1:-}" line k v
    ORCH_M_NAME=(); ORCH_M_TIER=(); ORCH_M_RANK=(); ORCH_M_ENDPOINT=()
    [[ -n "$f" && -f "$f" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%$'\r'}"
        line="${line%%#*}"                                   # strip comments
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        [[ "$line" == *=* ]] || continue
        k="${line%%=*}"; v="${line#*=}"
        k="${k//[[:space:]]/}"
        v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"   # trim
        case "$k" in
            ORCH_MODE)
                ORCH_MODE="${v//[[:space:]]/}" ;;
            ORCH_MODEL)
                # value: name|tier|rank|endpoint   (endpoint optional)
                local name tier rank ep rest
                name="${v%%|*}"; rest="${v#*|}"
                tier="${rest%%|*}"; rest="${rest#*|}"
                rank="${rest%%|*}"; ep="${rest#*|}"
                [[ "$ep" == "$rest" && "$rest" == "$rank" ]] && ep=""   # no endpoint field
                name="${name//[[:space:]]/}"; tier="${tier//[[:space:]]/}"; rank="${rank//[[:space:]]/}"
                [[ -n "$name" ]] || continue
                _orch_valid_tier "$tier" || continue          # ignore unknown tiers (fail safe)
                [[ "$rank" =~ ^[0-9]+$ ]] || rank=0
                ORCH_M_NAME+=("$name"); ORCH_M_TIER+=("$tier")
                ORCH_M_RANK+=("$rank"); ORCH_M_ENDPOINT+=("$ep") ;;
        esac
    done < "$f"
    return 0
}

orch_resolve_mode() { # orch_resolve_mode <override> ; prints the effective mode
    local override="${1:-}" m="${1:-$ORCH_MODE}"
    [[ -n "$override" ]] && m="$override"
    m="${m//[[:space:]]/}"
    case "$m" in
        LOCAL-ONLY|CLAUDE-ONLY|AUTO) printf '%s' "$m" ;;
        *) printf 'AUTO' ;;                                  # unknown -> safe default
    esac
}

# orch_classify <prompt> — MVP STUB. The real classifier is a local-LLM judge
# (D3), deferred to its own spec + eval. Until it exists, AUTO mode must not be
# able to send anything to the cloud on a guess, so this FAILS CLOSED: every
# query is treated as sensitive. Replace this function (or set ORCH_CLASSIFIER)
# when the judge lands; it must keep the fail-closed default on any error.
orch_classify() { # orch_classify <prompt> ; prints "sensitive"|"nonsensitive"
    if [[ -n "${ORCH_CLASSIFIER:-}" && -x "${ORCH_CLASSIFIER}" ]]; then
        local out
        out="$("$ORCH_CLASSIFIER" "$1" 2>/dev/null)" || { printf 'sensitive'; return 0; }
        case "$out" in
            nonsensitive) printf 'nonsensitive' ;;
            *)            printf 'sensitive' ;;             # anything else -> fail closed
        esac
        return 0
    fi
    printf 'sensitive'                                       # no classifier yet -> fail closed
}

# orch_eligible_tiers <sensitive> <mode> — THE INVARIANT. Prints the space-
# separated tier set the picker may choose from.
#   LOCAL-ONLY  : human forces local (treated as sensitive)      -> locals only
#   CLAUDE-ONLY : human asserts this is fine for the cloud        -> all tiers
#                 (manual override IS the human acting as classifier)
#   AUTO        : sensitive -> locals only ; nonsensitive -> all tiers
# In every path, a sensitive verdict yields locals-only — frontier is absent.
orch_eligible_tiers() { # orch_eligible_tiers <sensitive|nonsensitive> <mode>
    local sensitive="$1" mode="$2"
    case "$mode" in
        LOCAL-ONLY)  printf 'host-local network-local' ;;
        CLAUDE-ONLY) printf 'frontier host-local network-local' ;;
        *) # AUTO
            if [[ "$sensitive" == "sensitive" ]]; then
                printf 'host-local network-local'
            else
                printf 'frontier host-local network-local'
            fi ;;
    esac
}

# orch_tier_egresses <tier> — 0 (true) if choosing this tier sends data off the
# box. Used by the caller to assert the invariant before dispatch.
orch_tier_egresses() { [[ "$1" == "frontier" ]]; }

# orch_pick_model <eligible-tiers> — highest-rank model whose tier is in the
# eligible set. Prints "name|tier|rank|endpoint"; returns 1 if none eligible.
orch_pick_model() { # orch_pick_model "<tier> <tier> ..."
    local eligible=" $1 " i best=-1 bi=-1
    for i in "${!ORCH_M_NAME[@]}"; do
        [[ "$eligible" == *" ${ORCH_M_TIER[$i]} "* ]] || continue
        if (( ORCH_M_RANK[i] > best )); then best="${ORCH_M_RANK[$i]}"; bi="$i"; fi
    done
    (( bi >= 0 )) || return 1
    printf '%s|%s|%s|%s' "${ORCH_M_NAME[$bi]}" "${ORCH_M_TIER[$bi]}" "${ORCH_M_RANK[$bi]}" "${ORCH_M_ENDPOINT[$bi]}"
}
