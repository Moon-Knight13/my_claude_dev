#!/usr/bin/env bash
# gate-client.sh — the one client every hub caller uses to ask the gate
# (SP1a story 2.3; AD-2, AD-3, FR-10).
#
#   gate_client <socket> <deadline seconds> <header json> < payload
#       rc 0  the gate answered a well-formed allow
#       rc 3  anything else: a block, or no / empty / malformed / oversized /
#             trailing-data answer, unknown v, timeout, socket missing
#       rc 4  a local fault before asking (bad arguments, socat missing);
#             callers treat it as block too
#   GATE_CLIENT_RESPONSE holds the answer line when there was one.
#
# The rule (AD-3): only a well-formed {"v":1,"verdict":"allow"} within the
# deadline is an allow. A block is never retried into an allow. The payload is
# streamed to the gate as-is: never truncated, sampled, or split.

GATE_CLIENT_RESPONSE=""
GATE_CLIENT_MAX_ANSWER=4096

# GATE_CLIENT_RESPONSE is read by callers.
# shellcheck disable=SC2034
gate_client() {
    local sock="$1" dl="$2" hdr="$3" out bytes last
    GATE_CLIENT_RESPONSE=""
    [[ "$dl" =~ ^[1-9][0-9]{0,3}$ ]] || return 4
    [[ "$hdr" != *$'\n'* && -n "$hdr" ]] || return 4
    command -v socat >/dev/null 2>&1 || return 4
    [[ -S "$sock" ]] || return 3
    out="$(mktemp)" || return 4
    { printf '%s\n' "$hdr"; cat; } \
        | timeout -k 1 "$dl" socat -t "$dl" -T "$dl" - "UNIX-CONNECT:$sock" 2>/dev/null \
        | head -c "$(( GATE_CLIENT_MAX_ANSWER + 1 ))" > "$out"
    bytes="$(wc -c < "$out" | tr -d ' ')"
    last="$(tail -c 1 "$out" | od -An -tx1 | tr -d ' \n')"
    if (( bytes == 0 || bytes > GATE_CLIENT_MAX_ANSWER )) || [[ "$last" != 0a ]] \
        || [[ "$(wc -l < "$out" | tr -d ' ')" != 1 ]]; then
        rm -f "$out"; return 3
    fi
    GATE_CLIENT_RESPONSE="$(head -n 1 "$out")"
    # An empty line is no answer; jq -e alone would not say so on every version.
    [[ "$GATE_CLIENT_RESPONSE" == \{* ]] || { rm -f "$out"; return 3; }
    if jq -e '(.v | type) == "number" and .v == 1 and .verdict == "allow"
              and ((keys - ["v", "verdict", "detail"]) == [])' "$out" >/dev/null 2>&1; then
        rm -f "$out"; return 0
    fi
    rm -f "$out"; return 3
}
