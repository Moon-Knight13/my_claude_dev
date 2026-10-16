#!/usr/bin/env bash
# fleet.sh — the one model-call client (SP1a story 1.3; AD-10, FR-12, FR-17,
# FR-18, NFR-3). Every request to a local model endpoint goes through fleet_call;
# a lint test (scripts/tests/test-fleet-call.sh) fails on a direct request
# anywhere else.
#
# Why one client: the gate, the eval harness, and the Lane 1 client must call
# the model with the same settings, or eval and production measure different
# things. fleet_call also makes every call fail closed and the same each time:
#
#   /health -> /props (n_ctx) -> /apply-template -> /tokenize
#     -> fit check (prompt tokens + max_tokens <= n_ctx) -> /v1/chat/completions
#
# Any step that fails is a fault. A fault never becomes a success: there is no
# retry, and the input is never truncated, sampled, or split to make it fit.
#
# API (sourced lib; prefix fleet_):
#   fleet_use_config <file>    use this fleet config file instead of the default
#   fleet_load_config          parse it into FLEET_CONF (rc 4 if unreadable)
#   fleet_conf <KEY> [default] a parsed value
#   fleet_member_endpoint <m>  check member <m>'s endpoint; sets FLEET_EP_BASE,
#                              FLEET_EP_SOCK (rc 4 if missing or not allowed)
#   fleet_member_model <m>     print member <m>'s model alias (rc 4 if missing)
#   fleet_call <member> <settings-file> [system-prompt-file] < input
#                              print the validated model output
#   fleet_in_container         rc 0 inside a container
#
# Config: one hub config file, default /etc/lane2/fleet.conf. It is parsed,
# never sourced, and the last assignment wins. Nothing here is read from the
# environment: not the config path, not an endpoint, not a model, not a limit.
# The config path is set by code (fleet_use_config), never by a variable a
# caller's environment could carry in.
#   FLEET_<MEMBER>_ENDPOINT   http://127.x.y.z:<port>, http://[::1]:<port>, or
#                             unix:<FLEET_SOCKET_DIR>/<name>.sock. A port is
#                             required: nothing relies on a default port.
#   FLEET_<MEMBER>_MODEL      the exact --alias the member serves
#   FLEET_SOCKET_DIR          where hub fleet sockets live (default /run/lane2/fleet)
#   FLEET_PROBE_TIMEOUT       seconds for /health, /props, /apply-template, /tokenize (5)
#   FLEET_MAX_INPUT_BYTES     largest input accepted; bigger is a fault (1048576)
#   FLEET_MAX_RESPONSE_BYTES  largest server reply read (1048576)
#
# Settings file (JSON; the pinned classifier file is
# scripts/hub/fleet/classifier.settings.json):
#   {"max_tokens": N, "timeout_seconds": N, "params": {...}}
#   params go into the completion request as they are (temperature, seed,
#   response_format, cache_prompt, id_slot, ...). They may not set model,
#   messages, prompt, stream, or any token limit: the fit check depends on
#   max_tokens being the only one. A response_format of type json_schema must
#   be a flat object of string enums; the reply is then checked against it.
#
# fleet_call exit codes (callers treat every non-zero as block):
#   0 output on stdout   2 usage   4 config, settings, or input fault
#   5 endpoint fault (unhealthy, loading, unreachable, timeout, a probe failed)
#   6 does not fit (input too big, fit check, exceed_context_size_error)
#   7 bad reply (non-200, malformed, truncated, empty, extra field, not in enum)
# Stderr carries one fixed-text line per fault, never input or output text.

# Assigned when sourced, so a value in the caller's environment is discarded.
FLEET_CONF_FILE=/etc/lane2/fleet.conf
declare -gA FLEET_CONF=()
FLEET_EP_BASE=""
FLEET_EP_SOCK=""

fleet_use_config() { FLEET_CONF_FILE="${1:?fleet_use_config <file>}"; }

fleet_load_config() {
    local file="$FLEET_CONF_FILE" line key val
    FLEET_CONF=()
    [[ -f "$file" ]] || return 4
    [[ -r "$file" ]] || return 4
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        [[ "$line" =~ ^[[:space:]]*(FLEET_[A-Z0-9_]+)=(.*)$ ]] || continue
        key="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"
        case "$val" in
            \"*\") val="${val%\"}"; val="${val#\"}" ;;
            \'*\') val="${val%\'}"; val="${val#\'}" ;;
            *) val="${val%%[[:space:]]#*}"; val="${val%"${val##*[![:space:]]}"}" ;;
        esac
        FLEET_CONF["$key"]="$val"
    done < "$file"
    return 0
}

fleet_conf() { printf '%s' "${FLEET_CONF[$1]:-${2:-}}"; }

fleet_in_container() {
    [[ -f /.dockerenv || -f /run/.containerenv ]] && return 0
    [[ -n "${DEVCONTAINER:-}${REMOTE_CONTAINERS:-}${CODESPACES:-}${container:-}" ]] && return 0
    grep -qE 'docker|containerd|kubepods|lxc|libpod' /proc/1/cgroup 2>/dev/null && return 0
    return 1
}

_fleet_member_ok() { [[ "$1" =~ ^[a-z][a-z0-9]{0,31}$ ]]; }

# fleet_member_endpoint <member> — loopback IP literal with a port, or a socket
# under FLEET_SOCKET_DIR. No hostname (not even localhost: name resolution is
# not loopback by construction), no userinfo, no path, no https, no default port.
fleet_member_endpoint() {
    local m="$1" ep sockdir oct port path
    FLEET_EP_BASE=""; FLEET_EP_SOCK=""
    _fleet_member_ok "$m" || return 4
    ep="$(fleet_conf "FLEET_${m^^}_ENDPOINT")"
    [[ -n "$ep" ]] || return 4
    if [[ "$ep" =~ ^http://127\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3}):([0-9]{1,5})$ ]]; then
        for oct in "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"; do
            (( 10#$oct <= 255 )) || return 4
        done
        port="${BASH_REMATCH[4]}"
        (( 10#$port >= 1 && 10#$port <= 65535 )) || return 4
        FLEET_EP_BASE="$ep"
        return 0
    fi
    if [[ "$ep" =~ ^http://\[::1\]:([0-9]{1,5})$ ]]; then
        port="${BASH_REMATCH[1]}"
        (( 10#$port >= 1 && 10#$port <= 65535 )) || return 4
        FLEET_EP_BASE="$ep"
        return 0
    fi
    if [[ "$ep" == unix:* ]]; then
        path="${ep#unix:}"
        sockdir="$(fleet_conf FLEET_SOCKET_DIR /run/lane2/fleet)"
        sockdir="${sockdir%/}"
        [[ "$sockdir" =~ ^(/[A-Za-z0-9._-]+)+$ && "$sockdir" != *"/.."* && "$sockdir" != *"/./"* ]] || return 4
        [[ "$path" =~ ^/[A-Za-z0-9._/-]+\.sock$ ]] || return 4
        [[ "$path" != *"/../"* && "$path" != *"/./"* && "$path" != *"//"* ]] || return 4
        [[ "$path" == "$sockdir/"* ]] || return 4
        FLEET_EP_SOCK="$path"
        FLEET_EP_BASE="http://localhost"
        return 0
    fi
    return 4
}

fleet_member_model() {
    local m="$1" model
    _fleet_member_ok "$m" || return 4
    model="$(fleet_conf "FLEET_${m^^}_MODEL")"
    [[ "$model" =~ ^[A-Za-z0-9][A-Za-z0-9._:/@+-]{0,127}$ ]] || return 4
    printf '%s' "$model"
}

_fleet_int() { # _fleet_int <value> <min> <max>
    [[ "$1" =~ ^[0-9]{1,9}$ ]] && (( 10#$1 >= $2 && 10#$1 <= $3 ))
}

# _fleet_http <path> <timeout> <body-file|-> <out-file> — prints the HTTP code
# (000 when no reply). -q first so no curlrc is read; proxies, redirects, and
# every protocol but http are off. The body travels as a file, never on argv.
_fleet_http() {
    local path="$1" timeout="$2" body="$3" out="$4" maxres="$5"
    local -a args=(-q -sS --noproxy '*' --proto '=http' --max-redirs 0
                   --max-time "$timeout" --max-filesize "$maxres"
                   -o "$out" -w '%{http_code}')
    [[ -n "$FLEET_EP_SOCK" ]] && args+=(--unix-socket "$FLEET_EP_SOCK")
    [[ "$body" != - ]] && args+=(-X POST -H 'Content-Type: application/json' --data-binary "@$body")
    curl "${args[@]}" "$FLEET_EP_BASE$path" 2>/dev/null || true
}

_fleet_size() { wc -c < "$1" 2>/dev/null | tr -d ' '; }

# fleet_call <member> <settings-file> [system-prompt-file] < input
# Runs in a subshell so its temp directory is always removed.
fleet_call() (
    set +e
    set -u -o pipefail
    umask 077
    fault() { printf ' FAIL fleet_call: %s\n' "$2" >&2; exit "$1"; }

    (( $# == 2 || $# == 3 )) || fault 2 "usage: fleet_call <member> <settings-file> [system-prompt-file] < input"
    local member="$1" fc_settings="$2" sysfile="${3:-}"
    local model probe maxin maxres tmo max_tokens rfmt n_ctx ntok code size
    command -v curl >/dev/null 2>&1 || fault 4 "curl not installed"
    command -v jq >/dev/null 2>&1 || fault 4 "jq not installed"

    # --- config: endpoint, model, limits. No network before all of it holds. --
    fleet_load_config || fault 4 "fleet config missing or unreadable"
    fleet_member_endpoint "$member" || fault 4 "member '$member': endpoint missing or not loopback / hub socket"
    model="$(fleet_member_model "$member")" || fault 4 "member '$member': model alias missing or malformed"
    probe="$(fleet_conf FLEET_PROBE_TIMEOUT 5)"
    maxin="$(fleet_conf FLEET_MAX_INPUT_BYTES 1048576)"
    maxres="$(fleet_conf FLEET_MAX_RESPONSE_BYTES 1048576)"
    _fleet_int "$probe" 1 120 || fault 4 "FLEET_PROBE_TIMEOUT must be 1..120"
    _fleet_int "$maxin" 1 67108864 || fault 4 "FLEET_MAX_INPUT_BYTES must be 1..67108864"
    _fleet_int "$maxres" 1024 67108864 || fault 4 "FLEET_MAX_RESPONSE_BYTES must be 1024..67108864"

    # --- settings ------------------------------------------------------------
    [[ -f "$fc_settings" && -r "$fc_settings" ]] || fault 4 "settings file unreadable"
    jq -e '
        type == "object"
        and (.max_tokens | type == "number" and . == floor and . >= 1 and . <= 32768)
        and (.timeout_seconds | type == "number" and . == floor and . >= 1 and . <= 600)
        and (.params | type == "object")
        and ([.params | keys[]] - ["model","messages","prompt","stream","max_tokens",
              "n_predict","max_completion_tokens","n_ctx"] | length) == (.params | keys | length)
        and (if .params.response_format == null then true
             else .params.response_format.type == "json_schema"
              and (.params.response_format.json_schema.schema as $s
                   | ($s.type == "object") and ($s.additionalProperties == false)
                   and ($s.properties | type == "object" and length > 0)
                   and ([$s.properties[] | (.type == "string") and (.enum | type == "array" and length > 0
                         and all(.[]; type == "string"))] | all)
                   and (($s.required // []) | sort) == ($s.properties | keys | sort))
             end)' "$fc_settings" >/dev/null 2>&1 || fault 4 "settings file malformed or sets a forbidden key"
    max_tokens="$(jq -r .max_tokens "$fc_settings")"
    tmo="$(jq -r .timeout_seconds "$fc_settings")"
    rfmt="$(jq -r '.params.response_format.type // "text"' "$fc_settings")"
    if [[ -n "$sysfile" ]]; then
        [[ -f "$sysfile" && -r "$sysfile" && -s "$sysfile" ]] || fault 4 "system prompt file unreadable or empty"
    fi

    # --- input: bounded read; too big is a fault, never a truncation ---------
    local fc_t; fc_t="$(mktemp -d)" || fault 4 "no temp directory"
    trap 'rm -rf "$fc_t"' EXIT
    head -c "$(( maxin + 1 ))" > "$fc_t/in"
    size="$(_fleet_size "$fc_t/in")"
    (( size > 0 )) || fault 4 "empty input"
    (( size <= maxin )) || fault 6 "input over FLEET_MAX_INPUT_BYTES; not truncated"
    [[ "$(tr -d '\000' < "$fc_t/in" | wc -c | tr -d ' ')" == "$size" ]] || fault 4 "input contains NUL"
    if command -v iconv >/dev/null 2>&1; then
        iconv -f UTF-8 -t UTF-8 < "$fc_t/in" > /dev/null 2>&1 || fault 4 "input is not valid UTF-8"
    fi
    if [[ -n "$sysfile" ]]; then
        jq -n --rawfile u "$fc_t/in" --rawfile s "$sysfile" \
            '[{role: "system", content: $s}, {role: "user", content: $u}]' > "$fc_t/msgs" 2>/dev/null
    else
        jq -n --rawfile u "$fc_t/in" '[{role: "user", content: $u}]' > "$fc_t/msgs" 2>/dev/null
    fi || fault 4 "could not build messages"

    # --- 1. /health ----------------------------------------------------------
    code="$(_fleet_http /health "$probe" - "$fc_t/health" "$maxres")"
    [[ "$code" == 200 ]] || fault 5 "member '$member' not healthy (HTTP $code)"

    # --- 2. /props: n_ctx as the server reports it ---------------------------
    code="$(_fleet_http /props "$probe" - "$fc_t/props" "$maxres")"
    [[ "$code" == 200 ]] || fault 5 "/props failed (HTTP $code)"
    n_ctx="$(jq -er '(.default_generation_settings.n_ctx // .n_ctx)
                     | select(type == "number" and . == floor and . > 0)' "$fc_t/props" 2>/dev/null)" \
        || fault 5 "/props gave no n_ctx"

    # --- 3. /apply-template, 4. /tokenize ------------------------------------
    jq -c --slurpfile m "$fc_t/msgs" '{messages: $m[0]}
        + (if .params.chat_template_kwargs then {chat_template_kwargs: .params.chat_template_kwargs} else {} end)' \
        "$fc_settings" > "$fc_t/tmpl-req" 2>/dev/null || fault 4 "could not build template request"
    code="$(_fleet_http /apply-template "$probe" "$fc_t/tmpl-req" "$fc_t/tmpl" "$maxres")"
    [[ "$code" == 200 ]] || fault 5 "/apply-template failed (HTTP $code)"
    jq -ce '.prompt | select(type == "string" and length > 0)
            | {content: ., add_special: true, parse_special: true}' "$fc_t/tmpl" > "$fc_t/tok-req" 2>/dev/null \
        || fault 5 "/apply-template gave no prompt"
    code="$(_fleet_http /tokenize "$probe" "$fc_t/tok-req" "$fc_t/tok" "$maxres")"
    [[ "$code" == 200 ]] || fault 5 "/tokenize failed (HTTP $code)"
    ntok="$(jq -er '.tokens | select(type == "array") | length' "$fc_t/tok" 2>/dev/null)" \
        || fault 5 "/tokenize gave no tokens"

    # --- fit check -----------------------------------------------------------
    (( ntok + max_tokens <= n_ctx )) || fault 6 "does not fit: prompt $ntok + max_tokens $max_tokens > n_ctx $n_ctx"

    # --- 5. completion: one request, no retry --------------------------------
    jq -cS --slurpfile m "$fc_t/msgs" --arg model "$model" \
        '.params + {model: $model, messages: $m[0], max_tokens: .max_tokens, stream: false}' \
        "$fc_settings" > "$fc_t/req" 2>/dev/null || fault 4 "could not build request"
    code="$(_fleet_http /v1/chat/completions "$tmo" "$fc_t/req" "$fc_t/resp" "$maxres")"
    size="$(_fleet_size "$fc_t/resp")"; size="${size:-0}"
    (( size <= maxres )) || fault 7 "reply over FLEET_MAX_RESPONSE_BYTES"
    if [[ "$code" != 200 ]]; then
        [[ "$code" == 000 ]] && fault 5 "completion: no reply (timeout or unreachable)"
        jq -e '.error.type == "exceed_context_size_error"' "$fc_t/resp" >/dev/null 2>&1 \
            && fault 6 "server reports exceed_context_size_error"
        fault 7 "completion failed (HTTP $code)"
    fi
    jq -e '(.choices | type == "array" and length == 1)
           and (.choices[0].finish_reason == "stop")
           and (.choices[0].message.content | type == "string")' "$fc_t/resp" >/dev/null 2>&1 \
        || fault 7 "reply malformed, truncated, or not finished with stop"
    jq -j '.choices[0].message.content' "$fc_t/resp" > "$fc_t/content" 2>/dev/null || fault 7 "reply unreadable"
    [[ -n "$(tr -d '[:space:]' < "$fc_t/content")" ]] || fault 7 "reply empty"

    if [[ "$rfmt" == json_schema ]]; then
        # Exactly one JSON object, exactly the schema's keys, each value in its enum.
        jq -cs --slurpfile s "$fc_settings" '
            ($s[0].params.response_format.json_schema.schema) as $sch
            | select(length == 1) | .[0]
            | select(type == "object")
            | select((keys | sort) == ($sch.properties | keys | sort))
            | select(to_entries | all(.value as $v | $sch.properties[.key].enum | any(.[]; . == $v)))' \
            "$fc_t/content" > "$fc_t/out" 2>/dev/null
        [[ -s "$fc_t/out" ]] || fault 7 "reply is not one object of the schema's enum values"
        cat "$fc_t/out"
    else
        cat "$fc_t/content"
    fi
    exit 0
)
