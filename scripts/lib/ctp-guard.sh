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
CTP_ALLOWED_TEAM=""
CTP_ALLOWED_VERBS="deploy deploy-role"
CTP_CONTAINER=""
CTP_PROJECT_DIR=""
CTP_SECRET_PATHS=""

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
        case "$key" in
            CTP_ALLOWED_TARGET) CTP_ALLOWED_TARGET="$val" ;;
            CTP_ALLOWED_TEAM)   CTP_ALLOWED_TEAM="${val//[[:space:]]/}" ;;
            CTP_ALLOWED_VERBS)  CTP_ALLOWED_VERBS="$val" ;;
            CTP_CONTAINER)      CTP_CONTAINER="$val" ;;
            CTP_PROJECT_DIR)    CTP_PROJECT_DIR="$val" ;;
            CTP_SECRET_PATHS)   CTP_SECRET_PATHS="$val" ;;
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
# Two independent gates protect a mutating verb, and BOTH must pass:
#   - team gate: the target must belong to the authorised team (CTP_ALLOWED_TEAM),
#     i.e. end with _<team>. This is the protection against deploying to a live
#     team by mistake; it holds even if the box allow-list is later widened.
#   - box allow-list: the target must equal CTP_ALLOWED_TARGET (one named box).
# Both fail closed: an unset team or target refuses every mutating verb.
ctp_classify() {
    local a1="${1:-}" a2="${2:-}" a3="${3:-}" a4="${4:-}" verb target
    case "$a1" in
        secrets)
            printf 'refuse credential-verb-refused-outright'; return 1 ;;
        make)
            # make start/restart/stop are host-shell lifecycle + credential entry,
            # not ctp verbs; never run through the bridge.
            printf 'refuse lifecycle-verb-refused-outright'; return 1 ;;
        project)
            # update-inventory is the required step after making a Providentia box
            # (nothing else has a target; refuse any other project subverb).
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
            # read-only verification. A concrete target only — no bulk dump of the
            # whole range into the transcript.
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

    # --- mutating verb: allow-list, glob, team gate, box gate ---
    local allowed=" $CTP_ALLOWED_VERBS "
    [[ "$allowed" == *" $verb "* ]] || { printf 'refuse verb-not-in-config-allow-list:%s' "$verb"; return 1; }
    [[ -n "$target" ]] || { printf 'refuse mutating-verb-needs-a-target:%s' "$verb"; return 1; }
    [[ -z "$a4" ]] || { printf 'refuse unexpected-extra-args'; return 1; }
    ctp_has_glob "$target" && { printf 'refuse glob-in-target-refused:%s' "$verb"; return 1; }
    # team gate (mandatory, fail closed)
    [[ -n "$CTP_ALLOWED_TEAM" ]] || { printf 'refuse no-authorised-team-configured'; return 1; }
    [[ "$target" == *"_$CTP_ALLOWED_TEAM" ]] || { printf 'refuse target-not-in-authorised-team:%s' "$CTP_ALLOWED_TEAM"; return 1; }
    # box allow-list (one named box, fail closed)
    [[ -n "$CTP_ALLOWED_TARGET" ]] || { printf 'refuse no-allowed-target-configured'; return 1; }
    [[ "$target" == "$CTP_ALLOWED_TARGET" ]] || { printf 'refuse target-not-allowed'; return 1; }

    printf 'confirm mutating %s %s' "$verb" "$target"; return 0
}

# --- secret paths ------------------------------------------------------------
# ctp_expand_tilde <path> — leading ~ to the target user's home.
ctp_expand_tilde() {
    local p="$1" home="${CTP_TARGET_HOME:-$HOME}"
    case "$p" in
        '~/'*) printf '%s/%s' "$home" "${p#\~/}" ;;
        '~')   printf '%s' "$home" ;;
        *)     printf '%s' "$p" ;;
    esac
}

# ctp_is_secret_path <path> — 0 if the path matches a configured secret glob, so
# its contents must never be read into a transcript. Matches the raw and the
# basename form so `.env` matches `**/.env`, and `/var/tmp/vlt_pf` matches itself.
ctp_is_secret_path() {
    local candidate pat epat base
    candidate="$(ctp_expand_tilde "$1")"   # a literal ~ in the arg must match too
    base="${candidate##*/}"
    for pat in $CTP_SECRET_PATHS; do
        epat="$(ctp_expand_tilde "$pat")"
        # shellcheck disable=SC2053
        [[ "$candidate" == $epat ]] && return 0
        # a **/ prefix means "anywhere": match on the basename too
        case "$epat" in
            '**/'*) [[ "$base" == ${epat#\*\*/} ]] && return 0 ;;
        esac
    done
    return 1
}
