#!/usr/bin/env bash
# ctp-guard.sh — the single source of truth for what the tool bridge permits.
#
# Sourced by BOTH scripts/ctp-bridge.sh (the wrapper, human-shell path) and
# .claude/hooks/pretooluse-ctp.sh (the agent path). Keeping the gates here means
# the two callers cannot drift: a verb the hook lets through is exactly a verb
# the wrapper will run, and vice versa.
#
# Nothing here reads caller-supplied environment for a boundary value. The
# config file is the boundary; an agent that can set an env var in the same call
# it makes must not be able to widen its own limits. See .ctp-bridge.conf.example.
#
# No command strings are matched to classify — classification is on the parsed
# ctp argv. String matching is defeated by quoting and env prefixes; that is the
# failure shape docs/PROJECT.md warns about.

# --- config ------------------------------------------------------------------
# ctp_load_config <conf_path> — populate the guard globals from the file. Returns
# 1 if the file is missing (the caller decides whether that is fatal). Values are
# taken literally; no shell expansion beyond a leading ~ in secret paths.
CTP_ALLOWED_TARGET=""
CTP_ALLOWED_ENCLAVES=""
CTP_ALLOWED_TEAM_NR=""
CTP_ALLOWED_TEAM=""
CTP_ALLOWED_VERBS="deploy deploy-role"
CTP_CONTAINER=""
CTP_PROJECT_DIR=""
CTP_INVENTORY_PATH=""
CTP_SECRET_PATHS=""
CTP_PII_PATHS=""
CTP_REMOTE_HOST=""

ctp_load_config() {
    local conf="$1" line key val
    [[ -f "$conf" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        key="${line%%=*}"
        val="${line#*=}"
        key="${key//[[:space:]]/}"
        # shellcheck disable=SC2034  # CTP_PROJECT_DIR is consumed cross-file by ctp-bridge.sh
        case "$key" in
            CTP_ALLOWED_TARGET)   CTP_ALLOWED_TARGET="$val" ;;
            CTP_ALLOWED_ENCLAVES) CTP_ALLOWED_ENCLAVES="$val" ;;
            CTP_ALLOWED_TEAM_NR) CTP_ALLOWED_TEAM_NR="$val" ;;
            CTP_ALLOWED_TEAM)    CTP_ALLOWED_TEAM="$val" ;;
            CTP_ALLOWED_VERBS)   CTP_ALLOWED_VERBS="$val" ;;
            CTP_CONTAINER)       CTP_CONTAINER="$val" ;;
            CTP_PROJECT_DIR)     CTP_PROJECT_DIR="$val" ;;
            CTP_INVENTORY_PATH)  CTP_INVENTORY_PATH="$val" ;;
            CTP_SECRET_PATHS)    CTP_SECRET_PATHS="$val" ;;
            CTP_PII_PATHS)       CTP_PII_PATHS="$val" ;;
            CTP_REMOTE_HOST)     CTP_REMOTE_HOST="$val" ;;
        esac
    done < "$conf"
    return 0
}

# --- approval handoff (hook -> wrapper) --------------------------------------
# The Bash tool has no TTY, so the wrapper's own confirm prompt cannot reach the
# human on the agent path. The human confirms at the hook's `ask` prompt instead;
# the hook then writes a single-use, argv-bound, short-TTL token here, and the
# wrapper consumes it in place of prompting. Both derive the path from here so
# they agree. This authenticates "the hook approved THIS invocation" to the same
# strength as the rest of the hook (a shared-account hook is hygiene + human-in-
# the-loop, not a cryptographic boundary — see docs/PROJECT.md).
ctp_state_dir()     { printf '%s' "${CTP_BRIDGE_STATE:-$HOME/.local/state/ctp-bridge}"; }
ctp_approval_file() { printf '%s/approval' "$(ctp_state_dir)"; }

# ctp_container — the container name, derived at runtime unless overridden. Never
# hardcoded; the vendor convention is catapult-<user>.
ctp_container() {
    if [[ -n "$CTP_CONTAINER" ]]; then printf '%s' "$CTP_CONTAINER"; return 0; fi
    printf 'catapult-%s' "${CTP_TARGET_USER:-$(id -un)}"
}

# ctp_inventory_path — the inventory path inside the container.
ctp_inventory_path() {
    printf '%s' "${CTP_INVENTORY_PATH:-/srv/inventories/dcm/inventory/}"
}

# --- live team query ---------------------------------------------------------
# ctp_query_team <target> — query ansible-inventory for the target's team number.
# Returns the team number (actor_nr_str) on stdout. Exit codes:
#   0 — success, team number printed
#   1 — host not found in inventory (ansible-inventory exit 5)
#   2 — query failed (SSH/docker/parse error)
#
# The query runs: ssh <CTP_REMOTE_HOST> docker exec <container>
#   ansible-inventory -i <inventory> -e @<vault> --vault-password-file <unlock>
#   --host <target> 2>/dev/null | jq -r '.actor_nr_str'
#
# Override CTP_QUERY_TEAM_FN with a function name to replace this for testing.
ctp_query_team() {
    if [[ -n "${CTP_QUERY_TEAM_FN:-}" ]] && declare -F "$CTP_QUERY_TEAM_FN" >/dev/null 2>&1; then
        "$CTP_QUERY_TEAM_FN" "$@"
        return $?
    fi

    local target="$1"
    local container inventory_path remote_host
    container="$(ctp_container)"
    inventory_path="$(ctp_inventory_path)"
    remote_host="${CTP_REMOTE_HOST:-}"

    local docker_cmd
    docker_cmd=(docker exec "$container"
        /home/builder/catapult-venv/.venv/bin/ansible-inventory
        -i "$inventory_path"
        -e "@/home/builder/.vault/vlt"
        --vault-password-file /home/builder/.vault/unlock-vault.sh
        --host "$target")

    local output rc
    if [[ -n "$remote_host" ]]; then
        output="$(ssh -o BatchMode=yes "$remote_host" "${docker_cmd[@]}" 2>/dev/null)" && rc=0 || rc=$?
    else
        output="$("${docker_cmd[@]}" 2>/dev/null)" && rc=0 || rc=$?
    fi

    if [[ "$rc" -eq 5 ]]; then
        return 1
    elif [[ "$rc" -ne 0 ]]; then
        return 2
    fi

    local team_nr
    team_nr="$(printf '%s' "$output" | jq -r '.actor_nr_str' 2>/dev/null)" || return 2
    if [[ -z "$team_nr" || "$team_nr" == "null" ]]; then
        return 2
    fi
    printf '%s' "$team_nr"
    return 0
}

# --- glob / target -----------------------------------------------------------
# ctp_has_glob <string> — 0 if it contains a glob metacharacter. deploy and
# deploy '*' are different classes; one character must not separate a listing
# from a range-wide op.
ctp_has_glob() {
    case "$1" in
        *'*'*|*'?'*|*'['*|*']'*) return 0 ;;
        *) return 1 ;;
    esac
}

# --- classification ----------------------------------------------------------
# ctp_classify <ctp-argv...> — prints one verdict and returns:
#   0  "confirm <class> <verb> <target|->"   reachable; caller confirms + runs
#   1  "refuse <reason>"                      not permitted (never run)
# class is one of: mutating | read | inventory — the wrapper uses it to pick
# preconditions. The verdict is derived from the parsed argv only.
#
# Two gates protect a mutating verb:
#   - explicit override: CTP_ALLOWED_TARGET (space-separated hostnames) —
#     a target matching any entry passes immediately (custom-named hosts).
#   - live inventory query: CTP_ALLOWED_TEAM_NR (comma-separated team numbers,
#     e.g. "10" or "10,2"). The target is queried via ansible-inventory on
#     the catapult container; the returned actor_nr_str must match any entry.
# Fail closed: no team configured = refuse; host not in inventory = refuse.
ctp_classify() {
    local a1="${1:-}" a2="${2:-}" a3="${3:-}" a4="${4:-}" verb target
    case "$a1" in
        secrets)
            printf 'refuse credential-verb-refused-outright'; return 1 ;;
        make)
            printf 'refuse lifecycle-verb-refused-outright'; return 1 ;;
        project)
            if [[ "$a2" == "update-inventory" && -z "$a3" ]]; then
                printf 'confirm inventory update-inventory -'; return 0
            fi
            printf 'refuse project-verb-not-reachable:%s' "${a2:-<empty>}"; return 1 ;;
        host)
            verb="$a2"; target="$a3" ;;
        *)
            printf 'refuse unknown-verb:%s' "${a1:-<empty>}"; return 1 ;;
    esac

    case "$verb" in
        list)
            [[ -n "$target" ]] || { printf 'refuse list-needs-a-target-no-bulk-listing'; return 1; }
            [[ -z "$a4" ]] || { printf 'refuse unexpected-extra-args'; return 1; }
            [[ "$target" == "all" ]] && { printf 'refuse list-all-refused-no-bulk-dump'; return 1; }
            ctp_has_glob "$target" && { printf 'refuse glob-in-list-target-refused'; return 1; }
            printf 'confirm read list %s' "$target"; return 0 ;;
        vars)
            printf 'refuse vars-not-reachable-streams-box-detail'; return 1 ;;
        redeploy|remove)
            printf 'refuse destructive-verb-not-reachable:%s' "$verb"; return 1 ;;
        deploy|deploy-role)
            : ;;
        *)
            printf 'refuse unknown-host-verb:%s' "${verb:-<empty>}"; return 1 ;;
    esac

    # --- mutating verb: allow-list, glob, team gate ---
    local allowed=" $CTP_ALLOWED_VERBS "
    [[ "$allowed" == *" $verb "* ]] || { printf 'refuse verb-not-in-config-allow-list:%s' "$verb"; return 1; }
    [[ -n "$target" ]] || { printf 'refuse mutating-verb-needs-a-target:%s' "$verb"; return 1; }
    [[ -z "$a4" ]] || { printf 'refuse unexpected-extra-args'; return 1; }
    ctp_has_glob "$target" && { printf 'refuse glob-in-target-refused:%s' "$verb"; return 1; }
    # resolve effective team number (CTP_ALLOWED_TEAM is deprecated alias)
    local _eff_team_nr="$CTP_ALLOWED_TEAM_NR"
    if [[ -z "$_eff_team_nr" && -n "$CTP_ALLOWED_TEAM" ]]; then
        _eff_team_nr="$CTP_ALLOWED_TEAM"
    fi
    [[ -n "$_eff_team_nr" ]] || { printf 'refuse no-team-configured'; return 1; }
    # explicit target override: CTP_ALLOWED_TARGET bypasses inventory query
    if [[ -n "$CTP_ALLOWED_TARGET" ]]; then
        local _explicit_ok=false _b
        for _b in $CTP_ALLOWED_TARGET; do
            [[ "$target" == "$_b" ]] && { _explicit_ok=true; break; }
        done
        if [[ "$_explicit_ok" == true ]]; then
            printf 'confirm mutating %s %s' "$verb" "$target"; return 0
        fi
    fi
    # enclave gate: target suffix must be in CTP_ALLOWED_ENCLAVES (if set)
    if [[ -n "$CTP_ALLOWED_ENCLAVES" ]]; then
        local _suffix="${target##*-}"
        local _enclave_ok=false _e
        for _e in $CTP_ALLOWED_ENCLAVES; do
            [[ "$_suffix" == "$_e" ]] && { _enclave_ok=true; break; }
        done
        if [[ "$_enclave_ok" != true ]]; then
            printf 'refuse enclave-not-allowed:%s' "$_suffix"; return 1
        fi
    fi
    # live inventory query: target must belong to the configured team
    local _query_team_nr _query_rc
    _query_team_nr="$(ctp_query_team "$target")" && _query_rc=0 || _query_rc=$?
    if [[ "$_query_rc" -eq 1 ]]; then
        printf >&2 'ctp-guard: %s not in inventory (ansible-inventory exit 5)\n' "$target"
        printf 'refuse host-not-in-inventory:%s' "$target"; return 1
    elif [[ "$_query_rc" -ne 0 ]]; then
        printf >&2 'ctp-guard: inventory query failed for %s (rc=%d)\n' "$target" "$_query_rc"
        printf 'refuse inventory-query-failed:%s' "$target"; return 1
    fi
    local _team_match=false _t
    IFS=',' read -ra _team_list <<< "$_eff_team_nr"
    for _t in "${_team_list[@]}"; do
        [[ "$_query_team_nr" == "$_t" ]] && { _team_match=true; break; }
    done
    if [[ "$_team_match" != true ]]; then
        printf >&2 'ctp-guard: %s belongs to team %s, allowed: %s\n' "$target" "$_query_team_nr" "$_eff_team_nr"
        printf 'refuse host-belongs-to-team-%s-not-%s' "$_query_team_nr" "$_eff_team_nr"; return 1
    fi

    printf >&2 'ctp-guard: %s confirmed team %s (allowed: %s)\n' "$target" "$_query_team_nr" "$_eff_team_nr"
    printf 'confirm mutating %s %s' "$verb" "$target"; return 0
}

# --- liveness probe -----------------------------------------------------------
# ctp_probe_host_alive <target> — 0 if the target responds to a network probe
# (single ICMP ping inside the catapult container). Used by ctp-bridge.sh to
# warn before redeploying a host that is already live.
#
# Exit codes:
#   0 — host responded (reachable)
#   1 — host did not respond or probe failed (unreachable)
#
# Override CTP_PROBE_HOST_FN with a function name to replace this for testing.
ctp_probe_host_alive() {
    if [[ -n "${CTP_PROBE_HOST_FN:-}" ]] && declare -F "$CTP_PROBE_HOST_FN" >/dev/null 2>&1; then
        "$CTP_PROBE_HOST_FN" "$@"
        return $?
    fi

    local target="$1"
    local container remote_host
    container="$(ctp_container)"
    remote_host="${CTP_REMOTE_HOST:-}"

    local docker_cmd=(docker exec "$container" ping -c 1 -W 3 "$target")
    local rc

    if [[ -n "$remote_host" ]]; then
        ssh -o BatchMode=yes "$remote_host" "${docker_cmd[@]}" >/dev/null 2>&1 && rc=0 || rc=$?
    else
        "${docker_cmd[@]}" >/dev/null 2>&1 && rc=0 || rc=$?
    fi

    if [[ "$rc" -eq 0 ]]; then
        printf >&2 'ctp-guard: %s responded to probe (host is live)\n' "$target"
    else
        printf >&2 'ctp-guard: %s did not respond to probe\n' "$target"
    fi
    return "$rc"
}

# --- secret paths ------------------------------------------------------------
# ctp_expand_tilde <path> — leading ~ to the target user's home.
ctp_expand_tilde() {
    local p="$1" home="${CTP_TARGET_HOME:-$HOME}"
    # shellcheck disable=SC2088  # matching a LITERAL leading ~, not expanding it
    case "$p" in
        '~/'*) printf '%s/%s' "$home" "${p#\~/}" ;;
        '~')   printf '%s' "$home" ;;
        *)     printf '%s' "$p" ;;
    esac
}

# _ctp_path_in <path> <space-separated-globs> — 0 if <path> matches any glob in
# the list. Matches the raw and the basename form so `.env` matches `**/.env`,
# and `/var/tmp/vlt_pf` matches itself. Shared by the secret and PII matchers so
# both use one hardened rule.
_ctp_path_in() {
    local candidate="$1" list="$2" pat epat base
    candidate="$(ctp_expand_tilde "$candidate")"   # a literal ~ in the arg must match too
    base="${candidate##*/}"
    # Split the list on whitespace WITHOUT pathname expansion. Unquoted `$list`
    # globs its own patterns against the real filesystem first: `~/.ssh/**` would
    # collapse to the files that happen to exist right now, so a NEW file in a
    # guarded directory matched nothing and the guard failed open on exactly the
    # case that matters (a write, or a secret created after the shell started).
    local -a _pats=() _restore_glob=1
    [[ -o noglob ]] && _restore_glob=0
    set -f
    # shellcheck disable=SC2206  # deliberate word-splitting; globbing is off
    _pats=($list)
    [[ "$_restore_glob" == 1 ]] && set +f
    for pat in "${_pats[@]}"; do
        epat="$(ctp_expand_tilde "$pat")"
        # shellcheck disable=SC2053  # glob match is intentional (path patterns)
        [[ "$candidate" == $epat ]] && return 0
        # a **/ prefix means "anywhere": match on the basename too
        # shellcheck disable=SC2053
        case "$epat" in
            '**/'*) [[ "$base" == ${epat#\*\*/} ]] && return 0 ;;
        esac
    done
    return 1
}

# Secret path floor — always guarded, never overridable from config or env.
# Same design as CTP_PII_BUILTIN: a setup step you can forget is a control that
# fails open. .env holds API tokens and passwords; SSH keys are credentials;
# GPG keyrings are signing material. These are fixed, known paths — there is no
# reason to make protecting them opt-in.
# shellcheck disable=SC2088
CTP_SECRET_BUILTIN='**/.env ~/.ssh/id_* ~/.gnupg/**'

# ctp_is_secret_path <path> — 0 if the path matches the always-on built-in list
# OR a configured secret glob. Two lists, checked in order — the built-in one
# is NOT a default for the configured one (same reasoning as CTP_PII_BUILTIN).
ctp_is_secret_path() {
    _ctp_path_in "$1" "$CTP_SECRET_BUILTIN" && return 0
    _ctp_path_in "$1" "$CTP_SECRET_PATHS"
}

# The orchestrator's private config directory, guarded ALWAYS — not opt-in, and
# not overridable from config or the caller's environment (assigned outright, not
# defaulted, so an inherited value cannot weaken it).
#
# It holds the classifier prompt, the sanitiser prompt and the term list: files
# that accumulate the very Org codenames and patterns they exist to catch. The
# term list in particular is a distilled index of everything being protected.
#
# These paths are fixed and known, unlike the owner's own data paths, so there is
# no reason to make protecting them a step someone has to remember. A setup step
# you can forget is a control that fails open — and it would fail open silently,
# on the most sensitive file on the box.
#
# Deliberately the whole directory, so a private file added later (eval fixtures,
# a future prompt) is covered without another change here.
#
# This blocks Claude's TOOLS. The orchestrator reads these files directly rather
# than through a tool call, so every component keeps working.
# The ~ is expanded by ctp_expand_tilde inside _ctp_path_in, exactly as it is for
# owner-supplied globs from the config file — not by the shell here.
# shellcheck disable=SC2088
CTP_PII_BUILTIN='~/.config/orchestrator/*'

# ctp_is_pii_path <path> — 0 if the path matches the always-on built-in list OR a
# configured Org PII/IP glob.
#
# Two lists, checked in order, and the built-in one is NOT a default value for the
# configured one: CTP_PII_PATHS is assigned by the config parser, so a default
# would be REPLACED the moment an owner set their own paths — silently removing
# protection at the exact moment they started using the feature.
#
# Separate list, separate reason from secrets: a data-governance boundary the
# owner tunes independently (and that a future local-model front-door may treat
# differently). Empty CTP_PII_PATHS still matches nothing — the owner's half stays
# opt-in; the built-in half is not.
ctp_is_pii_path() {
    _ctp_path_in "$1" "$CTP_PII_BUILTIN" && return 0
    _ctp_path_in "$1" "$CTP_PII_PATHS"
}
