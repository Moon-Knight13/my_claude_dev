#!/usr/bin/env bash
# docker-housekeeping.sh — lightweight Docker cleanup before devcontainer start.
#
# Runs on the HOST via devcontainer.json initializeCommand. Prunes stopped
# containers, dangling images/volumes, and build cache beyond a retention
# threshold. Keeps enough cache for fast rebuilds.
#
# Safe by design: only removes resources Docker marks as unused/reclaimable.
# Never removes running containers, in-use volumes, or tagged images.
set -uo pipefail

BUILD_CACHE_KEEP="${DOCKER_CACHE_KEEP:-10GB}"

reclaimed=0

# Stopped containers (devcontainer rebuilds leave these behind).
out=$(docker container prune -f 2>/dev/null | grep -oP '[0-9.]+[KMGT]?B' | tail -1)
[[ -n "$out" && "$out" != "0B" ]] && { echo "  Containers: $out reclaimed"; reclaimed=1; }

# Dangling images (untagged layers from previous builds).
out=$(docker image prune -f 2>/dev/null | grep -oP '[0-9.]+[KMGT]?B' | tail -1)
[[ -n "$out" && "$out" != "0B" ]] && { echo "  Images: $out reclaimed"; reclaimed=1; }

# Anonymous volumes only (hex-named, truly orphaned).
# Named volumes (claude-code-bashhistory-*, ghconfig-*, vscode) are preserved
# even when no container is running — the devcontainer remounts them.
anon=$(docker volume ls -qf dangling=true 2>/dev/null | grep -E '^[0-9a-f]{64}$' || true)
if [[ -n "$anon" ]]; then
    count=$(echo "$anon" | wc -l)
    echo "$anon" | xargs docker volume rm 2>/dev/null || true
    echo "  Volumes: $count anonymous removed"; reclaimed=1
fi

# Build cache beyond retention threshold.
out=$(docker builder prune -f --reserved-space="$BUILD_CACHE_KEEP" 2>/dev/null | grep -oP '[0-9.]+[KMGT]?B' | tail -1)
[[ -n "$out" && "$out" != "0B" ]] && { echo "  Build cache: $out reclaimed (keeping $BUILD_CACHE_KEEP)"; reclaimed=1; }

(( reclaimed )) && echo "docker-housekeeping: done." || echo "docker-housekeeping: nothing to clean."
