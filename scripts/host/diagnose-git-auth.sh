#!/usr/bin/env bash
# diagnose-git-auth.sh — find out WHY the box authenticates to the git server as
# the wrong identity (or not at all). Read-only: it changes nothing, ever.
#
# The box reaches the git server with your FORWARDED agent key, not a key on the
# box. That chain has five boundaries and a failure at any one of them looks
# identical from `git push`:
#
#   laptop agent -> ssh forward -> box agent -> ssh key selection -> git server
#
# So this probes each boundary and prints what it found, instead of guessing.
# Site-specific values (git host, SSH port) are prompted or read from the
# environment — this repository is public and hardcodes none of them.
#
# Usage:
#   bash scripts/host/diagnose-git-auth.sh
#   GIT_HOST=git.example.net GIT_SSH_PORT=1234 bash scripts/host/diagnose-git-auth.sh
#   bash scripts/host/diagnose-git-auth.sh /path/to/repo    # check a specific clone
#
# The output names your git host and account. Keep it on the box; do not paste
# it into a public issue or commit it.
set -uo pipefail   # deliberately NOT -e: probes are expected to fail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$_SCRIPT_DIR/lib/host-common.sh"

REPO_DIR="${1:-$PWD}"
VERDICTS=()
verdict() { VERDICTS+=("$*"); }

ask_var() { # ask_var VAR "prompt" "default"
    local __var="$1" __prompt="$2" __default="${3:-}" __reply
    if [[ -n "${!__var:-}" ]]; then return 0; fi
    if [[ ! -t 0 ]]; then printf -v "$__var" '%s' "$__default"; export "${__var?}"; return 0; fi
    if [[ -n "$__default" ]]; then printf '  ??  %s [%s]: ' "$__prompt" "$__default"
    else printf '  ??  %s: ' "$__prompt"; fi
    read -r __reply
    printf -v "$__var" '%s' "${__reply:-$__default}"
    export "${__var?}"
}

# --- 0. Where are we talking to? ---------------------------------------------
host_step "[0/6] Target git server"
ask_var GIT_HOST "Git server hostname (bare hostname, no https://)" ""
if [[ -z "${GIT_HOST:-}" ]]; then
    host_warn "no git host given — set GIT_HOST or answer the prompt"
    exit 2
fi
# A URL pasted from the browser is the obvious thing to give this prompt, and
# accepting it built a target of `git@https://host` that could never
# authenticate — reported as an auth failure, which is a lie about what went
# wrong. Normalise what can be normalised, refuse the rest.
_raw_host="$GIT_HOST"
GIT_HOST="${GIT_HOST#*://}"        # scheme
GIT_HOST="${GIT_HOST#*@}"          # user@
GIT_HOST="${GIT_HOST%%/*}"         # trailing path
if [[ "$GIT_HOST" == *:* ]]; then  # host:port
    GIT_SSH_PORT="${GIT_SSH_PORT:-${GIT_HOST##*:}}"
    GIT_HOST="${GIT_HOST%%:*}"
fi
[[ "$GIT_HOST" != "$_raw_host" ]] && host_note "interpreted '${_raw_host}' as host '${GIT_HOST}'"
if [[ -z "$GIT_HOST" || "$GIT_HOST" =~ [^A-Za-z0-9._-] ]]; then
    host_warn "'${_raw_host}' is not a hostname — give the bare host, e.g. git.example.net"
    exit 2
fi
# No default port. Defaulting to 22 at a site on a non-standard port fails in a
# way that looks exactly like an authentication problem.
ask_var GIT_SSH_PORT "Git server SSH port (OpenSSH default is 22; check your site)" ""
if [[ ! "${GIT_SSH_PORT:-}" =~ ^[0-9]+$ ]]; then
    host_warn "git server SSH port required (numeric)"
    exit 2
fi
host_info "target: git@${GIT_HOST} port ${GIT_SSH_PORT}"

# --- 1. Is an agent forwarded at all? ----------------------------------------
# If forwarding is broken the box silently falls back to key files in the shared
# account's ~/.ssh — which is how you end up authenticating as somebody else.
host_step "[1/6] Forwarded SSH agent"
if [[ -z "${SSH_AUTH_SOCK:-}" ]]; then
    host_fail "SSH_AUTH_SOCK is unset — no agent is forwarded into this session"
    verdict "NO AGENT: reconnect with agent forwarding (ssh -A / ForwardAgent yes, VSCode remote.SSH.useExecServer=false)"
    AGENT_KEYS=""
else
    host_info "SSH_AUTH_SOCK=${SSH_AUTH_SOCK}"

    # A VSCode reconnect leaves the previous connection's path in this shell's
    # environment while a NEW agent is created under a different /tmp directory.
    # The editor's socket is a symlink, so the symptom is a dangling link and
    # "Error connecting to agent: No such file or directory" — not a dead agent.
    if [[ -L "$SSH_AUTH_SOCK" && ! -e "$SSH_AUTH_SOCK" ]]; then
        host_fail "SSH_AUTH_SOCK is a DANGLING symlink -> $(readlink "$SSH_AUTH_SOCK" 2>/dev/null)"
        host_note "the agent it pointed at died; a reconnect created a new one elsewhere"
        _live="$(ls -1t /tmp/ssh-*/agent.* 2>/dev/null | head -5)"
        if [[ -n "$_live" ]]; then
            host_note "agent sockets that DO exist (newest first):"
            printf '%s\n' "$_live" | sed 's/^/        /'
            host_warn "on a shared account these may belong to OTHER developers."
            host_warn "attach only after 'ssh-add -l' shows keys you recognise as yours."
        fi
        verdict "STALE SOCKET PATH: open a new terminal in the current window, or reconnect"
    fi

    AGENT_KEYS="$(ssh-add -l 2>/dev/null)"
    _rc=$?
    if [[ $_rc -eq 2 ]]; then
        host_fail "agent socket present but unreachable (stale forward — reconnect)"
        verdict "STALE AGENT: close the Remote-SSH window fully and reconnect"
        AGENT_KEYS=""
    elif [[ $_rc -eq 1 || -z "$AGENT_KEYS" ]]; then
        host_fail "agent is forwarded but holds NO keys"
        verdict "EMPTY AGENT: on your laptop run ssh-add <your key>, then reconnect"
        AGENT_KEYS=""
    else
        _n="$(printf '%s\n' "$AGENT_KEYS" | grep -c .)"
        host_info "agent holds ${_n} key(s):"
        printf '%s\n' "$AGENT_KEYS" | sed 's/^/        /'
        if (( _n > 1 )); then
            host_note "more than one key: ssh offers them in agent order and the server"
            host_note "accepts the FIRST one it recognises — which may not be your personal key"
            verdict "MULTIPLE AGENT KEYS (${_n}): identity is decided by agent order, not by you"
        fi
    fi
fi

# --- 2. Key material sitting on the box (shared account!) --------------------
# On a shared account these files belong to whoever set them up. If ssh reaches
# for one of these, you push as them.
host_step "[2/6] Key files in this account's ~/.ssh"
_found_local=0
for k in "$HOME"/.ssh/id_*; do
    [[ -f "$k" ]] || continue
    [[ "$k" == *.pub ]] && continue
    _found_local=1
    host_note "$(ssh-keygen -lf "$k" 2>/dev/null || echo "unreadable: $k")"
done
if [[ "$_found_local" == "1" ]]; then
    host_note "these live in a SHARED account home — anyone on this box can use them"
    verdict "LOCAL KEYS PRESENT in ~/.ssh: ssh may prefer one of these over your forwarded key"
else
    host_info "no private keys in ~/.ssh (good — forwarded agent is the only source)"
fi

# --- 3. Does an ssh_config on the box pin an identity? -----------------------
host_step "[3/6] SSH client config for ${GIT_HOST}"
for cfg in "$HOME/.ssh/config" /etc/ssh/ssh_config; do
    [[ -f "$cfg" ]] || continue
    if grep -qiE "^[[:space:]]*Host[[:space:]].*(${GIT_HOST//./\\.}|\*)" "$cfg" 2>/dev/null; then
        host_note "relevant entries in $cfg:"
        grep -iE -A6 "^[[:space:]]*Host[[:space:]].*(${GIT_HOST//./\\.}|\*)" "$cfg" | sed 's/^/        /'
        if grep -qiE '^[[:space:]]*IdentityFile' "$cfg"; then
            verdict "IdentityFile pinned in $cfg: it can override your forwarded agent key"
        fi
        if grep -qiE '^[[:space:]]*IdentitiesOnly[[:space:]]+yes' "$cfg"; then
            verdict "IdentitiesOnly=yes in $cfg: the AGENT IS IGNORED for matching hosts"
        fi
    fi
done

# --- 4. Which key does the server actually accept? ---------------------------
# -v tells us every key offered and the one accepted; the banner tells us who
# the server thinks we are.
host_step "[4/6] Live authentication to ${GIT_HOST}"
_out="$(ssh -v -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
        -p "${GIT_SSH_PORT}" -T "git@${GIT_HOST}" 2>&1)"
_offered="$(printf '%s\n' "$_out" | grep -E 'Offering public key' | sed 's/^debug1: //')"
_accepted="$(printf '%s\n' "$_out" | grep -E 'Server accepts key|Authentications that can continue' | head -3 | sed 's/^debug1: //')"
_banner="$(printf '%s\n' "$_out" | grep -iE 'Welcome to|logged in as|successfully authenticated' | head -2)"

if [[ -n "$_offered" ]]; then
    host_note "keys offered, in order:"
    printf '%s\n' "$_offered" | sed 's/^/        /'
fi
if [[ -n "$_accepted" ]]; then
    host_note "server response:"
    printf '%s\n' "$_accepted" | sed 's/^/        /'
fi
if [[ -n "$_banner" ]]; then
    host_info "server identifies you as:"
    printf '%s\n' "$_banner" | sed 's/^/        /'
    verdict "SERVER IDENTITY: ${_banner}"
else
    host_fail "no identity banner returned — authentication did not succeed"
    printf '%s\n' "$_out" | grep -iE 'permission denied|no supported authentication|connection refused|timed out' \
        | head -3 | sed 's/^/        /'
    verdict "AUTH FAILED against ${GIT_HOST}:${GIT_SSH_PORT}"
fi

# --- 5. What does the repo itself ask for? -----------------------------------
# An HTTPS remote never uses a key at all — a whole class of "wrong key" reports
# is actually a remote-URL problem.
host_step "[5/6] Repository remote and identity ($REPO_DIR)"
if git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    _seen_urls=""
    while read -r _name _url _kind; do
        [[ -z "${_url:-}" ]] && continue
        host_note "remote ${_name} ${_kind:-} -> ${_url}"
        # `git remote -v` prints fetch and push as separate lines. Judging each
        # one repeated every finding verbatim, which reads as two problems.
        case " $_seen_urls " in *" ${_name}=${_url} "*) continue ;; esac
        _seen_urls="$_seen_urls ${_name}=${_url}"
        case "$_url" in
            https://*|http://*)
                _rhost="${_url#*://}"; _rhost="${_rhost#*@}"
                _rhost="${_rhost%%/*}"; _rhost="${_rhost%%:*}"
                if [[ "$_rhost" != "$GIT_HOST" ]]; then
                    # Running the diagnostic from a checkout of some OTHER repo
                    # is normal. Saying "your pushes use a token" about a repo
                    # that was never the subject reads as a finding when it is
                    # not one.
                    host_note "  (${_rhost} is a different server from the one tested — not a finding)"
                else
                    verdict "REMOTE ${_name} IS HTTPS: pushes to ${_rhost} use a token/password, not your SSH key"
                fi ;;
            *"@"*)
                _rhost="${_url#*@}"; _rhost="${_rhost%%:*}"; _rhost="${_rhost%%/*}"
                [[ "$_rhost" != "$GIT_HOST" ]] && \
                    host_note "  (${_rhost} is a different server from the one tested — not a finding)" ;;
        esac
    done < <(git -C "$REPO_DIR" remote -v 2>/dev/null | sort -u)

    _un="$(git -C "$REPO_DIR" config user.name  || true)"
    _ue="$(git -C "$REPO_DIR" config user.email || true)"
    if [[ -z "$_un" || -z "$_ue" ]]; then
        host_fail "git user.name / user.email not set (developer-setup step: git config --global ...)"
        verdict "GIT IDENTITY UNSET: name='${_un}' email='${_ue}' — many servers reject a push whose committer does not match the authenticated user"
    else
        host_info "git identity: ${_un} <${_ue}>"
    fi
else
    host_note "$REPO_DIR is not a git repository — pass a clone path as \$1 to check one"
fi

# --- 6. Verdict ---------------------------------------------------------------
host_step "[6/6] Findings"
if [[ ${#VERDICTS[@]} -eq 0 ]]; then
    host_info "no misconfiguration found along the chain"
else
    for v in "${VERDICTS[@]}"; do host_note "$v"; done
fi
echo ""
host_note "read-only: this script changed nothing"
