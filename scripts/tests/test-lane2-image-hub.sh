#!/usr/bin/env bash
# `cond && ok … || bad …` is safe in this file: ok and bad always return 0.
# shellcheck disable=SC2015
# test-lane2-image-hub.sh — the real Lane 2 image on the hub (SP1a story 3.1,
# #111; AD-7, AD-21, FR-48, SM-1).
# tier: hub — after `lane2 install` built the image. Skips (exit 0) unless run
# as root on the hub with LANE2_HUB_TEST=1.
#
#   sudo LANE2_HUB_TEST=1 bash scripts/tests/test-lane2-image-hub.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok()   { echo "  OK  $1"; ((PASS++)) || true; }
bad()  { echo " FAIL $1"; ((FAIL++)) || true; }

# shellcheck source=/dev/null
source "$ROOT/scripts/lib/lane2.sh"
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/lane2-image.sh"
if [[ "${LANE2_HUB_TEST:-}" != 1 ]] || ! lane2_is_root || lane2_in_container; then
    echo "  !!  skipped: hub tier — run as root on the hub with LANE2_HUB_TEST=1"
    exit 0
fi
lane2_load_config /etc/lane2/lane2.conf
STATE="$(lane2_conf LANE2_STATE_ROOT /var/lib/lane2)"
REC="$STATE/install/manifest.json"
IMG="$(jq -r '.container.image_id // ""' "$REC")"

echo "== image and pins =="
[[ -n "$IMG" ]] && ok "image recorded in the install record" || { bad "no image recorded; run lane2 install"; exit 1; }
lane2_image_check "$IMG" && ok "image present by digest" || bad "image $IMG missing"
lane2_claude_digest_check "$IMG" "$(jq -r .container.claude_sha256 "$REC")" && ok "claude binary matches its pin" || bad "claude binary differs"
V="$(lane2_claude_version_in "$IMG")"
[[ -n "$V" ]] && _lane2_ver_ge "$V" "$LANE2_CLAUDE_FLOOR" && ok "claude --version $V >= floor" || bad "claude version $V"
[[ "$(docker run --rm --network none --entrypoint /bin/sh "$IMG" -c 'id -u' 2>/dev/null)" != 0 ]] \
    && ok "default user is not root" || bad "image runs as root"

echo "== userns-remap =="
UIDS=()
for n in "$(lane2_conf LANE2_OPERATOR)" "${LANE2_SERVICE_IDENTITIES[@]}"; do UIDS+=("$(getent passwd "$n" | cut -d: -f3)"); done
if lane2_userns_verify "$IMG" "${UIDS[@]}"; then
    ok "userns-remap in effect"
else
    bad "userns-remap: $LANE2_USERNS_REASON"; exit 1
fi
M="$LANE2_USERNS_MAPPED_UID"

echo "== container root, as its host uid, reads no store and no runtime socket =="
WALKED=()
while read -r name _ _ _; do
    WALKED+=("$name")
    if setpriv --reuid="$M" --regid="$M" --clear-groups test -r "$STATE/$name" 2>/dev/null \
       || setpriv --reuid="$M" --regid="$M" --clear-groups ls "$STATE/$name" >/dev/null 2>&1; then
        bad "mapped uid can read store $name"
    else
        ok "store $name denied"
    fi
done < <(lane2_stores)
echo "      stores walked (from the AD-7 table): ${WALKED[*]}"
for s in /var/run/docker.sock /run/docker.sock /run/containerd/containerd.sock; do
    [[ -e "$s" ]] || continue
    setpriv --reuid="$M" --regid="$M" --clear-groups test -w "$s" 2>/dev/null \
        && bad "mapped uid can use $s" || ok "runtime socket $s denied"
done

echo
echo "lane2-image-hub: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
