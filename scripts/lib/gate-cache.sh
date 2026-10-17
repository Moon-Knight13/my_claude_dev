#!/usr/bin/env bash
# Results are globals read by the gate handler and gate_decide.
# shellcheck disable=SC2034
# gate-cache.sh — verdict cache, per-peer rate limit and probe budget, and the
# query log (SP1a story 2.5; AD-4, AD-7, AD-19, AD-20, FR-10, FR-13, FR-14,
# NFR-7). Gate code: its digest is an input to policy_version.
#
#   <state>/gate-store/cache.jsonl     {k, pv}: allows under the full layer set
#   <state>/gate-store/counters/<uid>  {w, r, b}: window start, requests, blocks
#   <state>/gate-store/query.jsonl     {time, op, peer_uid, verdict, ref}
#
# All three are the gate's alone (gate-store, 0700) and hold no content: the
# cache keys are hashes, the query log is metadata.
#
# API (sourced lib; prefix gate_):
#   gate_cache_init <state>
#   gate_cache_key <file> <policy_version> <layer set>   prints the key
#   gate_cache_lookup <key> <policy_version>   rc 0 hit, 1 miss, 4 fault (corrupt,
#                                              unreadable, lock wait over); entries
#                                              under any other policy_version are
#                                              purged first
#   gate_cache_store <key> <policy_version>    rc 0 stored, 4 fault
#   gate_rate_check <uid>       rc 0 within the limits, 3 over (rate or probe
#                               budget), counting this request; corrupt or
#                               unreadable counters, or a lock wait over, are 3
#   gate_rate_count_block <uid> count a block toward the probe budget
#   gate_rate_check_config <limit> <window> <budget>   rc 0 when valid
#   gate_query_log <op> <uid> <verdict> <ref or "">
#
# GATE_CACHE_BYPASS=1 is the one decision-core flag that keeps a request away
# from the cache (eval and health set it).

GATE_CACHE_BYPASS=0
GATE_CACHE_HIT=0
GATE_CACHE_LOCK_WAIT=2
GATE_CACHE_MAX_ENTRIES=50000
GATE_QUERY_LOG_MAX_BYTES=8388608
GATE_QUERY_LOG_KEEP_LINES=100000
GATE_HEX64='^[0-9a-f]{64}$'

gate_now_s() { date +%s; }

gate_cache_init() {
    GATE_CACHE_FILE="$1/gate-store/cache.jsonl"
    GATE_CACHE_LOCK="$1/gate-store/.cache.lock"
    GATE_COUNTERS_DIR="$1/gate-store/counters"
    GATE_COUNTERS_LOCK="$1/gate-store/.counters.lock"
    GATE_QUERY_LOG="$1/gate-store/query.jsonl"
}

# Normalised content: line endings as LF and trailing newlines at the end
# removed, so the same text from different callers maps to one key. Nothing else
# is changed; the hash is never of the raw bytes a caller chose to vary.
gate_content_sha() {
    sed 's/\r$//' -- "$1" | sed -e ':a' -e '/^\n*$/{$d;N;ba' -e '}' | sha256sum | cut -d' ' -f1
}

gate_cache_key() { # gate_cache_key <file> <pv> <layer set>
    local c; c="$(gate_content_sha "$1")" || return 4
    printf '%s|%s|%s' "$c" "$2" "$3" | sha256sum | cut -d' ' -f1
}

# Index check: every line {k: hex64, pv: hex64}. Corrupt is a fault, never a miss.
_gate_cache_ok() {
    [[ -f "$GATE_CACHE_FILE" ]] || return 0
    [[ -r "$GATE_CACHE_FILE" && -w "$GATE_CACHE_FILE" ]] || return 1
    [[ -s "$GATE_CACHE_FILE" ]] || return 0
    jq -e -s 'all(.[]; type == "object" and (.k | type) == "string" and (.k | test("^[0-9a-f]{64}$"))
                     and (.pv | type) == "string" and (.pv | test("^[0-9a-f]{64}$")))' \
        "$GATE_CACHE_FILE" >/dev/null 2>&1
}

gate_cache_lookup() {
    local key="$1" pv="$2"
    [[ "$key" =~ $GATE_HEX64 && "$pv" =~ $GATE_HEX64 ]] || return 4
    (
        exec 7>>"$GATE_CACHE_LOCK" || exit 4
        flock -w "$GATE_CACHE_LOCK_WAIT" 7 || exit 4
        _gate_cache_ok || exit 4
        [[ -s "$GATE_CACHE_FILE" ]] || exit 1
        # A new policy_version: nothing older is ever served, and it is purged.
        if jq -e -s --arg pv "$pv" 'any(.[]; .pv != $pv)' "$GATE_CACHE_FILE" >/dev/null 2>&1; then
            jq -c --arg pv "$pv" 'select(.pv == $pv)' "$GATE_CACHE_FILE" > "$GATE_CACHE_FILE.tmp" \
                && chmod 600 "$GATE_CACHE_FILE.tmp" && mv -f "$GATE_CACHE_FILE.tmp" "$GATE_CACHE_FILE" || exit 4
        fi
        grep -qF "\"k\":\"$key\"" "$GATE_CACHE_FILE" && exit 0
        exit 1
    )
}

gate_cache_store() {
    local key="$1" pv="$2" n
    [[ "$key" =~ $GATE_HEX64 && "$pv" =~ $GATE_HEX64 ]] || return 4
    (
        exec 7>>"$GATE_CACHE_LOCK" || exit 4
        flock -w "$GATE_CACHE_LOCK_WAIT" 7 || exit 4
        _gate_cache_ok || exit 4
        ( umask 077; jq -nc --arg k "$key" --arg pv "$pv" '{k: $k, pv: $pv}' >> "$GATE_CACHE_FILE" ) || exit 4
        chmod 600 "$GATE_CACHE_FILE"
        n="$(wc -l < "$GATE_CACHE_FILE" | tr -d ' ')"
        if (( n > GATE_CACHE_MAX_ENTRIES )); then
            tail -n "$GATE_CACHE_MAX_ENTRIES" "$GATE_CACHE_FILE" > "$GATE_CACHE_FILE.tmp" \
                && chmod 600 "$GATE_CACHE_FILE.tmp" && mv -f "$GATE_CACHE_FILE.tmp" "$GATE_CACHE_FILE" || exit 4
        fi
    )
}

# --- rate limit and probe budget (per hub-socket peer uid) -------------------

gate_rate_check_config() {
    local l="$1" w="$2" b="$3"
    [[ "$l" =~ ^[1-9][0-9]{0,5}$ && "$w" =~ ^[1-9][0-9]{0,4}$ && "$b" =~ ^[1-9][0-9]{0,5}$ ]] || return 1
    (( w <= 86400 ))
}

# _gate_counters_update <uid> <add requests> <add blocks> — prints "r b" after the
# update; rc 4 if the counters are corrupt or unreadable, or the lock wait is over.
_gate_counters_update() {
    local uid="$1" ar="$2" ab="$3"
    [[ "$uid" =~ ^[0-9]+$ ]] || return 4
    (
        exec 6>>"$GATE_COUNTERS_LOCK" || exit 4
        flock -w "$GATE_CACHE_LOCK_WAIT" 6 || exit 4
        [[ -d "$GATE_COUNTERS_DIR" ]] || mkdir -m 700 "$GATE_COUNTERS_DIR" 2>/dev/null || exit 4
        local f="$GATE_COUNTERS_DIR/$uid" now w=0 r=0 b=0 cur
        now="$(gate_now_s)"
        if [[ -e "$f" ]]; then
            cur="$(jq -er 'select(type == "object" and (.w | type) == "number" and (.r | type) == "number"
                                  and (.b | type) == "number") | "\(.w) \(.r) \(.b)"' "$f" 2>/dev/null)" || exit 4
            read -r w r b <<<"$cur"
        fi
        if (( now >= w + GATE_RATE_WINDOW )); then w="$now"; r=0; b=0; fi
        r=$(( r + ar )); b=$(( b + ab ))
        ( umask 077; jq -nc --argjson w "$w" --argjson r "$r" --argjson b "$b" '{w: $w, r: $r, b: $b}' > "$f.tmp" ) || exit 4
        mv -f "$f.tmp" "$f" || exit 4
        printf '%s %s' "$r" "$b"
    )
}

gate_rate_check() {
    local out r b
    out="$(_gate_counters_update "$1" 1 0)" || return 3
    read -r r b <<<"$out"
    (( r <= GATE_RATE_LIMIT && b < GATE_PROBE_BUDGET )) || return 3
}

gate_rate_count_block() { _gate_counters_update "$1" 0 1 >/dev/null 2>&1 || true; }

# --- query log ---------------------------------------------------------------

gate_query_log() { # gate_query_log <op> <uid> <verdict> <ref>
    local op="$1" uid="$2" v="$3" ref="$4" size
    [[ -n "${GATE_QUERY_LOG:-}" ]] || return 0
    [[ "$uid" =~ ^[0-9]+$ ]] || uid=""
    [[ "$v" == allow || "$v" == block ]] || v=block
    [[ "$ref" =~ ^gr-[0-9a-f]{32}$ ]] || ref=""
    ( umask 077
      jq -nc --arg time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg op "$op" --arg uid "$uid" --arg v "$v" --arg ref "$ref" \
          '{time: $time, op: $op, peer_uid: (if $uid == "" then null else ($uid | tonumber) end),
            verdict: $v, ref: (if $ref == "" then null else $ref end)}' >> "$GATE_QUERY_LOG" ) 2>/dev/null || return 0
    size="$(wc -c < "$GATE_QUERY_LOG" 2>/dev/null | tr -d ' ')"
    if [[ -n "$size" ]] && (( size > GATE_QUERY_LOG_MAX_BYTES )); then
        tail -n "$GATE_QUERY_LOG_KEEP_LINES" "$GATE_QUERY_LOG" > "$GATE_QUERY_LOG.tmp" 2>/dev/null \
            && chmod 600 "$GATE_QUERY_LOG.tmp" && mv -f "$GATE_QUERY_LOG.tmp" "$GATE_QUERY_LOG"
    fi
    return 0
}
