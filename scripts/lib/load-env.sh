#!/usr/bin/env bash
# load-env.sh — make .env actually reach the routing scripts.
#
# .env.example advertises LOCAL_MODEL_ENABLED, LOCAL_MODEL_ENDPOINT and friends,
# and setup-day0.sh copies it to .env — but nothing ever loaded that file. Every
# consumer read the values straight from the environment, where they were never
# set, so route-model.sh fell through to its `LOCAL_MODEL_ENABLED:-false`
# default and reported `local_disabled` no matter what .env said. Local routing
# was off in every derived repo while day-0 reported it configured.
#
# Usage (from a script in scripts/):
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/load-env.sh"
#
# Precedence, two separate rules:
#
#   Environment over file. A variable already set — including set to empty — is
#   left untouched, so `FORCE_CLAUDE=true scripts/route-model.sh ...` and CI
#   environments keep overriding .env rather than being silently overwritten.
#
#   Within the file, the LAST assignment wins. Appending a corrected value is how
#   people actually edit a .env, and first-wins made that a no-op: .env.example
#   ships LOCAL_MODEL_ENDPOINT pointing at a devcontainer, a host user appended
#   the right value, and the appended line was silently ignored. The classifier
#   then could not reach a model, failed closed, and called every prompt
#   sensitive — safe, and quietly useless, with nothing anywhere saying why.
#   Last-wins matches a shell and every other dotenv loader. It applies to the
#   file only; it never lets the file overrule the caller.
#
# The file is parsed, not sourced. .env is developer-authored and gitignored, so
# sourcing it would execute whatever it contains on every routing decision;
# parsing keeps a config file a config file. Only KEY=VALUE lines are honoured.

# Guard against repeated work when one entry point calls another.
[[ -n "${_CLAUDE_ENV_LOADED:-}" ]] && return 0
_CLAUDE_ENV_LOADED=1

_load_env_file() {
    local file="$1"
    [[ -f "$file" ]] || return 0

    # Keys THIS file has already assigned. The "already set, leave it alone"
    # check below must apply to the caller's environment, not to a value this
    # same file set a few lines earlier — otherwise the first assignment wins and
    # every later one is discarded.
    local -A _from_file=()
    local line key val
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"                              # tolerate CRLF
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        line="${line#"${line%%[![:space:]]*}"}"           # strip leading space
        [[ "$line" == export\ * ]] && line="${line#export }"
        [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue

        key="${BASH_REMATCH[1]}"
        val="${BASH_REMATCH[2]}"

        # Environment wins: never clobber a variable the caller already set.
        # A key this file set earlier is not the caller's, so it may be replaced.
        [[ -n "${!key+x}" && -z "${_from_file[$key]:-}" ]] && continue
        _from_file["$key"]=1

        case "$val" in
            \"*\") val="${val%\"}"; val="${val#\"}" ;;    # "quoted value"
            \'*\') val="${val%\'}"; val="${val#\'}" ;;    # 'quoted value'
            *)
                # Unquoted: a trailing `  # comment` is a comment, as in
                # .env.example's `LOCAL_MODEL_TIMEOUT=120  # hard cap (s)`.
                val="${val%%[[:space:]]#*}"
                val="${val%"${val##*[![:space:]]}"}"      # strip trailing space
                ;;
        esac

        export "$key=$val"
    done < "$file"
}

# Repo root is two levels up from scripts/lib/.
_load_env_file "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/.env"
unset -f _load_env_file
