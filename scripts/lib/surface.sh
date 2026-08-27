#!/usr/bin/env bash
# surface.sh — say which of this repository's two surfaces we are running on.
#
# `docs/PROJECT.md` § "What this repository is" describes them: the devcontainer
# this repo is developed in, and a remote developer box the provisioning scripts
# bring to a known-good state. The distinction is not cosmetic — it has already
# hidden one failure. `devcontainer.json` sets LOCAL_MODEL_ENDPOINT through
# `containerEnv`, so local routing worked in the container and looked configured
# while being dead on every box. Any check whose correct answer differs between
# the two surfaces has to ask which one it is on, rather than assuming.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/surface.sh"
#   [[ "$(current_surface)" == "box" ]] && …
#
# Override with CLAUDE_SURFACE=devcontainer|box when testing the other path.

current_surface() {
    if [[ -n "${CLAUDE_SURFACE:-}" ]]; then
        printf '%s' "$CLAUDE_SURFACE"
        return 0
    fi
    # A devcontainer is a container, and these markers are set by the tooling
    # that builds one. A dev box is a plain host: none of them are present.
    if [[ -f /.dockerenv ]] \
        || [[ -n "${REMOTE_CONTAINERS:-}" ]] \
        || [[ -n "${CODESPACES:-}" ]] \
        || [[ -n "${DEVCONTAINER:-}" ]]; then
        printf 'devcontainer'
    else
        printf 'box'
    fi
}
