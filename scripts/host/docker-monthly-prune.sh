#!/usr/bin/env bash
# Monthly Docker cleanup — remove stale build cache, exited containers,
# and dangling images. Safe by design: never touches running containers,
# named volumes, or images in active use.
#
# Install as a systemd user timer:
#   cp scripts/host/docker-monthly-prune.{service,timer} ~/.config/systemd/user/
#   systemctl --user daemon-reload
#   systemctl --user enable --now docker-monthly-prune.timer
#
# Or run manually:  bash scripts/host/docker-monthly-prune.sh

set -euo pipefail

log() { printf '[%s] %s\n' "$(date -Iseconds)" "$*"; }

log "Docker monthly prune starting"

# 1. Remove exited containers older than 24h (catches vsc-* churn)
docker container prune --force --filter "until=24h"

# 2. Remove dangling images (untagged layers left by rebuilds)
docker image prune --force

# 3. Remove unused images not referenced by any container, older than 7 days
#    This catches stale vsc-* tagged images that `image prune` skips.
docker image prune --all --force --filter "until=168h"

# 4. Reclaim build cache older than 7 days
docker builder prune --force --filter "until=168h"

# 5. Remove unused networks (not default bridge/host/none)
docker network prune --force --filter "until=24h"

log "Docker monthly prune complete"
docker system df
