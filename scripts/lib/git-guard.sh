#!/usr/bin/env bash
# git-guard.sh — classify a shell command segment for DESTRUCTIVE git operations.
#
# Control 2b of the safety harness. Owner decision: A (safety-guard) gates generic
# filesystem/infra/db commands and deliberately NOT git; ALL git/commit actions
# are B's domain. The commit guard (B) covers commit CONTENT via a pre-commit
# hook, but destructive git ops (force-push, reset --hard, clean -fdx, branch -D)
# are not commits and fire no git hook — so they are gated here, at the same
# PreToolUse choke point as A, on the segmented command WORD (never a raw string,
# so a commit message that says "reset --hard" is not flagged).
#
# Verdict is `ask` — the human confirms in Claude Code; with no human the harness
# resolves `ask` to a deny (fail closed). These ops are recoverable far less often
# than people assume (force-push rewrites published history; reset --hard and
# clean delete uncommitted/untracked work), so confirm-before-run is proportionate.
# Honest limit: an adversarial model can obfuscate — defense-in-depth, not a
# sandbox (same accepted-risk basis as A).
#
# API:
#   gitguard_load_config <file>   parse GITGUARD_ALLOWLIST from a KEY=VALUE file
#                                 (parsed, never sourced, never from caller env)
#   gitguard_classify <segment>   prints "" (allow) | "ask:<reason>"
#
# Allow-list op names: force-push reset-hard clean branch-delete checkout-force

_GITGUARD_ALLOWLIST=""

gitguard_load_config() { # gitguard_load_config <file>
    local f="${1:-}"
    [[ -n "$f" && -f "$f" ]] || return 0
    local line k v
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        [[ "$line" == *=* ]] || continue
        k="${line%%=*}"; v="${line#*=}"
        k="${k//[[:space:]]/}"
        v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
        v="${v#[\"\']}"; v="${v%[\"\']}"
        case "$k" in
            GITGUARD_ALLOWLIST) _GITGUARD_ALLOWLIST="$v" ;;
        esac
    done < "$f"
    return 0
}

# _gitguard_allowed <op> — true if the operator exempted this op (per-op). Empty
# allow-list (the default) exempts nothing.
_gitguard_allowed() {
    local op="$1" a
    for a in $_GITGUARD_ALLOWLIST; do [[ "$a" == "$op" ]] && return 0; done
    return 1
}

gitguard_classify() { # gitguard_classify <segment> ; prints ""|"ask:.."
    local seg="$1"
    local cw; cw="$(_seg_cmdword "$seg")" || return 0
    cw="${cw##*/}"                                   # /usr/bin/git -> git
    [[ "$cw" == git ]] || return 0

    # tokenise; drop env-assignment prefixes and the 'git' word -> args
    local -a toks args=(); read -r -a toks <<<"$seg"
    local seen_cmd=0 t
    for t in "${toks[@]}"; do
        if [[ "$seen_cmd" == 0 ]]; then
            [[ "$t" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] && continue   # env prefix (value may hold /)
            seen_cmd=1; continue                                  # the 'git' word
        fi
        args+=("$t")
    done

    # the git subcommand is the first arg that is not a global flag/option value
    local sub="" a skip=0
    for a in "${args[@]-}"; do
        if [[ "$skip" == 1 ]]; then skip=0; continue; fi
        case "$a" in
            -C|-c|--git-dir|--work-tree|--namespace) skip=1; continue ;;  # take a value
            -*) continue ;;                                               # other global flag
            *) sub="$a"; break ;;
        esac
    done
    [[ -n "$sub" ]] || return 0
    local argline=" ${args[*]-} "

    local op="" reason=""
    case "$sub" in
        push)
            if [[ "$argline" == *" --force "* || "$argline" == *" --force-with-lease"* \
                  || "$argline" =~ [[:space:]]-[a-zA-Z]*f[a-zA-Z]*([[:space:]]|$) ]]; then
                op="force-push"; reason="git push --force — rewrites published history on the remote"
            fi ;;
        reset)
            [[ "$argline" == *" --hard"* ]] && { op="reset-hard"; reason="git reset --hard — discards uncommitted changes in the working tree"; } ;;
        clean)
            # clean does nothing without -f/--force; gate when force is present.
            if [[ "$argline" == *" --force"* || "$argline" =~ [[:space:]]-[a-zA-Z]*f[a-zA-Z]*([[:space:]]|$) ]]; then
                op="clean"; reason="git clean -f — permanently deletes untracked files"
            fi ;;
        branch)
            # -D (force delete), or a combined short flag containing D, or --delete --force
            if [[ "$argline" =~ [[:space:]]-[a-zA-Z]*D[a-zA-Z]*([[:space:]]|$) \
                  || ( "$argline" == *" --delete"* && "$argline" == *" --force"* ) ]]; then
                op="branch-delete"; reason="git branch -D — force-deletes a branch (may drop unmerged commits)"
            fi ;;
        checkout|switch)
            if [[ "$argline" == *" --force"* || "$argline" =~ [[:space:]]-[a-zA-Z]*f[a-zA-Z]*([[:space:]]|$) ]]; then
                op="checkout-force"; reason="git $sub --force — discards local changes in the working tree"
            fi ;;
    esac

    [[ -n "$op" ]] || return 0
    _gitguard_allowed "$op" && return 0
    printf 'ask:%s' "$reason"
    return 0
}
