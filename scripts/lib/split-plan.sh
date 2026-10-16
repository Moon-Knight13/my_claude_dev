#!/usr/bin/env bash
# split-plan.sh — the split plan for split-task co-execution (story D, issue #77).
# Sourced, not executed.
#
# A task like "make script.py with user data and generate an ansible playbook for
# it" has two halves: one that must stay on this machine, one that Claude can
# write. The LOCAL model proposes the split; this file is what stops that proposal
# from being trusted further than it deserves.
#
# WHY THE SPLIT IS MADE LOCALLY
# Asking Claude to help decide the split would mean describing the sensitive half
# to Claude in order to decide that Claude should not see it. So the planner is a
# local model, and nothing here is sent anywhere.
#
# WHAT CODE CHECKS, NOT THE MODEL
#   - the plan's shape: ids, routes, artifacts, dependencies (split_validate)
#   - artifact paths stay inside the working directory, and nowhere Git executes
#   - the owner's word list, on every part bound for the cloud (split_force_routes)
#   - the classifier, on every part bound for the cloud, unless the owner said
#     CLAUDE-ONLY — and the word list still applies then
# A part that fails either check is moved to `local`. The planner can make a part
# MORE local; nothing it writes can make a part less local than the checks allow.
#
# API:
#   split_extract <model reply>     prints the outermost JSON object, or nothing
#   split_validate <plan json>      -> SPLIT_ERR ("" = valid)
#   split_force_routes <plan> <mode> prints the plan with forced routes applied;
#                                    each forced part gets "forced": "floor"|"classifier"
#
# Returns by global (SPLIT_ERR) for the same reason guard-stack.sh does: a $(…)
# capture would run the check in a subshell and throw the result away.
# shellcheck disable=SC2034

_SP_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/orchestrator-route.sh disable=SC1091
source "${ORCH_ROUTE_LIB:-$_SP_SELF/orchestrator-route.sh}"

# Coarse on purpose. Every part bound for the cloud costs the owner an approval
# (E10), and #62 recorded confirmation fatigue as a design constraint: a plan in
# ten pieces is ten prompts, and the tenth gets waved through.
SPLIT_MAX_PARTS="${ORCH_SPLIT_MAX_PARTS:-4}"

SPLIT_ERR=""

split_extract() { # split_extract <model reply>
    local raw="${1:-}" obj
    # A local model wraps JSON in prose, a fence, or a leaked thinking block more
    # often than not. Take the outermost brace span and let jq decide.
    [[ "$raw" == *"{"* && "$raw" == *"}"* ]] || return 0
    obj="{${raw#*\{}"; obj="${obj%\}*}}"
    printf '%s' "$obj" | jq -c 'select(type=="object")' 2>/dev/null || true
}

# _split_bad_artifact <path> — rc 0 (bad) with a reason on stdout.
_split_bad_artifact() {
    local a="$1"
    [[ -n "$a" ]]                          || { echo "artifact is empty"; return 0; }
    [[ "$a" != /* ]]                       || { echo "artifact must be a relative path"; return 0; }
    [[ "$a" != '~'* ]]                     || { echo "artifact must be a relative path"; return 0; }
    [[ "$a" =~ ^[A-Za-z0-9._/-]+$ ]]       || { echo "artifact has characters outside [A-Za-z0-9._/-]"; return 0; }
    [[ "$a" != -* && "$a" != */ ]]         || { echo "artifact is not a file name"; return 0; }
    case "/$a/" in
        */../*|*/./*) echo "artifact may not contain . or .. segments"; return 0 ;;
        # Git runs what is in here. A cloud-written file landing in .git/hooks is
        # code execution on the next commit, so the whole directory is out.
        */.git/*)     echo "artifact may not be inside .git"; return 0 ;;
    esac
    return 1
}

split_validate() { # split_validate <plan json>
    SPLIT_ERR=""
    local p="$1" n bad
    if ! printf '%s' "$p" | jq -e 'type=="object" and (.parts|type=="array")' >/dev/null 2>&1; then
        SPLIT_ERR="plan is not an object with a parts array"; return 0
    fi
    n="$(printf '%s' "$p" | jq '.parts|length')"
    if (( n < 1 )); then SPLIT_ERR="plan has no parts"; return 0; fi
    if (( n > SPLIT_MAX_PARTS )); then
        SPLIT_ERR="plan has $n parts; the limit is $SPLIT_MAX_PARTS (keep the split coarse)"; return 0
    fi

    bad="$(printf '%s' "$p" | jq -r '
        .parts | to_entries[] | .key as $i | .value as $v |
        if ($v|type) != "object" then "part \($i+1) is not an object"
        elif (($v.id // "")|type) != "string" or (($v.id // "") | test("^[a-z][a-z0-9_-]{0,31}$") | not)
            then "part \($i+1) has an invalid id (lowercase letters, digits, _ and -, starting with a letter)"
        elif ($v.route // "") as $r | ($r != "local" and $r != "cloud")
            then "part \($v.id) has route \"\($v.route // "")\"; it must be local or cloud"
        elif (($v.task // "")|type) != "string" or ($v.task // "") == ""
            then "part \($v.id) has no task"
        elif (($v.artifact // "")|type) != "string"
            then "part \($v.id) has a non-string artifact"
        elif ($v.uses // []) | type != "array"
            then "part \($v.id) has a uses field that is not a list"
        else empty end' 2>/dev/null | head -1)"
    if [[ -n "$bad" ]]; then SPLIT_ERR="$bad"; return 0; fi

    if [[ -n "$(printf '%s' "$p" | jq -r '[.parts[].id] | group_by(.) | map(select(length>1)) | .[0][0] // empty')" ]]; then
        SPLIT_ERR="two parts share an id"; return 0
    fi
    if [[ -n "$(printf '%s' "$p" | jq -r '[.parts[].artifact] | group_by(.) | map(select(length>1)) | .[0][0] // empty')" ]]; then
        SPLIT_ERR="two parts write the same artifact"; return 0
    fi

    local id art why
    while IFS=$'\t' read -r id art; do
        if why="$(_split_bad_artifact "$art")"; then
            SPLIT_ERR="part $id: $why"; return 0
        fi
    done < <(printf '%s' "$p" | jq -r '.parts[] | [.id, .artifact] | @tsv')

    # Dependencies point from a cloud part to a local part, and only that way. A
    # local part never needs a contract to use its neighbour — it can read it — and
    # a cloud part that "uses" another cloud part has no interface to be given.
    bad="$(printf '%s' "$p" | jq -r '
        (.parts | map({key:.id, value:.route}) | from_entries) as $route |
        .parts[] | . as $v | ($v.uses // [])[] as $u |
        if $v.route != "cloud" then "part \($v.id) is local; only a cloud part may list uses"
        elif ($u|type) != "string" or $route[$u] == null then "part \($v.id) uses an unknown part"
        elif $route[$u] != "local" then "part \($v.id) uses \($u), which is not a local part"
        else empty end' 2>/dev/null | head -1)"
    if [[ -n "$bad" ]]; then SPLIT_ERR="$bad"; return 0; fi
    return 0
}

# split_force_routes <plan json> <mode> — apply the code-level checks to every
# part the planner sent to the cloud. Prints the resulting plan.
#
# The word list is checked against the task AND the artifact name, since both
# would be shown to Claude or named in its output. A hit is recorded as
# `"forced":"floor"` and nothing else: which term matched is never written down,
# here or anywhere (see orch_floor_match).
#
# When a part moves to local its `uses` are dropped — it is now on the same side
# of the boundary as what it used, and reads it directly.
split_force_routes() { # split_force_routes <plan json> <mode>
    local plan="$1" mode="${2:-AUTO}" i n route text forced
    n="$(printf '%s' "$plan" | jq '.parts|length')"
    for (( i = 0; i < n; i++ )); do
        route="$(printf '%s' "$plan" | jq -r --argjson i "$i" '.parts[$i].route')"
        [[ "$route" == cloud ]] || continue
        text="$(printf '%s' "$plan" | jq -r --argjson i "$i" '.parts[$i] | .task + "\n" + .artifact')"
        forced=""
        if orch_floor_match "$text"; then
            forced=floor
        elif [[ "$mode" == LOCAL-ONLY ]]; then
            forced=mode
        elif [[ "$mode" != CLAUDE-ONLY ]]; then
            # AUTO asks the judge, which fails closed: no classifier, an error or
            # a garbled verdict all come back sensitive.
            [[ "$(orch_classify "$text")" == nonsensitive ]] || forced=classifier
        fi
        if [[ -n "$forced" ]]; then
            plan="$(printf '%s' "$plan" | jq -c --argjson i "$i" --arg f "$forced" \
                '.parts[$i] |= (.route = "local" | .forced = $f | del(.uses))')"
        fi
    done
    # Every `uses` left in place still points at a local part: parts only ever
    # move toward local here, so no dependency can be left pointing at the cloud.
    printf '%s' "$plan"
}
