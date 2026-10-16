#!/usr/bin/env bash
# gate-store.sh — what the gate keeps about a block (SP1a story 2.4; AD-4,
# AD-7, FR-7, FR-9, FR-10, NFR-7). Gate code: its digest is an input to
# policy_version.
#
# On a block the caller gets an opaque ref; the operator gets the reason, the
# retained payload, and a log line. Nothing here writes a payload or a
# caller-chosen string anywhere but the payload file itself.
#
#   <state>/gate-store/payloads/          0700, gate only
#       <ref>                             0600, the blocked payload
#       index.jsonl                       one line per ref:
#                                         {ref, t, origin, bytes, state}
#   <state>/operator-log/gate.jsonl       {time, op, origin, session,
#                                          reason_category, ref}
#
# API (sourced lib; prefix gate_):
#   gate_store_init <state>                 GATE_STORE_* paths
#   gate_store_check_config <days> <total> <op quota> <container quota>
#                                           rc 0 when valid; never clamps
#   gate_new_ref                            a fresh, unused gr-<32 hex>
#   gate_op_origin <op>                     operator | container | hub
#   gate_op_name <op>                       the op if known, else "unknown"
#   gate_retain <ref> <payload file> <origin>
#                                           rc 0 kept; 4 store fault (full,
#                                           over quota, index corrupt, unwritable,
#                                           lock wait over) — caller blocks
#                                           fault:store
#   gate_purge                              remove expired payloads (keeps a
#                                           tombstone so review can say expired)
#   gate_oplog <op> <origin> <reason category> <ref>
#   gate_review_state <ref>                 prints kept | expired | unknown
#   gate_now                                epoch seconds (tests replace it)

GATE_REF_RE='^gr-[0-9a-f]{32}$'
GATE_KNOWN_OPS=(prompt expansion tool_input tool_result git_text push mount_scan rescan eval health)
GATE_STORE_LOCK_WAIT=2
GATE_TOMBSTONE_DAYS=30

gate_now() { date +%s; }

gate_store_init() {
    GATE_STORE_DIR="$1/gate-store/payloads"
    GATE_STORE_INDEX="$GATE_STORE_DIR/index.jsonl"
    GATE_STORE_LOCK="$1/gate-store/.lock"
    GATE_OPLOG="$1/operator-log/gate.jsonl"
}

gate_store_check_config() {
    local d="$1" total="$2" qo="$3" qc="$4"
    [[ "$d" =~ ^[1-9][0-9]*$ ]] && (( d <= 30 )) || return 1
    [[ "$total" =~ ^[1-9][0-9]{0,11}$ && "$qo" =~ ^[1-9][0-9]{0,11}$ && "$qc" =~ ^[1-9][0-9]{0,11}$ ]] || return 1
    (( qo <= total && qc <= total ))
}

# 128 random bits, never derived from content, time, or a counter; never reused.
gate_new_ref() {
    local r i
    for (( i = 0; i < 8; i++ )); do
        r="gr-$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
        [[ "$r" =~ $GATE_REF_RE ]] || continue
        [[ -e "$GATE_STORE_DIR/$r" ]] && continue
        grep -qF "\"$r\"" "$GATE_STORE_INDEX" 2>/dev/null && continue
        printf '%s' "$r"; return 0
    done
    return 1
}

# AD-20: who wrote the content an op carries.
gate_op_origin() {
    case "$1" in
        prompt) printf 'operator' ;;
        expansion|tool_input|tool_result|git_text|push|rescan) printf 'container' ;;
        *) printf 'hub' ;;
    esac
}

# Only a known op name may reach the log; anything a caller invented is "unknown".
gate_op_name() {
    local o
    for o in "${GATE_KNOWN_OPS[@]}"; do [[ "$1" == "$o" ]] && { printf '%s' "$o"; return; }; done
    printf 'unknown'
}

# Is the index well formed? Corrupt or unreadable counts as over the limit.
_gate_index_ok() {
    [[ -f "$GATE_STORE_INDEX" ]] || { : > "$GATE_STORE_INDEX" 2>/dev/null && chmod 600 "$GATE_STORE_INDEX"; }
    [[ -r "$GATE_STORE_INDEX" && -w "$GATE_STORE_INDEX" ]] || return 1
    [[ ! -s "$GATE_STORE_INDEX" ]] && return 0
    jq -e -s 'all(.[]; type == "object" and (.ref | type) == "string" and (.t | type) == "number"
                     and (.bytes | type) == "number" and (.state == "kept" or .state == "expired"))' \
        "$GATE_STORE_INDEX" >/dev/null 2>&1
}

_gate_purge_locked() {
    local now days keep tmp
    now="$(gate_now)"; days="$GATE_RETAIN_DAYS"
    _gate_index_ok || return 4
    while IFS= read -r keep; do
        [[ "$keep" =~ $GATE_REF_RE ]] && rm -f -- "${GATE_STORE_DIR:?}/$keep"
    done < <(jq -r --argjson now "$now" --argjson d "$days" \
                'select(.state == "kept" and (.t + $d * 86400) <= $now) | .ref' "$GATE_STORE_INDEX")
    tmp="$GATE_STORE_INDEX.tmp"
    jq -c --argjson now "$now" --argjson d "$days" --argjson tomb "$GATE_TOMBSTONE_DAYS" '
        if .state == "kept" and (.t + $d * 86400) <= $now then .state = "expired"
        else . end
        | select(.state == "kept" or (.t + ($d + $tomb) * 86400) > $now)' "$GATE_STORE_INDEX" > "$tmp" \
        && chmod 600 "$tmp" && mv -f "$tmp" "$GATE_STORE_INDEX"
}

gate_purge() {
    (
        exec 8>>"$GATE_STORE_LOCK" || exit 4
        flock -w "$GATE_STORE_LOCK_WAIT" 8 || exit 4
        _gate_purge_locked
    )
}

# Bound check and insert are one step under the lock. Over the total bound or
# the origin's quota is a store fault; nothing unexpired is evicted to make room.
gate_retain() {
    local ref="$1" payload="$2" origin="$3"
    [[ "$ref" =~ $GATE_REF_RE && -f "$payload" ]] || return 4
    (
        exec 8>>"$GATE_STORE_LOCK" || exit 4
        flock -w "$GATE_STORE_LOCK_WAIT" 8 || exit 4
        [[ -d "$GATE_STORE_DIR" ]] || mkdir -m 700 "$GATE_STORE_DIR" 2>/dev/null || exit 4
        [[ -w "$GATE_STORE_DIR" && "$(stat -c %a "$GATE_STORE_DIR")" == 700 ]] || exit 4
        _gate_purge_locked || exit 4
        local bytes used_all used_mine quota class
        bytes="$(wc -c < "$payload" | tr -d ' ')"
        class=operator; [[ "$origin" == container ]] && class=container
        used_all="$(jq -s '[.[] | select(.state == "kept") | .bytes] | add // 0' "$GATE_STORE_INDEX")" || exit 4
        used_mine="$(jq -s --arg c "$class" \
            '[.[] | select(.state == "kept" and ((.origin == "container") == ($c == "container"))) | .bytes] | add // 0' \
            "$GATE_STORE_INDEX")" || exit 4
        if [[ "$class" == container ]]; then quota="$GATE_QUOTA_CONTAINER_BYTES"; else quota="$GATE_QUOTA_OPERATOR_BYTES"; fi
        (( used_all + bytes <= GATE_STORE_MAX_BYTES && used_mine + bytes <= quota )) || exit 4
        ( umask 077; cp -- "$payload" "$GATE_STORE_DIR/$ref" ) || exit 4
        chmod 600 "$GATE_STORE_DIR/$ref"
        jq -nc --arg ref "$ref" --argjson t "$(gate_now)" --arg o "$origin" --argjson b "$bytes" \
            '{ref: $ref, t: $t, origin: $o, bytes: $b, state: "kept"}' >> "$GATE_STORE_INDEX" \
            || { rm -f -- "$GATE_STORE_DIR/$ref"; exit 4; }
    )
}

# One JSONL line per block, every value gate-derived. The gate is the only writer.
gate_oplog() {
    local op origin cat ref
    op="$(gate_op_name "$1")"; origin="$2"; cat="$3"; ref="$4"
    [[ "$ref" =~ $GATE_REF_RE && "$cat" =~ ^(hit|fault):[a-z-]+$ ]] || return 4
    case "$origin" in operator|container|hub) ;; *) return 4 ;; esac
    ( umask 027
      jq -nc --arg time "$(date -u -d "@$(gate_now)" +%Y-%m-%dT%H:%M:%SZ)" --arg op "$op" --arg origin "$origin" \
             --arg cat "$cat" --arg ref "$ref" \
             '{time: $time, op: $op, origin: $origin, session: null, reason_category: $cat, ref: $ref}' \
          >> "$GATE_OPLOG" ) 2>/dev/null
}

gate_review_state() {
    local ref="$1" st
    [[ "$ref" =~ $GATE_REF_RE ]] || { printf 'invalid'; return; }
    st="$(jq -r --arg r "$ref" 'select(.ref == $r) | .state' "$GATE_STORE_INDEX" 2>/dev/null | tail -1)"
    if [[ "$st" == kept ]]; then
        local t; t="$(jq -r --arg r "$ref" 'select(.ref == $r) | .t' "$GATE_STORE_INDEX" | tail -1)"
        if (( t + GATE_RETAIN_DAYS * 86400 <= $(gate_now) )) || [[ ! -f "$GATE_STORE_DIR/$ref" ]]; then
            printf 'expired'; return
        fi
        printf 'kept'; return
    fi
    [[ "$st" == expired ]] && { printf 'expired'; return; }
    printf 'unknown'
}
