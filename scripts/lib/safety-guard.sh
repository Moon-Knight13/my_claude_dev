#!/usr/bin/env bash
# safety-guard.sh — classify a shell command segment for DESTRUCTIVE actions.
#
# The first control of the safety harness. Sourced by the PreToolUse hook (and, in
# future, by a local-model orchestrator) — the SINGLE model-agnostic choke point,
# so the same policy applies whoever is driving. It classifies the segmented
# command WORD + args produced by cmd-segment.sh, never a raw string match, so
# "drop the users table" inside a commit message or heredoc body is not flagged.
#
# Scope: generic filesystem / infra / database commands. NOT git or commit actions
# (those are the commit guard's domain), and NOT ctp (already gated by the ctp
# path). Verdict default is `ask` — the human confirms in Claude Code; with no
# human the harness resolves `ask` to a deny (fail closed). `deny`-hard is a small
# reserved set. Honest limit: an adversarial model can still obfuscate — this
# stops the accidental and the misread-instruction cases, it is not a sandbox.
#
# API:
#   safety_load_config <file>   parse SAFETY_ALLOWLIST from a KEY=VALUE file (never
#                               sourced, never from caller env)
#   safety_classify <segment>   prints "" (allow) | "ask:<reason>" | "deny:<reason>"

_SAFETY_ALLOWLIST=""

safety_load_config() { # safety_load_config <file>
    local f="${1:-}"
    [[ -n "$f" && -f "$f" ]] || return 0
    # Parse, do not source: the file is operator-authored. Honour only known keys.
    local line k v
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"                       # strip comments
        [[ "$line" == *=* ]] || continue
        k="${line%%=*}"; v="${line#*=}"
        k="${k//[[:space:]]/}"
        v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
        v="${v#[\"\']}"; v="${v%[\"\']}"
        case "$k" in
            SAFETY_ALLOWLIST) _SAFETY_ALLOWLIST="$v" ;;
        esac
    done < "$f"
    return 0
}

# _safety_allowed <verb> — true if the operator has exempted this verb (per-verb,
# owner decision). Empty allow-list (the supported default) exempts nothing.
_safety_allowed() {
    local v="$1" a
    for a in $_SAFETY_ALLOWLIST; do [[ "$a" == "$v" ]] && return 0; done
    return 1
}

safety_classify() { # safety_classify <segment> ; prints ""|"ask:.."|"deny:.."
    local seg="$1"
    local cw; cw="$(_seg_cmdword "$seg")" || return 0
    cw="${cw##*/}"                                # basename: /bin/rm -> rm
    [[ -n "$cw" ]] || return 0

    # tokenise; drop env-assignment prefixes and the command word itself -> args
    local -a toks args=(); read -r -a toks <<<"$seg"
    local seen_cmd=0 t
    for t in "${toks[@]}"; do
        if [[ "$seen_cmd" == 0 ]]; then
            [[ "$t" == *=* && "$t" != */* ]] && continue   # env prefix
            seen_cmd=1; continue                            # this is the cmd word
        fi
        args+=("$t")
    done
    local argline=" ${args[*]-} "

    _safety_allowed "$cw" && return 0

    local ask=""   # set to a reason to gate

    case "$cw" in
        rm)
            # recursive AND force (combined -rf/-fr/-Rf, or separate flags)
            if [[ "$argline" =~ [[:space:]]-[a-zA-Z]*[rR][a-zA-Z]*f || "$argline" =~ [[:space:]]-[a-zA-Z]*f[a-zA-Z]*[rR] ]] \
               || { [[ "$argline" == *" -r"* || "$argline" == *" -R"* || "$argline" == *" --recursive"* ]] \
                    && [[ "$argline" == *" -f"* || "$argline" == *" --force"* ]]; }; then
                ask="recursive force delete (rm) — irreversible removal of a directory tree"
            fi ;;
        shred)  ask="secure erase (shred) — irreversibly destroys file contents" ;;
        wipefs) ask="wipefs — erases filesystem signatures from a device" ;;
        mkfs|mkfs.*) ask="format filesystem (mkfs) — destroys existing data on the target" ;;
        dd)
            [[ "$argline" =~ [[:space:]]of= ]] && ask="dd writes directly to a device/file — can overwrite a disk" ;;
        dropdb) ask="dropdb — drops an entire database" ;;
        psql|mysql|mysqladmin|mariadb|mongo|mongosh)
            if printf '%s' "$argline" | grep -qiE '\b(DROP|TRUNCATE)\b'; then
                ask="destructive SQL (DROP/TRUNCATE) via $cw"
            fi ;;
        terraform|tofu)
            [[ "$argline" == *" destroy"* ]] && ask="$cw destroy — tears down managed infrastructure" ;;
        kubectl|oc)
            [[ "$argline" == *" delete"* ]] && ask="$cw delete — removes cluster resources" ;;
        helm)
            [[ "$argline" == *" uninstall"* || "$argline" == *" delete"* ]] && ask="helm uninstall/delete — removes a release" ;;
        docker|podman)
            if [[ "$argline" == *" system "*prune* || "$argline" =~ [[:space:]](image|volume|container|network)[[:space:]]+prune ]]; then
                ask="$cw prune — bulk-removes unused resources"
            elif [[ "$argline" =~ [[:space:]](rm|rmi)[[:space:]] && ( "$argline" == *" -f"* || "$argline" == *" --force"* ) ]]; then
                ask="$cw force-remove (rm/rmi -f)"
            elif [[ "$argline" =~ [[:space:]]volume[[:space:]]+rm ]]; then
                ask="$cw volume rm — deletes a data volume"
            fi ;;
    esac

    [[ -n "$ask" ]] && printf 'ask:%s' "$ask"
    return 0
}
