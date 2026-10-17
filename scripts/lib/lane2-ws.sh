#!/usr/bin/env bash
# Results are globals read by the lane2 command family.
# shellcheck disable=SC2034
# lane2-ws.sh — workspace marks, work-repo refusal, and the mount-scan manifest
# (SP1a story 3.2; AD-7, AD-8, AD-18, AD-20, AD-24, FR-1, FR-32, FR-47, FR-52).
#
# Workspace state lives in the workspaces store, one file per workspace named
# by its id (the first 32 hex of sha256 of its canonical real path):
#   <state>/workspaces/<id>.json   {path, mark, scan: {state, ref, at}}
#   <state>/workspaces/<id>.lock   the per-workspace lock
# The lane2 command family is the store's only writer.
#
# API (sourced lib; prefix lane2_):
#   lane2_ws_real <path>             canonical path, or rc 2 (missing, not a
#                                    directory, a symlink, or inside the hub's
#                                    own state, install, or policy)
#   lane2_ws_id <canonical path>
#   lane2_ws_mountable <canonical>   rc 0 marked mountable; 3 no (unmarked or
#                                    sensitive); 4 fault (corrupt or unreadable)
#   lane2_ws_scan_state <canonical>  prints unscanned | clean | scan-blocked <ref>
#   lane2_ws_set_mark <canonical> <mountable|sensitive>
#   lane2_ws_set_scan <canonical> <state> [ref]
#   lane2_ws_work_check <canonical>  rc 0 ok; 3 refused (LANE2_WS_REASON says why,
#                                    never a remote or a term)
#   lane2_ws_manifest <canonical> <manifest dir> <scratch>
#                                    rc 0 built; 4 fault (LANE2_WS_REASON): an
#                                    escape, a budget overrun, or a copy error

LANE2_WS_REASON=""

lane2_ws_id() { printf '%s' "$1" | sha256sum | cut -c1-32; }

lane2_ws_real() {
    local p="$1" r
    p="${p%/}"; [[ -n "$p" ]] || return 2
    [[ -L "$p" ]] && return 2
    [[ -d "$p" ]] || return 2
    r="$(realpath -e -- "$p" 2>/dev/null)" || return 2
    local own
    for own in "$STATE" "$PREFIX" "$STATE/gate-policy"; do
        [[ "$r" == "$own" || "$r" == "$own"/* || "$own" == "$r"/* ]] && return 2
    done
    printf '%s' "$r"
}

_lane2_ws_file() { printf '%s/workspaces/%s.json' "$STATE" "$(lane2_ws_id "$1")"; }

# _lane2_ws_read <canonical> — prints the entry; rc 1 none, 4 corrupt/unreadable.
_lane2_ws_read() {
    local f; f="$(_lane2_ws_file "$1")"
    [[ -d "$STATE/workspaces" && -r "$STATE/workspaces" ]] || return 4
    [[ -e "$f" ]] || return 1
    [[ -r "$f" ]] || return 4
    jq -ce --arg p "$1" 'select(type == "object" and .path == $p and (.mark == "mountable" or .mark == "sensitive")
                         and (.scan.state | IN("unscanned", "clean", "scan-blocked")))' "$f" 2>/dev/null || return 4
}

lane2_ws_mountable() {
    local e rc=0
    e="$(_lane2_ws_read "$1")" || rc=$?
    case "$rc" in 0) ;; 1) return 3 ;; *) return 4 ;; esac
    [[ "$(jq -r .mark <<<"$e")" == mountable ]] || return 3
}

lane2_ws_scan_state() {
    local e; e="$(_lane2_ws_read "$1")" || { echo unscanned; return 0; }
    jq -r '.scan | if .state == "scan-blocked" then "scan-blocked \(.ref)" else .state end' <<<"$e"
}

# _lane2_ws_write <canonical> <jq filter> [a1] [a2] — under the per-workspace
# lock. The filter sees $c (current entry or null), $p, $t, $a1, $a2; values
# always travel as --arg, never as filter text.
# shellcheck disable=SC2016  # jq filters below
_lane2_ws_write() {
    local p="$1" filter="$2" a1="${3:-}" a2="${4:-}" f lock
    f="$(_lane2_ws_file "$p")"; lock="${f%.json}.lock"
    (
        exec 8>>"$lock" || exit 4
        chmod 600 "$lock"
        flock -w 10 8 || exit 4
        local cur='null'
        if [[ -s "$f" ]]; then cur="$(jq -c . "$f" 2>/dev/null)" || cur='null'; fi
        [[ -n "$cur" ]] || cur='null'
        ( umask 077; jq -n --argjson c "$cur" --arg p "$p" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            --arg a1 "$a1" --arg a2 "$a2" "($filter)" > "$f.tmp" ) || exit 4
        mv -f "$f.tmp" "$f" || exit 4
    )
}

# shellcheck disable=SC2016  # jq filters
lane2_ws_set_mark() {
    [[ "$2" == mountable || "$2" == sensitive ]] || return 2
    _lane2_ws_write "$1" '(if $c == null or ($c | type) != "object" then {path: $p, scan: {state: "unscanned", ref: null, at: null}} else $c end)
                          | .path = $p | .mark = $a1
                          | if .mark == "sensitive" then .scan = {state: "unscanned", ref: null, at: $t} else . end' "$2"
}

# shellcheck disable=SC2016  # jq filters
lane2_ws_set_scan() {
    [[ "$2" =~ ^(unscanned|clean|scan-blocked)$ ]] || return 2
    [[ -z "${3:-}" || "$3" =~ ^gr-[0-9a-f]{32}$ ]] || return 2
    _lane2_ws_write "$1" '$c | .scan = {state: $a1, ref: (if $a2 == "" then null else $a2 end), at: $t}' "$2" "${3:-}"
}

lane2_ws_event() { # lane2_ws_event <event> <canonical> [extra jq object]
    ( umask 077
      jq -nc --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg e "$1" --arg w "$(lane2_ws_id "$2")" \
          --argjson x "${3:-{\}}" '{time: $t, event: $e, workspace: $w} + $x' >> "$STATE/events/lane2.jsonl" )
}

# --- work-repo refusal (read as data, never by running git) ------------------

_lane2_list() { tr ',' '\n' <<<"$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' || true; }

# The host part of a git URL: scheme://[user@]host[:port]/… or user@host:path.
_lane2_url_host() {
    local u="$1" h
    if [[ "$u" =~ ^[A-Za-z][A-Za-z0-9+.-]*://([^/@]*@)?([^/:]+) ]]; then h="${BASH_REMATCH[2]}"
    elif [[ "$u" =~ ^([^@/:]+@)?([^/:]+):($|[^/]) ]]; then h="${BASH_REMATCH[2]}"
    else return 1; fi
    printf '%s' "${h,,}"
}

# Every URL a workspace's git config, nested repositories, or submodules name.
_lane2_ws_urls() {
    local ws="$1" g f gd
    while IFS= read -r -d '' g; do
        if [[ -f "$g" ]]; then
            gd="$(sed -n 's/^gitdir:[[:space:]]*//p' "$g" | head -1)"
            [[ -n "$gd" ]] || continue
            [[ "$gd" == /* ]] || gd="$(dirname "$g")/$gd"
            g="$gd"
        fi
        f="$g/config"
        [[ -f "$f" && ! -L "$f" ]] || continue
        sed -n -e 's/^[[:space:]]*\(url\|pushurl\)[[:space:]]*=[[:space:]]*//Ip' \
               -e 's/^[[:space:]]*\[url[[:space:]]*"\([^"]*\)".*/\1/Ip' "$f"
    done < <(find "$ws" -name .git \( -type d -o -type f \) -print0 2>/dev/null)
    while IFS= read -r -d '' f; do
        sed -n 's/^[[:space:]]*url[[:space:]]*=[[:space:]]*//Ip' "$f"
    done < <(find "$ws" -name .gitmodules -type f -print0 2>/dev/null)
}

lane2_ws_work_check() {
    local ws="$1" root host url d other
    LANE2_WS_REASON=""
    while IFS= read -r root; do
        root="${root%/}"
        [[ "$ws" == "$root" || "$ws" == "$root"/* ]] && { LANE2_WS_REASON="lies under a work repository root"; return 3; }
    done < <(_lane2_list "$(lane2_conf LANE2_WORK_REPO_ROOTS)")
    while IFS= read -r url; do
        host="$(_lane2_url_host "$url")" || continue
        while IFS= read -r d; do
            d="${d,,}"
            [[ "$host" == "$d" || "$host" == *".$d" ]] \
                && { LANE2_WS_REASON="a remote, nested repository, or submodule names a work git host"; return 3; }
        done < <(_lane2_list "$(lane2_conf LANE2_WORK_GIT_HOSTS)")
    done < <(_lane2_ws_urls "$ws")
    # Containing, or contained by, a path marked sensitive.
    local f p m
    for f in "$STATE"/workspaces/*.json; do
        [[ -e "$f" ]] || continue
        p="$(jq -r '.path // ""' "$f" 2>/dev/null)" || { LANE2_WS_REASON="workspace-state store unreadable"; return 4; }
        m="$(jq -r '.mark // ""' "$f" 2>/dev/null)"
        [[ "$m" == sensitive && -n "$p" ]] || continue
        [[ "$ws" == "$p" || "$ws" == "$p"/* || "$p" == "$ws"/* ]] \
            && { LANE2_WS_REASON="contains, or is contained by, a path marked sensitive"; return 3; }
    done
    return 0
}

# --- the manifest ------------------------------------------------------------

LANE2_WS_N=0; LANE2_WS_BYTES=0

_lane2_ws_add() { # _lane2_ws_add <mdir> <descriptor> <source file>
    local mdir="$1" what="$2" src="$3" sz
    sz="$(stat -c %s -- "$src" 2>/dev/null)" || { LANE2_WS_REASON="cannot read an item"; return 4; }
    LANE2_WS_N=$(( LANE2_WS_N + 1 )); LANE2_WS_BYTES=$(( LANE2_WS_BYTES + sz ))
    (( LANE2_WS_N <= LANE2_SCAN_MAX_FILES && LANE2_WS_BYTES <= LANE2_SCAN_MAX_BYTES )) \
        || { LANE2_WS_REASON="over the scan budget (LANE2_SCAN_MAX_FILES / LANE2_SCAN_MAX_BYTES)"; return 4; }
    cp -- "$src" "$mdir/items/$(printf '%06d' "$LANE2_WS_N")" || { LANE2_WS_REASON="cannot copy an item"; return 4; }
    jq -nc --arg i "$what" '{item: $i}' >> "$mdir/index.jsonl"
}

_lane2_inside() { [[ "$2" == "$1" || "$2" == "$1"/* ]]; }   # _lane2_inside <ws> <path>

# git, only ever in the hub-owned copy: no system or global config, an empty
# HOME, hooks and fsmonitor off.
_lane2_ws_git() { # _lane2_ws_git <copy> <args…>
    local d="$1"; shift
    env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME="$LANE2_WS_HOME" LC_ALL=C \
        GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 GIT_DIR="$d" \
        git -c core.hooksPath=/dev/null -c core.fsmonitor=false "$@"
}

# shellcheck disable=SC2016  # perl code
LANE2_WS_SPLIT='
my ($out) = @ARGV; binmode STDIN; my $n = 0;
while (my $h = <STDIN>) {
    chomp $h; my ($sha, $type, $size) = split / /, $h;
    exit 4 unless defined $size && $size =~ /^\d+$/;
    my $body = ""; read(STDIN, $body, $size) == $size or exit 4; my $nl; read(STDIN, $nl, 1);
    $n++; open(my $o, ">:raw", sprintf("%s/%07d", $out, $n)) or exit 4; print $o $body; close $o;
    open(my $i, ">>", "$out/list") or exit 4; print $i "$sha $type\n"; close $i;
}
'

# _lane2_ws_gitdir <ws> <gitdir> <rel name> <mdir> <scratch> — one git dir.
_lane2_ws_gitdir() {
    local ws="$1" g="$2" rel="$3" mdir="$4" scr="$5" copy l t a k=0 f
    # Pointers out of the workspace are a fault, never followed.
    if [[ -f "$g/commondir" ]]; then
        t="$(head -n1 "$g/commondir")"; [[ "$t" == /* ]] || t="$g/$t"
        _lane2_inside "$ws" "$(realpath -m -- "$t")" || { LANE2_WS_REASON="a commondir points outside the workspace"; return 4; }
    fi
    while IFS= read -r -d '' l; do
        _lane2_inside "$ws" "$(realpath -m -- "$l")" || { LANE2_WS_REASON="a symlink escapes the workspace"; return 4; }
    done < <(find "$g" -type l -print0)
    copy="$scr/git-$(lane2_ws_id "$g")"
    cp -RL --no-preserve=ownership -- "$g" "$copy" 2>/dev/null || { LANE2_WS_REASON="cannot copy a git directory"; return 4; }
    # Alternates: inside the workspace only, and copied too, so git never reads
    # the workspace.
    if [[ -f "$copy/objects/info/alternates" ]]; then
        : > "$scr/alt.new"
        while IFS= read -r a; do
            [[ -n "$a" ]] || continue
            [[ "$a" == /* ]] || a="$g/objects/$a"
            a="$(realpath -m -- "$a")"
            _lane2_inside "$ws" "$a" || { LANE2_WS_REASON="objects/info/alternates points outside the workspace"; return 4; }
            k=$((k + 1)); cp -RL --no-preserve=ownership -- "$a" "$copy/alt-$k" 2>/dev/null \
                || { LANE2_WS_REASON="cannot copy an alternate object directory"; return 4; }
            printf '%s\n' "$copy/alt-$k" >> "$scr/alt.new"
        done < "$copy/objects/info/alternates"
        mv -f "$scr/alt.new" "$copy/objects/info/alternates"
    fi
    # The workspace's config and hooks are data to scan, never used.
    [[ -f "$copy/config" ]] && { _lane2_ws_add "$mdir" "git-config:$rel" "$copy/config" || return 4; }
    if [[ -d "$copy/hooks" ]]; then
        while IFS= read -r -d '' f; do
            _lane2_ws_add "$mdir" "git-hook:$rel/${f#"$copy"/hooks/}" "$f" || return 4
        done < <(find "$copy/hooks" -type f -print0)
    fi
    local fmt=""
    grep -qiE '^[[:space:]]*objectformat[[:space:]]*=[[:space:]]*sha256' "$copy/config" 2>/dev/null && fmt=sha256
    rm -rf -- "$copy/hooks" "$copy/config"
    if [[ -n "$fmt" ]]; then
        printf '[core]\n\trepositoryformatversion = 1\n\tbare = true\n[extensions]\n\tobjectformat = sha256\n' > "$copy/config"
    else
        printf '[core]\n\trepositoryformatversion = 0\n\tbare = true\n' > "$copy/config"
    fi
    # Every other file: refs, packed refs, reflogs (the stash), HEAD, messages,
    # info, LFS objects, submodule git dirs.
    while IFS= read -r -d '' f; do
        _lane2_ws_add "$mdir" "git:$rel/${f#"$copy"/}" "$f" || return 4
    done < <(find "$copy" -path "$copy/objects" -prune -o -path "$copy/alt-*" -prune -o -name config -prune -o -type f -print0)
    # Every ref and branch/tag name as one item.
    _lane2_ws_git "$copy" for-each-ref --format='%(refname)' > "$scr/refnames" 2>/dev/null \
        || { LANE2_WS_REASON="cannot list refs"; return 4; }
    _lane2_ws_add "$mdir" "ref-names:$rel" "$scr/refnames" || return 4
    # Every object, loose or packed, reachable or not.
    local od; od="$scr/obj-$(lane2_ws_id "$g")"; mkdir -m 700 "$od" || return 4
    _lane2_ws_git "$copy" cat-file --batch-all-objects --batch 2>/dev/null | perl -e "$LANE2_WS_SPLIT" "$od" \
        || { LANE2_WS_REASON="cannot read git objects"; return 4; }
    local i=0 sha type
    if [[ -f "$od/list" ]]; then
        while read -r sha type; do
            i=$((i + 1))
            _lane2_ws_add "$mdir" "object:$rel:$sha:$type" "$(printf '%s/%07d' "$od" "$i")" || return 4
        done < "$od/list"
    fi
    rm -rf -- "$od"
    # Submodule git dirs inside this one.
    while IFS= read -r -d '' f; do
        f="${f%/HEAD}"
        [[ -d "$f/objects" ]] || continue
        _lane2_ws_gitdir "$ws" "$g/${f#"$copy"/}" "$rel/${f#"$copy"/}" "$mdir" "$scr" || return 4
    done < <(find "$copy/modules" -name HEAD -type f -print0 2>/dev/null)
    rm -rf -- "$copy"
}

# Instruction files: an import that reaches outside the workspace is a fault.
_lane2_ws_imports() {
    local ws="$1" f imp base t
    while IFS= read -r -d '' f; do
        base="$(dirname "$f")"
        while IFS= read -r imp; do
            imp="${imp#@}"
            case "$imp" in
                "~"*) LANE2_WS_REASON="an instruction file imports from outside the workspace"; return 4 ;;
                /*) t="$imp" ;;
                *) t="$base/$imp" ;;
            esac
            _lane2_inside "$ws" "$(realpath -m -- "$t")" \
                || { LANE2_WS_REASON="an instruction file imports from outside the workspace"; return 4; }
        done < <(grep -oE '(^|[[:space:]])@[~./A-Za-z0-9_][^[:space:]]*' "$f" 2>/dev/null | sed 's/^[[:space:]]*//')
    done < <(find "$ws" \( -name CLAUDE.md -o -path '*/.claude/*' \) -type f -name '*.md' -print0 2>/dev/null)
    return 0
}

lane2_ws_manifest() {
    local ws="$1" mdir="$2" scr="$3" f l g rel
    LANE2_WS_N=0; LANE2_WS_BYTES=0; LANE2_WS_REASON=""
    LANE2_SCAN_MAX_FILES="$(lane2_conf LANE2_SCAN_MAX_FILES 50000)"
    LANE2_SCAN_MAX_BYTES="$(lane2_conf LANE2_SCAN_MAX_BYTES 536870912)"
    [[ "$LANE2_SCAN_MAX_FILES" =~ ^[1-9][0-9]*$ && "$LANE2_SCAN_MAX_BYTES" =~ ^[1-9][0-9]*$ ]] \
        || { LANE2_WS_REASON="LANE2_SCAN_MAX_FILES / LANE2_SCAN_MAX_BYTES invalid"; return 4; }
    LANE2_WS_HOME="$scr/home"; mkdir -m 700 "$LANE2_WS_HOME" "$mdir/items" || return 4
    : > "$mdir/index.jsonl"
    # Symlinks anywhere in the workspace may not escape it.
    while IFS= read -r -d '' l; do
        _lane2_inside "$ws" "$(realpath -m -- "$l")" || { LANE2_WS_REASON="a symlink escapes the workspace"; return 4; }
    done < <(find "$ws" -type l -print0)
    _lane2_ws_imports "$ws" || return 4
    # Working tree: every regular file (tracked, untracked, ignored), outside git dirs.
    while IFS= read -r -d '' f; do
        _lane2_ws_add "$mdir" "tree:${f#"$ws"/}" "$f" || return 4
    done < <(find "$ws" -name .git -prune -o -type f -print0)
    # Git dirs: .git directories, and gitfiles pointing to one inside the workspace.
    while IFS= read -r -d '' g; do
        rel="${g#"$ws"/}"; [[ "$g" == "$ws/.git" ]] && rel=".git"
        if [[ -f "$g" ]]; then
            local gd; gd="$(sed -n 's/^gitdir:[[:space:]]*//p' "$g" | head -1)"
            [[ -n "$gd" ]] || { LANE2_WS_REASON="a gitfile without a gitdir"; return 4; }
            [[ "$gd" == /* ]] || gd="$(dirname "$g")/$gd"
            gd="$(realpath -m -- "$gd")"
            _lane2_inside "$ws" "$gd" || { LANE2_WS_REASON="a gitfile points outside the workspace"; return 4; }
            _lane2_ws_add "$mdir" "gitfile:$rel" "$g" || return 4
            continue            # the git dir it names is inside, and found as a .git dir or under modules/
        fi
        _lane2_ws_gitdir "$ws" "$g" "$rel" "$mdir" "$scr" || return 4
    done < <(find "$ws" -name .git \( -type d -o -type f \) -prune -print0)
    return 0
}
