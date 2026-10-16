#!/usr/bin/env bash
# `cond && ok … || bad …` is safe in this file: ok and bad always return 0.
# shellcheck disable=SC2015
# test-lane2-image.sh — the Lane 2 image and container definition (SP1a story
# 3.1, #111; AD-9, AD-18, AD-21, AD-23, FR-16, FR-31, FR-48).
# tier: ci — a stub docker; no daemon, no network.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="$ROOT/scripts/lib/lane2-image.sh"
DEF="$ROOT/scripts/hub/container/lane2-container.json"
PASS=0; FAIL=0
ok()   { echo "  OK  $1"; ((PASS++)) || true; }
bad()  { echo " FAIL $1"; ((FAIL++)) || true; }
check(){ if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (no '$3' in output)"; printf '%s\n' "$2" | sed 's/^/      | /' ;; esac; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
L() { bash -c 'source "$1"; shift; eval "$*"' _ "$LIB" "$@"; }

# =============================================================================
echo "== container definition lint =="
check "shipped definition passes" "$(L "lane2_container_lint '$DEF'")" ""
mut() { # mut <label> <jq edit> <expected problem text>
    jq "$2" "$DEF" > "$TMP/d.json"
    has "$1" "$(L "lane2_container_lint '$TMP/d.json'")" "$3"
}
mut "writable root filesystem"     '.read_only = false'                          "not read-only"
mut "no tmpfs scratch"             '.tmpfs = []'                                 "no tmpfs"
mut "capabilities kept"            '.cap_drop = []'                              "capabilities not dropped"
mut "a capability added"           '.cap_add = ["NET_ADMIN"]'                    "capabilities not dropped"
mut "no-new-privileges missing"    '.security_opt = []'                          "no-new-privileges"
mut "root default user"            '.user = "root"'                              "default user is root"
mut "uid 0 default user"           '.user = "0:0"'                               "default user is root"
mut "privileged"                   '.privileged = true'                          "privileged"
mut "a device"                     '.devices = ["/dev/dri"]'                     "devices present"
mut "pid host"                     '.pid = "host"'                               "pid host"
mut "network host"                 '.network = "host"'                           "network is not none"
mut "bridge network"               '.network = "bridge"'                         "network is not none"
mut "userns host"                  '.userns = "host"'                            "userns host"
mut "host-gateway alias"           '.add_host = ["host.docker.internal:host-gateway"]' "add_host present"
mut "LOCAL_MODEL_ variable"        '.env = {"LOCAL_MODEL_ENDPOINT": "x"}'        "LOCAL_MODEL_"
mut "docker socket mount"          '.mounts += [{"kind":"workspace","target":"/x","mode":"rw","source":"/var/run/docker.sock"}]' "control socket"
mut "containerd socket anywhere"   '.extra = "/run/containerd/containerd.sock"'  "control socket"
mut "podman socket"                '.extra = "/run/podman/podman.sock"'           "control socket"
mut "a fixed host source"          '.mounts += [{"kind":"workspace","target":"/y","mode":"rw","source":"/srv/data"}]' "fixed host source"
mut "a mount outside the AD-21 list" '.mounts += [{"kind":"home","target":"/home/x","mode":"ro"}]' "not in the AD-21 list: home"
mut "workspace mounted read-only"  '(.mounts[] | select(.kind == "workspace") | .mode) = "ro"' "mount workspace must be rw"
mut "integration policy writable"  '(.mounts[] | select(.kind == "integration-policy") | .mode) = "rw"' "mount integration-policy must be ro"

echo "== Claude Code version pin =="
v() { L "lane2_claude_version_ok '$1' '$2'"; echo $?; }
check "2.1.301 from latest" "$(v 2.1.301 latest)" 0
check "the floor itself (2.1.299)" "$(v 2.1.299 latest)" 0
check "below the floor (2.1.298) refused" "$(v 2.1.298 latest)" 4
check "the literal latest refused" "$(v latest latest)" 4
check "a range refused" "$(v '^2.1.301' latest)" 4
check "a wildcard refused" "$(v 2.1.x latest)" 4
check "the stable channel refused" "$(v 2.1.301 stable)" 4
check "an empty pin refused" "$(v '' latest)" 4
check "the shipped pin is valid" \
    "$(v "$(jq -r .container.claude_code.version "$ROOT/scripts/hub/pin-manifest.json")" "$(jq -r .container.claude_code.channel "$ROOT/scripts/hub/pin-manifest.json")")" 0

echo "== Dockerfile =="
DF="$(cat "$ROOT/scripts/hub/container/Dockerfile")"
# The ${...} below are literal Dockerfile text, matched as-is.
# shellcheck disable=SC2016
has "base comes from the pin (by digest)" "$DF" 'FROM ${BASE_IMAGE}'
# shellcheck disable=SC2016
has "exact Claude Code version" "$DF" '@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}'
has "root-owned install" "$DF" "chown -R root:root /usr/local/lib/node_modules"
has "managed settings baked in" "$DF" "/etc/claude-code/managed-settings.json"
has "non-root default user" "$DF" "USER node"
check "auto-update off in the managed settings seed" \
    "$(jq -c '[.autoUpdates, .env.DISABLE_AUTOUPDATER]' "$ROOT/scripts/hub/integration/managed-settings.base.json")" '[false,"1"]'

# =============================================================================
echo "== build (stub docker) =="
S="$TMP/dstate"; mkdir -p "$S" "$TMP/bin"
IMG="sha256:$(printf '1%.0s' {1..64})"; CSHA="$(printf 'c%.0s' {1..64})"
cat > "$TMP/bin/docker" <<EOF
#!/usr/bin/env bash
S="$S"
printf '%s\n' "\$*" >> "\$S/calls"
case "\$1" in
  build)
    [[ -f "\$S/fail-build" ]] && exit 1
    while (( \$# )); do
      case "\$1" in --iidfile) printf '%s' "$IMG" > "\$2"; shift 2 ;; *) last="\$1"; shift ;; esac
    done
    ls "\$last" > "\$S/context" ;;
  run)
    case "\$*" in
      *"claude --version"*) cat "\$S/version" 2>/dev/null || echo "2.1.301 (Claude Code)" ;;
      *sha256sum*) echo "\$(cat "\$S/sha" 2>/dev/null || echo $CSHA)  /usr/local/lib/node_modules/x/claude.exe" ;;
    esac ;;
  image) [[ -f "\$S/no-image" ]] || echo "$IMG" ;;
  info) cat "\$S/secopts" ;;
esac
EOF
chmod +x "$TMP/bin/docker"
export PATH="$TMP/bin:$PATH"
TREE="$TMP/tree"; mkdir -p "$TREE/scripts/hub/container" "$TREE/scripts/hub/integration"
cp "$ROOT/scripts/hub/container/"* "$TREE/scripts/hub/container/"
cp "$ROOT/scripts/hub/integration/managed-settings.base.json" "$TREE/scripts/hub/integration/"
jq '.container.base_digest = "sha256:'"$(printf 'b%.0s' {1..64})"'"' "$ROOT/scripts/hub/pin-manifest.json" > "$TREE/scripts/hub/pin-manifest.json"
W="$TMP/work"; mkdir -p "$W"
build() { L "lane2_image_build '$TREE' '$W'; echo \"rc=\$? id=\$LANE2_IMAGE_ID ver=\$LANE2_CLAUDE_VERSION sha=\$LANE2_CLAUDE_SHA256 idg=\$LANE2_INTEGRATION_DIGEST\""; }
OUT="$(build)"
has "build succeeds" "$OUT" "rc=0"
has "image id recorded" "$OUT" "id=$IMG"
has "claude version read from the image" "$OUT" "ver=2.1.301"
has "claude binary sha recorded" "$OUT" "sha=$CSHA"
has "integration digest = the rendered managed settings" "$OUT" "idg=$(jq -S . "$ROOT/scripts/hub/integration/managed-settings.base.json" | sha256sum | cut -d' ' -f1)"
check "build context is only the Dockerfile and the rendered settings" "$(tr '\n' ' ' < "$S/context")" "Dockerfile managed-settings.json "
has "base pulled by digest" "$(grep '^build' "$S/calls")" "BASE_IMAGE=node:24@sha256:bbbb"
has "exact claude version as a build arg" "$(grep '^build' "$S/calls")" "CLAUDE_CODE_VERSION=2.1.301"
has "probes run without network" "$(grep '^run' "$S/calls" | head -1)" "--network none"
touch "$S/fail-build"; OUT="$(build)"; rm -f "$S/fail-build"
has "a failed build: exit 4" "$OUT" "rc=4"
has "a failed build leaves no image recorded" "$OUT" "id= "
echo "2.1.300 (Claude Code)" > "$S/version"; OUT="$(build)"; rm -f "$S/version"
has "image claude version not the pin: exit 4, nothing recorded" "$OUT" "rc=4 id= "
jq '.container.base_digest = ""' "$ROOT/scripts/hub/pin-manifest.json" > "$TREE/scripts/hub/pin-manifest.json"
OUT="$(build 2>&1)"
has "no pinned base digest: refused" "$OUT" "base_digest not pinned"
jq '.container.base_digest = "sha256:'"$(printf 'b%.0s' {1..64})"'" | .container.claude_code.version = "latest"' \
    "$ROOT/scripts/hub/pin-manifest.json" > "$TREE/scripts/hub/pin-manifest.json"
OUT="$(build 2>&1)"
has "a pin of latest: refused" "$OUT" "exact version"
jq '.container.base_digest = "sha256:'"$(printf 'b%.0s' {1..64})"'" | .privileged = true' "$DEF" > "$TREE/scripts/hub/container/lane2-container.json"
jq '.container.base_digest = "sha256:'"$(printf 'b%.0s' {1..64})"'"' "$ROOT/scripts/hub/pin-manifest.json" > "$TREE/scripts/hub/pin-manifest.json"
OUT="$(build 2>&1)"
has "a definition that fails the lint is not built" "$OUT" "container definition: privileged"

echo "== digest and image checks =="
L "lane2_claude_digest_check '$IMG' '$CSHA'"; check "binary matches its pin" "$?" 0
L "lane2_claude_digest_check '$IMG' '$(printf 'd%.0s' {1..64})'"; check "binary differs from its pin: 4" "$?" 4
L "lane2_image_check '$IMG'"; check "pinned image present" "$?" 0
touch "$S/no-image"; L "lane2_image_check '$IMG'"; check "pinned image missing: 4" "$?" 4; rm -f "$S/no-image"
L "lane2_image_check latest"; check "a tag instead of a digest: 4" "$?" 4

echo "== userns-remap =="
DJ="$TMP/daemon.json"; SU="$TMP/subuid"; ME="$(id -u)"
uv() { # uv <mapped uid> — verify with nobody as the remap user
    bash -c 'source "$1"; LANE2_DOCKER_DAEMON_JSON="$2"; LANE2_SUBUID_FILE="$3"; MAPPED="$4"
             lane2_userns_probe_uid() { echo "$MAPPED"; }
             lane2_userns_verify img "$5"; echo "rc=$? $LANE2_USERNS_REASON"' _ "$LIB" "$DJ" "$SU" "$1" "$ME"
}
echo '["name=apparmor","name=seccomp,profile=builtin","name=userns"]' > "$S/secopts"
echo '{"userns-remap": "nobody"}' > "$DJ"; echo "nobody:400000:65536" > "$SU"
check "rootful, remapped, dedicated range" "$(uv 400000)" "rc=0 "
check "container root maps to host root" "$(uv 0)" "rc=4 container root maps to host root"
check "container root maps outside the range" "$(uv 100)" "rc=4 container root maps outside the remap range"
check "probe with no answer is not read as uid 0" "$(uv '')" "rc=4 probe gave no host uid"
echo '["name=seccomp,profile=builtin"]' > "$S/secopts"
check "remap off" "$(uv 400000)" "rc=4 userns-remap not in effect"
echo '["name=seccomp,profile=builtin","name=rootless","name=userns"]' > "$S/secopts"
check "rootless daemon" "$(uv 400000)" "rc=4 rootless daemon"
echo '["name=userns"]' > "$S/secopts"
echo '{"userns-remap": "default"}' > "$DJ"
check "default remap user (not dedicated)" "$(uv 400000)" "rc=4 userns-remap must name a dedicated user in daemon.json"
echo '{"userns-remap": "nobody"}' > "$DJ"; echo "nobody:$(( ME - 10 )):65536" > "$SU"
check "range overlapping the operator" "$(uv "$(( ME - 10 ))")" "rc=4 range overlaps the operator or a service identity"
echo "other:400000:65536" > "$SU"
check "no range for the remap user" "$(uv 400000)" "rc=4 no subordinate uid range for the remap user"

echo "== public-repo hygiene =="
HITS="$(grep -nE '([0-9]{1,3}\.){3}[0-9]{1,3}|[0-9]{4,}:[0-9]{4,}' "$DEF" "$ROOT/scripts/hub/container/Dockerfile" "$ROOT/scripts/hub/pin-manifest.json" || true)"
check "no address or uid range in the tracked definition" "$HITS" ""

echo
echo "lane2-image: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
