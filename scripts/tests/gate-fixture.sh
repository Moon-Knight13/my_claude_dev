#!/usr/bin/env bash
# Sourced by the gate suites, which read RC, RESP, REASON and call gf_conf with
# arguments; shellcheck cannot see that from this file alone.
# shellcheck disable=SC2034,SC2119,SC2120
# gate-fixture.sh — shared fixture for the gate suites (test-gate-protocol.sh,
# test-gate-faults.sh). Sourced, not run: it is not a test-*.sh suite.
#
# Builds a hub in a temp dir: hub config (lane2.conf, gate.conf, fleet.conf), a
# policy checkout with synthetic terms (zzalpha, zzbravo), an installed tree for
# the gate-code digest, the llama-server mock as the classifier, and the real
# gate-handler behind a real unix socket (accept-socket.py, as Accept=yes).
# Uses real socat when installed, else socat-shim.py.

GF_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GF_HANDLER="$GF_ROOT/scripts/hub/gate-handler"
GF_MOCK="$GF_ROOT/scripts/tests/mock-llama-server.py"
GF_SHA="$(printf 'a%.0s' {1..64})"
GF_PIDS=()

gf_setup() {
    TMP="$(mktemp -d)"
    trap 'gf_teardown' EXIT
    CONF="$TMP/etc"; STATE="$TMP/state"; PREFIX="$TMP/opt"; MS="$TMP/mock"; SOCK="$TMP/hub.sock"
    mkdir -p "$CONF" "$STATE/gate-policy/trees/p1" "$PREFIX/c1/scripts/lib" "$MS" "$TMP/bin"
    cp "$GF_ROOT/scripts/lib/gate.sh" "$PREFIX/c1/scripts/lib/gate.sh"; ln -s c1 "$PREFIX/current"
    printf '# synthetic\nzzalpha\nzzbravo\n' > "$STATE/gate-policy/trees/p1/term-list.txt"
    printf 'Classify the text. Reply with the JSON verdict.\n' > "$STATE/gate-policy/trees/p1/classifier-prompt.md"
    ln -s trees/p1 "$STATE/gate-policy/current"
    printf 'ZZSENSITIVE\t{"verdict":"sensitive"}\n' > "$MS/rules"
    MOCK_STATE_DIR="$MS" python3 "$GF_MOCK" & GF_PIDS+=($!)
    local i; for (( i = 0; i < 50; i++ )); do [[ -s "$MS/port" ]] && break; sleep 0.1; done
    PORT="$(cat "$MS/port")"
    if ! command -v socat >/dev/null 2>&1; then
        ln -s "$GF_ROOT/scripts/tests/socat-shim.py" "$TMP/bin/socat"
        export PATH="$TMP/bin:$PATH"
    fi
    gf_conf
    python3 "$GF_ROOT/scripts/tests/accept-socket.py" "$SOCK" bash "$GF_HANDLER" "$CONF" & GF_PIDS+=($!)
    for (( i = 0; i < 50; i++ )); do [[ -S "$SOCK" ]] && break; sleep 0.1; done
    # shellcheck source=/dev/null
    source "$GF_ROOT/scripts/lib/gate-client.sh"
}

gf_teardown() {
    local p; for p in "${GF_PIDS[@]}"; do kill "$p" 2>/dev/null; done
    rm -rf "$TMP"
}

# gf_conf [KEY=VALUE ...] — rewrite the hub config; extra lines go to gate.conf
# (GATE_*) or fleet.conf (FLEET_*), last assignment wins.
gf_conf() {
    { echo "LANE2_OPERATOR=$(id -un)"; echo "LANE2_PREFIX=$PREFIX"; echo "LANE2_STATE_ROOT=$STATE"; } > "$CONF/lane2.conf"
    { echo "GATE_MAX_REQUEST=4096"; echo "GATE_DEADLINE=10"; echo "GATE_SHIM_TIMEOUT=28"; echo "GATE_HOOK_TIMEOUT=30"; } > "$CONF/gate.conf"
    { echo "FLEET_CLASSIFIER_ENDPOINT=http://127.0.0.1:$PORT"; echo "FLEET_CLASSIFIER_MODEL=clf-test"
      echo "FLEET_CLASSIFIER_SHA256=$GF_SHA"; echo "FLEET_RUNTIME_BUILD=b1234"; echo "FLEET_PROBE_TIMEOUT=2"; } > "$CONF/fleet.conf"
    local kv
    for kv in "$@"; do
        case "$kv" in GATE_*) echo "$kv" >> "$CONF/gate.conf" ;; FLEET_*) echo "$kv" >> "$CONF/fleet.conf" ;; esac
    done
}

gf_mode() { printf '%s' "$1" > "$MS/mode"; }
gf_completions() { grep -c '"/v1/chat/completions"' "$MS/requests.jsonl" 2>/dev/null || true; }

# gf_ask <layers> <text> — ask the eval op through gate_client.
# Sets RC (0 allow, 3 block, 4 local fault), RESP, and REASON.
gf_ask() {
    local hdr
    hdr="$(jq -nc --arg l "$1" '{v: 1, op: "eval", layers: ($l | split(","))}')"
    RC=0; gate_client "$SOCK" 20 "$hdr" < <(printf '%s' "$2") || RC=$?
    RESP="$GATE_CLIENT_RESPONSE"
    REASON="$(jq -r '.detail.reason // ""' <<<"${RESP:-null}" 2>/dev/null)"
}

# gf_raw <mode> < bytes — a raw connection (gate-raw-client.py).
gf_raw() { python3 "$GF_ROOT/scripts/tests/gate-raw-client.py" "$SOCK" "$1"; }
gf_reason_of() { jq -r '.detail.reason // ""' <<<"$1" 2>/dev/null | head -1; }
