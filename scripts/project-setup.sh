#!/usr/bin/env bash
# Project-specific container setup — the project's extension point.
#
# The last entry in devcontainer.json's postStartCommand, so start-time setup
# has one home instead of growing devcontainer.json. Ships as a no-op: replace
# the body below with whatever the project needs at container start (extra
# runtime deps, symlinks, fetching a fixture, …).
#
# Two constraints worth respecting:
#
#   - Exit 0 unless the failure genuinely warrants a broken container. This
#     runs last in a `&&` chain, so a non-zero exit marks the whole
#     postStartCommand failed.
#   - Network egress is deny-by-default (see .devcontainer/init-firewall.sh).
#     registry.npmjs.org, pypi.org and files.pythonhosted.org are reachable;
#     anything else needs adding to the allowlist there first.

set -euo pipefail

echo "project-setup.sh: nothing to do (template default)."
echo "  Derivatives override this — see the comments in this file."
