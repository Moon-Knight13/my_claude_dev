#!/usr/bin/env bash
# Results are globals read by callers (lane2 install, health).
# shellcheck disable=SC2034
# lane2-image.sh — the Lane 2 image and container definition (SP1a story 3.1;
# AD-9, AD-12, AD-18, AD-21, AD-23, FR-16, FR-31, FR-48, FR-52).
#
# API (sourced lib; prefix lane2_):
#   lane2_claude_version_ok <version> <channel>  rc 0 for an exact X.Y.Z >= the
#                                                floor from the "latest" channel
#   lane2_container_lint <definition.json>       one problem per line; none = ok
#   lane2_image_build <tree> <workdir>           build hub-side from the tree; sets
#                                                LANE2_IMAGE_ID, LANE2_CLAUDE_VERSION,
#                                                LANE2_CLAUDE_SHA256,
#                                                LANE2_INTEGRATION_DIGEST; rc 4 on any
#                                                failure (nothing recorded)
#   lane2_image_check <image id>                 rc 0 when that image exists
#   lane2_claude_digest_check <image id> <sha>   rc 0 when the in-image binary matches
#   lane2_claude_version_in <image id>           prints the image's claude version
#   lane2_userns_verify                          rc 0 only for rootful Docker with
#                                                userns-remap to a dedicated range;
#                                                else 4 with LANE2_USERNS_REASON
#
# Test seams: LANE2_DOCKER_DAEMON_JSON, LANE2_SUBUID_FILE, and
# lane2_userns_probe_uid can be replaced by a test that sources this lib.

LANE2_CLAUDE_FLOOR="2.1.299"
LANE2_DOCKER_DAEMON_JSON=/etc/docker/daemon.json
LANE2_SUBUID_FILE=/etc/subuid
# Runtime control sockets: never a mount source (FR-48).
LANE2_RUNTIME_SOCKETS='docker\.sock|containerd\.sock|podman\.sock|/run/containerd|/run/podman|/var/run/docker|/run/docker|crio\.sock'
# The AD-21 mount list: kind and the only mode it may have.
declare -A LANE2_MOUNT_KINDS=(
    [workspace]=rw [host-executed]=ro [integration-policy]=ro
    [agent-settings]=ro [session-sockets]=ro [claude-config]=rw
)

_lane2_ver_ge() { # _lane2_ver_ge <a> <b> — a >= b for X.Y.Z
    local IFS=. a b i
    read -ra a <<<"$1"; read -ra b <<<"$2"
    for i in 0 1 2; do
        (( 10#${a[i]} > 10#${b[i]} )) && return 0
        (( 10#${a[i]} < 10#${b[i]} )) && return 1
    done
    return 0
}

# Exact, from "latest", at or above the floor. "latest" itself, ranges, tags,
# and the "stable" channel (below the floor) are refused.
lane2_claude_version_ok() {
    local v="$1" ch="$2"
    [[ "$ch" == latest ]] || return 4
    [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 4
    _lane2_ver_ge "$v" "$LANE2_CLAUDE_FLOOR" || return 4
}

lane2_container_lint() {
    local f="$1" k m
    jq -e 'type == "object"' "$f" >/dev/null 2>&1 || { echo "definition is not a JSON object"; return 0; }
    jq -e '.read_only == true' "$f" >/dev/null || echo "root filesystem is not read-only"
    jq -e '(.tmpfs | type) == "array" and (.tmpfs | length) > 0' "$f" >/dev/null || echo "no tmpfs scratch"
    jq -e '.cap_drop == ["ALL"] and ((.cap_add // []) == [])' "$f" >/dev/null || echo "capabilities not dropped (cap_drop ALL, no cap_add)"
    jq -e '(.security_opt // []) | index("no-new-privileges") != null' "$f" >/dev/null || echo "no-new-privileges missing"
    jq -e '(.user | type) == "string" and .user != "" and .user != "root" and .user != "0" and (.user | startswith("0:") | not)' "$f" >/dev/null \
        || echo "default user is root or missing"
    jq -e '.privileged == false' "$f" >/dev/null || echo "privileged"
    jq -e '(.devices // []) == []' "$f" >/dev/null || echo "devices present"
    jq -e '.pid != "host"' "$f" >/dev/null || echo "pid host"
    jq -e '.network == "none"' "$f" >/dev/null || echo "network is not none (no host network, no bridge: AD-9)"
    jq -e '.userns != "host"' "$f" >/dev/null || echo "userns host"
    jq -e '(.add_host // []) == []' "$f" >/dev/null || echo "add_host present (no host-gateway alias)"
    jq -e '((.env // {}) | keys | map(select(startswith("LOCAL_MODEL_"))) | length) == 0' "$f" >/dev/null \
        || echo "LOCAL_MODEL_* variable present"
    jq -r '[.. | strings] | .[]' "$f" | grep -qE "$LANE2_RUNTIME_SOCKETS" && echo "references a container-runtime control socket"
    jq -e '[.mounts[]? | has("source")] | any | not' "$f" >/dev/null \
        || echo "a mount has a fixed host source (sources are resolved per session from the AD-21 list)"
    while IFS=$'\t' read -r k m; do
        [[ -n "${LANE2_MOUNT_KINDS[$k]:-}" ]] || { echo "mount kind not in the AD-21 list: $k"; continue; }
        [[ "$m" == "${LANE2_MOUNT_KINDS[$k]}" ]] || echo "mount $k must be ${LANE2_MOUNT_KINDS[$k]}"
    done < <(jq -r '.mounts[]? | "\(.kind)\t\(.mode)"' "$f")
    return 0
}

# Build from the tree only: a fresh context holds the tree's container/ files
# and the managed settings rendered from the tree's integration seed.
lane2_image_build() {
    local tree="$1" work="$2" pins base digest ver ch ctx
    LANE2_IMAGE_ID=""; LANE2_CLAUDE_VERSION=""; LANE2_CLAUDE_SHA256=""; LANE2_INTEGRATION_DIGEST=""
    pins="$tree/scripts/hub/pin-manifest.json"
    [[ -r "$pins" ]] || { echo " FAIL image: no pin manifest in the installed tree"; return 4; }
    base="$(jq -r '.container.base_image // ""' "$pins")"
    digest="$(jq -r '.container.base_digest // ""' "$pins")"
    ver="$(jq -r '.container.claude_code.version // ""' "$pins")"
    ch="$(jq -r '.container.claude_code.channel // ""' "$pins")"
    [[ "$base" =~ ^[a-z0-9._/-]+:[A-Za-z0-9._-]+$ ]] || { echo " FAIL image: base_image is not name:tag"; return 4; }
    [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] \
        || { echo " FAIL image: base_digest not pinned in scripts/hub/pin-manifest.json (see docs/SP1A_WORKSPACE_SEPARATION.md)"; return 4; }
    lane2_claude_version_ok "$ver" "$ch" \
        || { echo " FAIL image: Claude Code pin must be an exact version >= $LANE2_CLAUDE_FLOOR from the latest channel"; return 4; }
    local probs; probs="$(lane2_container_lint "$tree/scripts/hub/container/lane2-container.json")"
    [[ -z "$probs" ]] || { while IFS= read -r p; do echo " FAIL container definition: $p"; done <<<"$probs"; return 4; }
    command -v docker >/dev/null 2>&1 || { echo " FAIL image: docker not installed"; return 4; }

    ctx="$work/build"; rm -rf -- "$ctx"; mkdir -m 700 "$ctx" || return 4
    cp -- "$tree/scripts/hub/container/Dockerfile" "$ctx/Dockerfile" || return 4
    jq -S . "$tree/scripts/hub/integration/managed-settings.base.json" > "$ctx/managed-settings.json" 2>/dev/null \
        || { echo " FAIL image: managed settings seed missing or not JSON"; return 4; }
    LANE2_INTEGRATION_DIGEST="$(sha256sum < "$ctx/managed-settings.json" | cut -d' ' -f1)"
    docker build -q --pull --no-cache --network default \
        --build-arg "BASE_IMAGE=$base@$digest" --build-arg "CLAUDE_CODE_VERSION=$ver" \
        --iidfile "$work/iid" "$ctx" >/dev/null 2>"$work/build.err" \
        || { echo " FAIL image: build failed (docker build; see $work/build.err)"; return 4; }
    LANE2_IMAGE_ID="$(cat "$work/iid" 2>/dev/null)"
    [[ "$LANE2_IMAGE_ID" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo " FAIL image: no image id"; LANE2_IMAGE_ID=""; return 4; }
    LANE2_CLAUDE_VERSION="$(lane2_claude_version_in "$LANE2_IMAGE_ID")"
    [[ "$LANE2_CLAUDE_VERSION" == "$ver" ]] \
        || { echo " FAIL image: claude --version in the image is not the pinned $ver"; LANE2_IMAGE_ID=""; return 4; }
    LANE2_CLAUDE_SHA256="$(_lane2_claude_sha "$LANE2_IMAGE_ID")"
    [[ "$LANE2_CLAUDE_SHA256" =~ ^[0-9a-f]{64}$ ]] || { echo " FAIL image: cannot hash the claude binary"; LANE2_IMAGE_ID=""; return 4; }
    rm -rf -- "$ctx"
    echo "  OK  image built: $LANE2_IMAGE_ID (claude $ver)"
}

_lane2_in_image() { # _lane2_in_image <image> <sh -c script>
    docker run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges \
        --entrypoint /bin/sh "$1" -c "$2" 2>/dev/null
}

_lane2_claude_sha() {
    # Runs inside the image; expands there.
    # shellcheck disable=SC2016
    _lane2_in_image "$1" 'sha256sum "$(readlink -f "$(command -v claude)")"' | cut -d' ' -f1
}

lane2_claude_version_in() {
    _lane2_in_image "$1" 'claude --version' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

lane2_image_check() {
    [[ "$1" =~ ^sha256:[0-9a-f]{64}$ ]] || return 4
    [[ "$(docker image inspect --format '{{.Id}}' "$1" 2>/dev/null)" == "$1" ]] || return 4
}

lane2_claude_digest_check() {
    local have; have="$(_lane2_claude_sha "$1")"
    [[ -n "$have" && "$have" == "$2" ]] || return 4
}

# --- userns-remap (AD-21) -----------------------------------------------------

# The host uid that container uid 0 runs as: start a probe, read its host pid's uid.
lane2_userns_probe_uid() {
    local img="$1" cid pid uid
    cid="$(docker run -d --rm --network none --entrypoint /bin/sh "$img" -c 'sleep 30' 2>/dev/null)" || return 4
    pid="$(docker inspect --format '{{.State.Pid}}' "$cid" 2>/dev/null)"
    uid="$(awk '/^Uid:/ { print $2 }' "/proc/$pid/status" 2>/dev/null)"
    docker rm -f "$cid" >/dev/null 2>&1
    [[ "$uid" =~ ^[0-9]+$ ]] || return 4
    printf '%s' "$uid"
}

# lane2_userns_verify <probe image> <uid> [<uid> ...] — the uids that must stay
# outside the remap range: the operator and every hub service identity.
lane2_userns_verify() {
    local img="$1"; shift
    local sec user start count rec ruid u mapped
    LANE2_USERNS_REASON=""
    sec="$(docker info --format '{{json .SecurityOptions}}' 2>/dev/null)" \
        || { LANE2_USERNS_REASON="docker info failed"; return 4; }
    [[ "$sec" == *rootless* ]] && { LANE2_USERNS_REASON="rootless daemon"; return 4; }
    [[ "$sec" == *name=userns* ]] || { LANE2_USERNS_REASON="userns-remap not in effect"; return 4; }
    user="$(jq -r '."userns-remap" // ""' "$LANE2_DOCKER_DAEMON_JSON" 2>/dev/null)"
    [[ -n "$user" && "$user" != default ]] \
        || { LANE2_USERNS_REASON="userns-remap must name a dedicated user in daemon.json"; return 4; }
    user="${user%%:*}"
    rec="$(getent passwd "$user")" || { LANE2_USERNS_REASON="remap user not found"; return 4; }
    ruid="$(cut -d: -f3 <<<"$rec")"
    read -r start count < <(awk -F: -v u="$user" '$1 == u { print $2, $3; exit }' "$LANE2_SUBUID_FILE" 2>/dev/null)
    [[ "$start" =~ ^[0-9]+$ && "$count" =~ ^[0-9]+$ && "$count" -gt 0 && "$start" -gt 0 ]] \
        || { LANE2_USERNS_REASON="no subordinate uid range for the remap user"; return 4; }
    for u in "$@"; do
        [[ "$u" =~ ^[0-9]+$ ]] || continue
        [[ "$u" == "$ruid" ]] && { LANE2_USERNS_REASON="remap user is the operator or a service identity"; return 4; }
        (( u >= start && u < start + count )) && { LANE2_USERNS_REASON="range overlaps the operator or a service identity"; return 4; }
    done
    mapped="$(lane2_userns_probe_uid "$img")" || { LANE2_USERNS_REASON="probe container failed"; return 4; }
    [[ "$mapped" =~ ^[0-9]+$ ]] || { LANE2_USERNS_REASON="probe gave no host uid"; return 4; }
    (( mapped != 0 )) || { LANE2_USERNS_REASON="container root maps to host root"; return 4; }
    (( mapped >= start && mapped < start + count )) \
        || { LANE2_USERNS_REASON="container root maps outside the remap range"; return 4; }
    LANE2_USERNS_MAPPED_UID="$mapped"
}
