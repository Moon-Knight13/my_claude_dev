#!/usr/bin/env bash
# Idempotent "managed block" helpers for the devbox SSH config (issue #38).
#
# bootstrap-devbox grows over time: directives get added (IdentityFile for the
# box key, RemoteForward for the local-model tunnel) that did not exist when a
# developer first bootstrapped. On a re-run the script finds their Host block
# already present and, correctly, will not clobber a hand-edited file — so those
# developers never pick up the new directives.
#
# The fix, without touching what the developer wrote: SSH merges ALL Host blocks
# that match a host, and treats IdentityFile and RemoteForward as additive
# (every matching value is tried). So a separate, clearly-marked block supplies
# the missing directives and stays trivially removable. We only ever write and
# rewrite OUR block; the developer's is never parsed for editing, only read to
# see which directives are already there.
#
# Marker (alias-scoped, so several boxes in one file never collide):
#   # >>> devbox-managed <alias> >>>
#   Host <alias> <host>
#       <directive>
#   # <<< devbox-managed <alias> <<<
#
# Sourced by scripts/local/bootstrap-devbox.sh and by the test suite.

# Normalise a config line for comparison: strip leading/trailing whitespace,
# collapse internal runs to a single space.
_ssh_norm() { sed -E 's/^[[:space:]]+//; s/[[:space:]]+/ /g; s/[[:space:]]+$//'; }

# Emit the directive lines from the HAND-WRITTEN Host blocks that match the
# alias or host. The managed block (if any) is stripped first, so our own
# additions never count as "already present". Only matching blocks are scanned,
# so an identical-looking directive under a different box does not suppress ours.
# Args: <alias> <host>   Reads config text on stdin.
_ssh_matching_directives() {
    awk -v al="$1" -v ho="$2" '
        BEGIN { inmanaged=0; inblk=0 }
        /^[[:space:]]*#[[:space:]]*>>>[[:space:]]*devbox-managed/ { inmanaged=1; next }
        /^[[:space:]]*#[[:space:]]*<<<[[:space:]]*devbox-managed/ { inmanaged=0; next }
        inmanaged { next }
        {
            line=$0
            hdr=line; sub(/^[[:space:]]+/,"",hdr)
            if (hdr ~ /^[Hh][Oo][Ss][Tt][[:space:]]/) {
                inblk=0
                n=split(hdr, f, /[[:space:]]+/)
                for (i=2;i<=n;i++) if (f[i]==al || f[i]==ho) inblk=1
                next
            }
            if (hdr ~ /^[Mm][Aa][Tt][Cc][Hh][[:space:]]/) { inblk=0; next }
            if (inblk && hdr !~ /^#/ && hdr ~ /[^[:space:]]/) print line
        }
    '
}

# Print the directive lines that SHOULD be in the managed block: each desired
# directive (IdentityFile for the key, and the tunnel line if one is given) that
# is not already present in a hand-written matching block. Empty output means
# there is nothing to add. Deterministic order: IdentityFile, then RemoteForward.
# Args: <cfg> <alias> <host> <key> <tunnel_line>
ssh_managed_missing() {
    local cfg="$1" alias="$2" host="$3" key="$4" tunnel="$5"
    local present desired norm
    present="$(_ssh_matching_directives "$alias" "$host" <"$cfg" | _ssh_norm)"

    if [[ -n "$key" ]]; then
        desired="$(printf 'IdentityFile %s' "$key")"
        norm="$(printf '%s' "$desired" | _ssh_norm)"
        grep -qxF "$norm" <<<"$present" || printf 'IdentityFile %s\n' "$key"
    fi
    if [[ -n "$tunnel" ]]; then
        norm="$(printf '%s' "$tunnel" | _ssh_norm)"
        grep -qxF "$norm" <<<"$present" || printf '%s\n' "$tunnel"
    fi
}

# Remove any existing managed block for the alias, then — if directive lines are
# supplied on stdin — append a fresh one. Rewriting wholesale (we own the marked
# span) keeps re-runs idempotent and lets the block self-heal to nothing once the
# developer folds the directives into their own block.
# Args: <cfg> <alias> <host>   Reads directive lines on stdin.
ssh_write_managed_block() {
    local cfg="$1" alias="$2" host="$3"
    local directives tmp
    directives="$(cat)"

    tmp="$(mktemp)"
    # Drop the old managed block (inclusive of both markers) for THIS alias only.
    awk -v al="$alias" '
        $0 ~ ("^[[:space:]]*#[[:space:]]*>>>[[:space:]]*devbox-managed[[:space:]]+" al "[[:space:]]*>>>") { skip=1; next }
        skip && $0 ~ ("^[[:space:]]*#[[:space:]]*<<<[[:space:]]*devbox-managed[[:space:]]+" al "[[:space:]]*<<<") { skip=0; next }
        skip { next }
        { print }
    ' "$cfg" >"$tmp"

    # Trim a trailing run of blank lines so re-runs do not accumulate whitespace.
    sed -e :a -e '/^\n*$/{$d;N;ba}' "$tmp" >"$cfg"

    if [[ -n "$directives" ]]; then
        {
            printf '\n# >>> devbox-managed %s >>>\n' "$alias"
            printf '# Added by bootstrap-devbox so a re-run can supply directives your\n'
            printf '# original block predates. Safe to delete; SSH merges it additively.\n'
            printf 'Host %s %s\n' "$alias" "$host"
            printf '%s\n' "$directives" | while IFS= read -r d; do
                [[ -n "$d" ]] && printf '    %s\n' "$d"
            done
            printf '# <<< devbox-managed %s <<<\n' "$alias"
        } >>"$cfg"
    fi
    rm -f "$tmp"
}

# --- Agent-forwarding policy (issue #86) --------------------------------------
# The box account is shared and everyone on it has sudo, so a forwarded agent is
# usable by every colleague for the life of the session. Forwarding is therefore
# OFF unless the developer asks for it, and a request that cannot be honoured as
# asked degrades to "no" — never silently to "yes".

# Decide the ForwardAgent value.
# Args: <mode> <scoped_sock> <ssh_major> <ssh_minor>
#   mode: "" or no (default) | scoped (SCOPE_AGENT=true) | all (FORWARD_AGENT=all)
#   scoped_sock: socket path of the scoped agent (used only for mode=scoped)
# Prints: no | yes | <socket path>
ssh_forward_value() {
    local mode="${1:-no}" sock="${2:-}" major="${3:-0}" minor="${4:-0}"
    case "$mode" in
        all) echo "yes" ;;
        scoped)
            if [[ -n "$sock" ]] && (( major > 8 || (major == 8 && minor >= 9) )); then
                echo "$sock"
            else
                echo "no"
            fi ;;
        *) echo "no" ;;
    esac
}

# Emit a fresh Host block. The local-model tunnel line is included only when the
# caller passes one (the tunnel is opt-in: LOCAL_MODEL_TUNNEL=true).
# Args: <alias> <host> <hostname> <user> <key> <forward_value> [tunnel_line]
ssh_host_block() {
    printf '\nHost %s %s\n' "$1" "$2"
    printf '  HostName %s\n' "$3"
    printf '  User %s\n' "$4"
    printf '  IdentityFile %s\n' "$5"
    printf '  ForwardAgent %s\n' "$6"
    if [[ -n "${7:-}" ]]; then printf '%s\n' "$7"; fi
}

# Report risky directives already in the developer's own Host block for this box,
# so a re-run can warn about defaults this script no longer writes.
# Args: <alias> <host>   Reads config text on stdin.
# Prints one finding per line: "ForwardAgent yes" and/or the RemoteForward line.
ssh_risky_directives() {
    _ssh_matching_directives "$1" "$2" | _ssh_norm | awk '
        tolower($1)=="forwardagent" && tolower($2)=="yes" { print "ForwardAgent yes" }
        tolower($1)=="remoteforward"                     { print }
    '
}
