#!/usr/bin/env bash
# lane2.sh — shared hub helpers for the `lane2` command family (SP1a story 2.1;
# AD-7, AD-14, AD-18, AD-21, AD-22, FR-22, FR-52, NFR-6).
#
# This lib holds what `lane2 install` needs and later lane2 commands reuse: the
# hub config, the store table and its checks, service identities, the tree
# digest, and unit rendering and linting.
#
# API (sourced lib; prefix lane2_):
#   lane2_load_config <file>     parse hub config into LANE2_CONF (last wins)
#   lane2_conf <KEY> [default]   a parsed value
#   lane2_in_container           rc 0 inside a container
#   lane2_is_root                rc 0 when running as root
#   lane2_check_origin <url>     rc 0 for a remote origin; local paths refused
#   lane2_uid <role>             uid for a role (root | operator | gate | fleet-*)
#   lane2_gid <role>             gid for a role's group
#   lane2_ensure_identity <name> create a system user with no login shell
#   lane2_check_identity <name>  rc 0 if <name> is a non-root nologin system user
#   lane2_stores                 print the AD-7 store table (name owner group mode)
#   lane2_ensure_stores <root>   create missing stores; refuse wrong owner or mode
#   lane2_tree_digest <dir> [path ...]  sha256 over sorted file list + contents
#   lane2_lint_unit <file>       print problems with a rendered unit (none = ok)
#   lane2_boot_allowed <unit>    rc 0 if the unit may be enabled at boot
#
# Test seams: lane2_is_root, lane2_in_container, lane2_check_origin, lane2_uid,
# lane2_gid, lane2_ensure_identity, and lane2_chown are plain functions so a test
# that SOURCES this lib can replace them. Running `lane2` as root executes the
# real ones; nothing in the environment can switch them.

# Read by the lane2 command family that sources this lib.
# shellcheck disable=SC2034
LANE2_SERVICE_IDENTITIES=(lane2-gate lane2-fleet-orchestrator lane2-fleet-classifier)

# --- config ------------------------------------------------------------------

declare -A LANE2_CONF=()
lane2_load_config() {
    local file="$1" line key val
    LANE2_CONF=()
    [[ -f "$file" ]] || return 0
    [[ -r "$file" ]] || return 4
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        [[ "$line" =~ ^[[:space:]]*([A-Z0-9_]+)=(.*)$ ]] || continue
        key="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"
        case "$val" in
            \"*\") val="${val%\"}"; val="${val#\"}" ;;
            \'*\') val="${val%\'}"; val="${val#\'}" ;;
            *) val="${val%%[[:space:]]#*}"; val="${val%"${val##*[![:space:]]}"}" ;;
        esac
        LANE2_CONF["$key"]="$val"
    done < "$file"
}

lane2_conf() { printf '%s' "${LANE2_CONF[$1]:-${2:-}}"; }

# lane2_conf_file_get <file> <KEY> — one key from another hub config file
# (e.g. fleet.conf), same parsing rules, last assignment wins. Empty if absent.
lane2_conf_file_get() {
    local file="$1" key="$2" line val=""
    [[ -f "$file" && -r "$file" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*${key}=(.*)$ ]] || continue
        val="${BASH_REMATCH[1]}"
        case "$val" in
            \"*\") val="${val%\"}"; val="${val#\"}" ;;
            \'*\') val="${val%\'}"; val="${val#\'}" ;;
            *) val="${val%%[[:space:]]#*}"; val="${val%"${val##*[![:space:]]}"}" ;;
        esac
    done < "$file"
    printf '%s' "$val"
}

# --- environment -------------------------------------------------------------

lane2_in_container() {
    [[ -f /.dockerenv || -f /run/.containerenv ]] && return 0
    [[ -n "${DEVCONTAINER:-}${REMOTE_CONTAINERS:-}${CODESPACES:-}${container:-}" ]] && return 0
    grep -qE 'docker|containerd|kubepods|lxc|libpod' /proc/1/cgroup 2>/dev/null && return 0
    return 1
}

lane2_is_root() { [[ "$(id -u)" == 0 ]]; }

lane2_is_operator() {
    local op; op="$(lane2_uid operator 2>/dev/null)" || return 1
    [[ -n "$op" && "$(id -u)" == "$op" ]]
}

# The policy repository is private and reached with the host's own SSH config,
# so scp-style user@host:path is allowed here as well. Local paths and file://
# are refused for the same reason as the code origin.
lane2_check_policy_repo() {
    local url="$1"
    lane2_check_origin "$url" && return 0
    [[ "$url" =~ ^[A-Za-z0-9._-]+@[A-Za-z0-9.-]+:[A-Za-z0-9._/-]+$ && "$url" != *..* ]]
}

# Only a remote origin is accepted. A local path, file:// URL, or anything
# without a scheme could point into a workspace the agent writes, which is the
# exact path AD-18 closes. Credentials in the URL are refused too.
lane2_check_origin() {
    local url="$1"
    [[ "$url" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?/[^[:space:]@]+$ ]] && return 0
    [[ "$url" =~ ^ssh://([A-Za-z0-9._-]+@)?[A-Za-z0-9.-]+(:[0-9]+)?/[^[:space:]]+$ ]] && return 0
    return 1
}

# --- identities --------------------------------------------------------------

# Role -> account name. "operator" is the configured operator account.
lane2_role_user() {
    case "$1" in
        root) printf 'root' ;;
        operator) lane2_conf LANE2_OPERATOR ;;
        gate) printf 'lane2-gate' ;;
        fleet-orchestrator) printf 'lane2-fleet-orchestrator' ;;
        fleet-classifier) printf 'lane2-fleet-classifier' ;;
        *) return 1 ;;
    esac
}

lane2_uid() {
    local u; u="$(lane2_role_user "$1")" || return 1
    [[ -n "$u" ]] || return 1
    getent passwd "$u" | cut -d: -f3
}

lane2_gid() {
    local u; u="$(lane2_role_user "$1")" || return 1
    [[ -n "$u" ]] || return 1
    getent passwd "$u" | cut -d: -f4
}

lane2_chown() { chown "$@"; }

lane2_ensure_identity() {
    local name="$1"
    getent passwd "$name" >/dev/null && return 0
    useradd --system --user-group --no-create-home --home-dir /nonexistent \
        --shell /usr/sbin/nologin "$name"
}

# A service identity is a non-root system account with no login shell, not
# shared with the operator.
lane2_check_identity() {
    local name="$1" rec uid shell op
    rec="$(getent passwd "$name")" || return 1
    uid="$(cut -d: -f3 <<<"$rec")"; shell="$(cut -d: -f7 <<<"$rec")"
    [[ "$uid" != 0 ]] || return 1
    case "$shell" in */nologin|*/false) ;; *) return 1 ;; esac
    op="$(lane2_uid operator 2>/dev/null)" || op=""
    [[ -z "$op" || "$uid" != "$op" ]]
}

# --- stores (AD-7) -----------------------------------------------------------

# name owner-role group-role mode. One subdirectory per store under the state
# root, owned by its sole writer. Mode is 0700, except where AD-7 names a reader
# under another identity: that reader gets read through the group, and the
# directory is setgid (2750) so files the writer creates carry the reader's
# group without the writer being a member of it.
lane2_stores() {
    cat <<'EOF'
gate-policy  operator gate     2750
gate-store   gate     gate     0700
operator-log gate     operator 2750
events       operator operator 0700
sessions     operator gate     2750
workspaces   operator operator 0700
exclusions   operator gate     2750
eval         operator operator 0700
fleet        operator operator 0700
push         operator operator 0700
install      root     root     0700
EOF
}

# lane2_ensure_stores <state-root> — prints one line per store; returns 4 on the
# first store that exists with the wrong owner, group, or mode, or is a symlink.
lane2_ensure_stores() {
    local root="$1" name owner group mode dir want have
    [[ -d "$root" && ! -L "$root" ]] || { printf ' FAIL state root missing: %s\n' "$root"; return 4; }
    have="$(stat -c '%u %a' "$root")"
    [[ "$have" == "$(lane2_uid root) 755" || "$have" == "$(lane2_uid root) 711" ]] \
        || { printf ' FAIL state root must be root-owned, mode 0755 (is %s): %s\n' "$have" "$root"; return 4; }
    while read -r name owner group mode; do
        dir="$root/$name"
        want="$(lane2_uid "$owner") $(lane2_gid "$group") ${mode#0}"
        [[ "$want" =~ ^[0-9]+\ [0-9]+\ [0-9]+$ ]] \
            || { printf ' FAIL store %s: owner %s or group %s has no account\n' "$name" "$owner" "$group"; return 4; }
        if [[ -L "$dir" ]]; then
            printf ' FAIL store %s is a symlink\n' "$name"; return 4
        elif [[ -e "$dir" ]]; then
            have="$(stat -c '%u %g %a' "$dir")"
            if [[ "$have" != "$want" ]]; then
                printf ' FAIL store %s: owner/group/mode is %s, want %s (fix it by hand; install never chmods)\n' \
                    "$name" "$have" "$want"
                return 4
            fi
            printf '  OK  store %s\n' "$name"
        else
            mkdir -m "$mode" "$dir" || { printf ' FAIL cannot create store %s\n' "$name"; return 4; }
            lane2_chown "$(lane2_uid "$owner"):$(lane2_gid "$group")" "$dir" \
                || { printf ' FAIL cannot set owner of store %s\n' "$name"; return 4; }
            printf '  OK  store %s created\n' "$name"
        fi
    done < <(lane2_stores)
}

# lane2_check_store <state-root> <name> — rc 0 when the store exists with exactly
# its table owner, group, and mode. For non-root callers that use a store root
# created it.
lane2_check_store() {
    local root="$1" want_name="$2" name owner group mode want
    while read -r name owner group mode; do
        [[ "$name" == "$want_name" ]] || continue
        [[ -d "$root/$name" && ! -L "$root/$name" ]] || return 1
        want="$(lane2_uid "$owner") $(lane2_gid "$group") ${mode#0}"
        [[ "$(stat -c '%u %g %a' "$root/$name")" == "$want" ]]
        return
    done < <(lane2_stores)
    return 1
}

# --- digests -----------------------------------------------------------------

# lane2_tree_digest <dir> [relative path prefixes...] — sha256 over the sorted
# list of regular files and symlinks with each one's content (or link target).
# With prefixes, only paths under them count; no match is the digest of nothing.
lane2_tree_digest() {
    local dir="$1" p keep pre; shift
    (
        cd "$dir" || exit 4
        find . \( -type f -o -type l \) ! -name '.lane2-*' -print0 \
            | LC_ALL=C sort -z \
            | while IFS= read -r -d '' p; do
                p="${p#./}"
                if (( $# > 0 )); then
                    keep=0
                    for pre in "$@"; do [[ "$p" == "$pre"* ]] && keep=1; done
                    (( keep )) || continue
                fi
                if [[ -L "$p" ]]; then
                    printf 'L %s %s\n' "$p" "$(readlink "$p")"
                else
                    printf 'F %s %s\n' "$p" "$(sha256sum < "$p" | cut -d' ' -f1)"
                fi
            done
    ) | sha256sum | cut -d' ' -f1
}

# Gate code: what the gate executes. Its digest is an input to policy_version.
# Read by the lane2 command family that sources this lib.
# shellcheck disable=SC2034
LANE2_GATE_CODE=(scripts/lib/gate scripts/hub/gate)

# --- units (AD-18, AD-22) ----------------------------------------------------

# Only these may be enabled at boot: the gate sockets, the fleet units, the
# notifier. Supervisors, Lane 2 containers, and sessions never start at boot.
lane2_boot_allowed() {
    case "$1" in
        gate-*.socket|fleet-*.service|lane2-notify.service) return 0 ;;
        *) return 1 ;;
    esac
}

# lane2_lint_user_unit <file> — an operator user unit (the notifier): no home or
# workspace path, no placeholder left, NoNewPrivileges, and the boot rule.
lane2_lint_user_unit() {
    local f="$1" name; name="user/${1##*/}"
    grep -qE '(/home/|/workspace|/root/|~/|\.claude/worktrees)' "$f" \
        && echo "$name references a workspace or home path"
    grep -qE '@[A-Z_]+@' "$f" && echo "$name has an unrendered placeholder"
    grep -qxF 'NoNewPrivileges=yes' "$f" || echo "$name lacks NoNewPrivileges=yes"
    if lane2_boot_allowed "${f##*/}"; then
        grep -qxF 'Restart=on-failure' "$f" || echo "$name is boot-enabled but lacks Restart=on-failure"
    elif grep -q '^\[Install\]' "$f"; then
        echo "$name has an [Install] section but is not on the boot allowlist"
    fi
    return 0
}

# lane2_lint_unit <file> — prints one problem per line; nothing printed = ok.
lane2_lint_unit() {
    local f="$1" name; name="${f##*/}"
    grep -qE '(/home/|/workspace|/root/|~/|@REPO@|\.claude/worktrees)' "$f" \
        && echo "$name references a workspace or home path"
    grep -qE '@[A-Z_]+@' "$f" && echo "$name has an unrendered placeholder"
    if [[ "$name" == *.service ]]; then
        local k
        for k in 'NoNewPrivileges=yes' 'ProtectSystem=strict' 'ProtectHome=yes' \
                 'PrivateTmp=yes' 'LimitCORE=0'; do
            grep -qxF "$k" "$f" || echo "$name lacks $k"
        done
        grep -qE '^User=(root)?$' "$f" && echo "$name runs as root"
        grep -qE '^User=.+' "$f" || echo "$name has no User="
        if lane2_boot_allowed "$name"; then
            grep -qxF 'Restart=on-failure' "$f" || echo "$name is boot-enabled but lacks Restart=on-failure"
        fi
    fi
    if ! lane2_boot_allowed "$name" && grep -q '^\[Install\]' "$f"; then
        echo "$name has an [Install] section but is not on the boot allowlist"
    fi
    return 0
}
