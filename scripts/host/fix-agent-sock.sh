#!/usr/bin/env bash
# fix-agent-sock.sh — repair a stale SSH_AUTH_SOCK after a Remote-SSH reconnect.
#
# The editor points SSH_AUTH_SOCK at a symlink under the user's runtime dir,
# which targets an agent socket in /tmp. When a connection drops, that agent
# dies; the reconnect creates a NEW one under a different /tmp directory, but
# shells opened before the reconnect keep the old path. The symptom is:
#
#     Error connecting to agent: No such file or directory
#
# and it breaks anything that needs the forwarded key — git over SSH, and the
# infrastructure tool, which mounts SSH_AUTH_SOCK into its container.
#
# On a SHARED account, every connected developer's forwarded agent lives in /tmp
# owned by the same user. Picking "the newest socket" would attach you to
# whichever colleague reconnected last, and you would authenticate as them. So
# this script never guesses: it walks up THIS shell's own process tree to the
# sshd that owns the session, and reads the socket path from that process's
# environment. Only your own session can be found this way.
#
# Usage — must be evaluated, since a child process cannot export into its parent:
#     eval "$(bash scripts/host/fix-agent-sock.sh)"
#     ssh-add -l
#
# Prints nothing but an export line on success; diagnostics go to stderr.
set -uo pipefail

say() { echo "$*" >&2; }

# Already working? Do nothing rather than reattach for no reason.
if [[ -n "${SSH_AUTH_SOCK:-}" ]] && [[ -S "$SSH_AUTH_SOCK" ]] && ssh-add -l >/dev/null 2>&1; then
    say "agent already reachable at $SSH_AUTH_SOCK — no change"
    exit 0
fi

if [[ -n "${SSH_AUTH_SOCK:-}" ]]; then
    say "current SSH_AUTH_SOCK is unusable: $SSH_AUTH_SOCK"
    [[ -L "$SSH_AUTH_SOCK" ]] && say "  (dangling symlink -> $(readlink "$SSH_AUTH_SOCK" 2>/dev/null))"
else
    say "SSH_AUTH_SOCK is unset"
fi

# Walk this shell's ancestry to the owning sshd and read its environment.
_pid="${PPID:-$$}"
_found=""
for _ in $(seq 1 20); do
    [[ -z "$_pid" || "$_pid" -le 1 ]] && break
    _comm="$(cat "/proc/$_pid/comm" 2>/dev/null)"
    if [[ "$_comm" == sshd* ]]; then
        # Same-uid process, so this is readable; NUL-separated environment.
        _sock="$(tr '\0' '\n' < "/proc/$_pid/environ" 2>/dev/null \
                 | sed -n 's/^SSH_AUTH_SOCK=//p' | head -1)"
        if [[ -n "$_sock" && -S "$_sock" ]]; then _found="$_sock"; break; fi
    fi
    _pid="$(awk '{print $4}' "/proc/$_pid/stat" 2>/dev/null)"
done

if [[ -z "$_found" ]]; then
    say "could not find a forwarded agent belonging to THIS session."
    say "that usually means the connection itself carries no agent:"
    say "  - reconnect with agent forwarding (ssh -A / ForwardAgent)"
    say "  - in the editor, check remote.SSH.enableAgentForwarding and useExecServer"
    say "do NOT attach to a socket under /tmp/ssh-*/ that this script did not find:"
    say "  on a shared account those may belong to other developers."
    exit 1
fi

if ! SSH_AUTH_SOCK="$_found" ssh-add -l >/dev/null 2>&1; then
    say "found $_found but it holds no usable keys — add your key on the client and reconnect"
    exit 1
fi

say "found this session's agent: $_found"
say "keys:"
SSH_AUTH_SOCK="$_found" ssh-add -l 2>/dev/null | sed 's/^/  /' >&2

# Repair the editor's symlink too, so other terminals in this window and any
# tooling that mounts the socket path both recover. Best-effort.
if [[ -n "${SSH_AUTH_SOCK:-}" && -L "$SSH_AUTH_SOCK" && ! -e "$SSH_AUTH_SOCK" ]]; then
    if ln -sf "$_found" "$SSH_AUTH_SOCK" 2>/dev/null; then
        say "repaired symlink $SSH_AUTH_SOCK -> $_found"
    fi
fi

echo "export SSH_AUTH_SOCK='$_found'"
