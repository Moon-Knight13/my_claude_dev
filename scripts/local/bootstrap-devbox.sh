#!/usr/bin/env bash
# bootstrap-devbox.sh — run on the DEVELOPER'S laptop (macOS/Linux; Windows uses
# the .ps1 sibling). Configures local SSH + VSCode Remote-SSH for a remote dev
# box, mirroring the manual developer-setup guide, then hands off to the on-box
# provisioning.
#
# It PROMPTS for per-dev values and secrets and NEVER writes them into the repo:
#   - the SSH key passphrase and the box login password are entered live,
#   - the ~/.ssh/config Host block and the copied *public* key live outside the
#     repo. Nothing sensitive is committed.
#
# SCOPE NOTE — this script writes to the BOX as well as the laptop. The identity
# pin copies your PUBLIC key to the box and appends an ssh_config
# ALIAS block there. It never writes private key material to the box, and never
# adds or edits a default `Host` entry: the box account is shared, and a default
# entry would change behaviour for every other developer on it. An alias block
# applies only when the alias is used, so it is additive and safe.
#
# Idempotent. Usage:
#   bash scripts/local/bootstrap-devbox.sh
# Every site-specific value (domain, host prefix, box account, git host and
# port) is prompted for or read from an env var — this repo is public, so none
# of them are baked in. Pre-set them all to run non-interactively:
#   DEVBOX_DOMAIN=… DEVBOX_PREFIX=… DEVBOX_USER=… DEVBOX_NUM=07 RANGE_USER=jdoe \
#     DEVBOX_GIT_HOST=… DEVBOX_GIT_SSH_PORT=… bash scripts/local/bootstrap-devbox.sh
set -euo pipefail

info() { echo "  ++  $*"; }
note() { echo "  --  $*"; }
warn() { echo "  !!  $*" >&2; }
step() { echo ""; echo ">> $*"; }

# Managed-block helpers for the SSH config (issue #38): let a re-run add
# directives an already-present Host block predates, without editing it.
# shellcheck source=scripts/local/lib/ssh-config.sh disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/ssh-config.sh"

# Site-specific values are NOT hardcoded (this repo is public). Provide each via
# its env var or the prompts below. SSH_KEY overrides the key path if yours
# already lives somewhere else.
DOMAIN="${DEVBOX_DOMAIN:-}"
BOX_USER="${DEVBOX_USER:-}"
HOST_PREFIX="${DEVBOX_PREFIX:-}"
GIT_HOST="${DEVBOX_GIT_HOST:-}"
GIT_SSH_PORT="${DEVBOX_GIT_SSH_PORT:-}"
# Alias used for the pinned git identity on the box. Generic on purpose: it must
# not encode a site name.
GIT_ALIAS="${DEVBOX_GIT_ALIAS:-devbox-git}"

ask() { # ask VAR "prompt" "default"
    local __var="$1" __prompt="$2" __default="${3:-}" __reply
    local __cur="${!__var:-}"
    if [[ -n "$__cur" ]]; then eval "$__var=\$__cur"; return; fi
    if [[ -n "$__default" ]]; then
        printf '  ??  %s [%s]: ' "$__prompt" "$__default"
    else
        printf '  ??  %s: ' "$__prompt"
    fi
    read -r __reply
    eval "$__var=\${__reply:-\$__default}"
}

confirm() { # confirm "question"  -> 0 on yes
    local __reply
    printf '  ??  %s [y/N]: ' "$1"
    read -r __reply
    [[ "$__reply" =~ ^[Yy] ]]
}

sanitise() { # keep only characters that are safe in a filename and a key comment
    printf '%s' "${1//[^A-Za-z0-9._-]/_}"
}

step "Remote dev box local bootstrap"

# --- 1. Prompt for per-dev values (never persisted to the repo) --------------
ask DEVBOX_NUM "Box number (e.g. 07)" ""
[[ -z "${DEVBOX_NUM:-}" ]] && { warn "box number required"; exit 1; }
ask RANGE_USER "Your username on the box (for the key comment / git identity)" "$(id -un)"
ask DOMAIN "Box domain (e.g. dev.example.net)" ""
[[ -z "${DOMAIN:-}" ]] && { warn "domain required (set DEVBOX_DOMAIN or answer the prompt)"; exit 1; }
ask HOST_PREFIX "Box hostname prefix, before the number (e.g. devbox)" ""
[[ -z "${HOST_PREFIX:-}" ]] && { warn "hostname prefix required (set DEVBOX_PREFIX or answer the prompt)"; exit 1; }
ask BOX_USER "Login account on the box (shared account)" ""
[[ -z "${BOX_USER:-}" ]] && { warn "box account required (set DEVBOX_USER or answer the prompt)"; exit 1; }
ask DEVBOX_IP "Box IP address (blank = use hostname)" ""

# Git server details are needed EARLY: the key-selection step below asks the git
# server which of your existing keys it already knows, rather than generating a
# competing one.
ask GIT_HOST "Git server hostname" "git.${DOMAIN}"
[[ -z "${GIT_HOST:-}" ]] && { warn "git server hostname required"; exit 1; }
# No default port. A site on a non-standard SSH port got '22' silently on every
# run, and the wrong port fails in a way that looks like an auth problem.
ask GIT_SSH_PORT "Git server SSH port (OpenSSH default is 22; check your site)" ""
[[ "${GIT_SSH_PORT:-}" =~ ^[0-9]+$ ]] || { warn "git server SSH port required (numeric)"; exit 1; }

HOST="${HOST_PREFIX}${DEVBOX_NUM}.${DOMAIN}"
ALIAS="${HOST_PREFIX}${DEVBOX_NUM}"
HOSTNAME_VALUE="${DEVBOX_IP:-$HOST}"
info "Target: ${BOX_USER}@${HOST} (HostName ${HOSTNAME_VALUE})"

# --- 2. Identity string (one value, everything derives from it) --------------
# <range-user>_<machine>. A developer with two machines otherwise ends up with
# two keys carrying identical comments, indistinguishable in the git server's
# key list and impossible to revoke individually.
step "Identity"
ask MACHINE_NAME "Short name for THIS machine (appears in the key comment)" "$(hostname -s 2>/dev/null || hostname)"
IDENTITY="$(sanitise "${RANGE_USER}_${MACHINE_NAME}")"
[[ -z "$IDENTITY" ]] && { warn "could not build an identity string"; exit 1; }
KEY_COMMENT="${KEY_COMMENT:-$IDENTITY}"
MANAGED_KEY="$HOME/.ssh/id_ed25519_${IDENTITY}"
info "identity: ${IDENTITY}"

# --- 3. SSH keypair — REUSE what the git server already knows ----------------
# Generating unconditionally is what manufactures the fault this script exists
# to prevent: a developer who already holds a registered key gains a second,
# UNREGISTERED identity competing for position in agent order. ssh offers agent
# keys in order and stops at the first the server accepts, so the identity you
# authenticate as becomes emergent rather than declared.
step "SSH keypair"

probe_key() { # probe_key <private-key-path> -> prints the server's greeting
    ssh -o IdentitiesOnly=yes -i "$1" \
        -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
        -p "$GIT_SSH_PORT" -T "git@${GIT_HOST}" 2>&1 | grep -v '^debug' | head -2
}

KEY="${SSH_KEY:-}"
if [[ -n "$KEY" ]]; then
    [[ -f "$KEY" ]] || { warn "SSH_KEY=$KEY does not exist"; exit 1; }
    info "using SSH_KEY override: $KEY"
else
    note "asking ${GIT_HOST} which of your existing keys it already knows"
    mapfile -t CANDIDATES < <(find "$HOME/.ssh" -maxdepth 1 -type f -name '*.pub' 2>/dev/null \
        | sed 's/\.pub$//' | sort)
    for c in "${CANDIDATES[@]:-}"; do
        [[ -f "$c" ]] || continue
        greeting="$(probe_key "$c" || true)"
        if [[ -n "$greeting" ]] && ! grep -qiE 'permission denied|no such identity' <<<"$greeting"; then
            info "$(basename "$c") -> ${greeting%%$'\n'*}"
            if confirm "reuse $(basename "$c") as your git identity?"; then
                KEY="$c"
                break
            fi
        fi
    done
fi

if [[ -z "$KEY" ]]; then
    if [[ -f "$MANAGED_KEY" ]]; then
        info "reusing existing managed key: $MANAGED_KEY"
        KEY="$MANAGED_KEY"
    else
        note "no key that ${GIT_HOST} already accepts — generating one for this machine"
        note "(you will set a passphrase; it is never stored by this script)"
        ssh-keygen -t ed25519 -C "$KEY_COMMENT" -f "$MANAGED_KEY"
        KEY="$MANAGED_KEY"
        NEEDS_REGISTRATION=1
    fi
fi
info "git identity key: $KEY"

# --- 4. SSH agent + add key --------------------------------------------------
# The key MUST live in a PERSISTENT agent (your login session), because VSCode
# forwards THAT agent to the box and the downstream build tooling uses the
# forwarded key. We must NOT spawn a throwaway `ssh-agent` here — one started in
# this script dies when the script exits, so your shell/VSCode would forward an
# empty agent and that tooling would fail. Detect a real agent, don't create one.
step "SSH agent"
ssh-add -l >/dev/null 2>&1; agent_rc=$?   # 0 = keys loaded, 1 = empty agent, 2 = no agent
if [[ "$agent_rc" -eq 2 ]]; then
    warn "no persistent ssh-agent found in this session — NOT starting a throwaway one"
    note "a script-started agent dies on exit and would forward NOTHING to the box."
    note "run this in your OWN login shell, then re-run this script:"
    note "    ssh-add ${KEY}"
    note "  to persist across reboots:"
    note "    macOS:  ssh-add --apple-use-keychain ${KEY}"
    note "    Linux:  ensure your desktop/systemd ssh-agent is running (gnome-keyring/keychain)"
else
    _fp="$(ssh-keygen -lf "$KEY" 2>/dev/null | awk '{print $2}')"
    if [[ -n "$_fp" ]] && ssh-add -l 2>/dev/null | grep -q "$_fp"; then
        info "key already in agent"
    elif [[ "$(uname)" == "Darwin" ]]; then
        ssh-add --apple-use-keychain "$KEY" || warn "could not add key to agent"
    else
        ssh-add "$KEY" || warn "could not add key to agent"
    fi

    # Agent population is not cosmetic: with several keys, WHICH identity you
    # authenticate as is decided by agent order, and a wrong identity
    # authenticates SUCCESSFULLY — nothing surfaces until a push is refused.
    AGENT_KEYS="$(ssh-add -l 2>/dev/null | grep -c . || true)"
    if [[ "${AGENT_KEYS:-0}" -gt 1 ]]; then
        warn "agent holds ${AGENT_KEYS} keys — identity is decided by agent ORDER, not by intent"
        ssh-add -l | sed 's/^/       /'
        note "the verification step below reports which identity the git server actually returns."
        if [[ "${AGENT_KEYS}" -ge 6 ]]; then
            warn "at ${AGENT_KEYS} keys you are at or past the server's usual MaxAuthTries (6):"
            note "each key offered and rejected burns one attempt, so the right key can be"
            note "cut off before it is ever reached. Pinning (below) removes that risk."
        fi
    fi
fi

# --- 5. Agent forwarding (OFF by default; issue #86) ---------------------------
# `ForwardAgent yes` exposes EVERY key in your agent to the box for the life of
# the session. The box account is shared and everyone on it has sudo, so that is
# every colleague. The Host block therefore gets `ForwardAgent no` unless you ask
# for forwarding, and an opt-in that cannot be honoured degrades to `no` — never
# silently to `yes`.
#
# The build tooling on the box authenticates to the hosts it configures through a
# forwarded agent, and which identities those hosts accept is not recorded in this
# repository. If you deploy from this box you need one of the opt-ins:
#   SCOPE_AGENT=true SCOPE_AGENT_KEYS="$HOME/.ssh/k1 …" bash …   # preferred: only listed keys
#       (OpenSSH >= 8.9; on older clients this falls back to NO forwarding)
#   FORWARD_AGENT=all bash …                                      # every agent key — last resort
# For onward hops from your own machine, prefer ProxyJump over forwarding:
#   ssh -J <alias> <next-host>      or  `ProxyJump <alias>` in that host's block
FORWARD_MODE="no"
[[ "${FORWARD_AGENT:-}" == "all" ]] && FORWARD_MODE="all"
[[ "${SCOPE_AGENT:-false}" == "true" ]] && FORWARD_MODE="scoped"
SCOPED_SOCK=""
ssh_major=0; ssh_minor=0
if [[ "$FORWARD_MODE" == "all" ]]; then
    step "Agent forwarding"
    warn "FORWARD_AGENT=all — EVERY key in your agent is usable from the box for the session"
    note "the box account is shared with sudo for all; prefer SCOPE_AGENT=true with SCOPE_AGENT_KEYS"
fi
if [[ "$FORWARD_MODE" == "scoped" ]]; then
    step "Scoped forwarding agent"
    ssh_ver="$(ssh -V 2>&1 | sed -n 's/^OpenSSH_\([0-9]*\)\.\([0-9]*\).*/\1 \2/p')"
    read -r ssh_major ssh_minor <<<"${ssh_ver:-0 0}"
    if (( ssh_major > 8 || (ssh_major == 8 && ssh_minor >= 9) )); then
        SCOPED_SOCK="$HOME/.ssh/agent-${ALIAS}.sock"
        if SSH_AUTH_SOCK="$SCOPED_SOCK" ssh-add -l >/dev/null 2>&1; then
            info "reusing scoped agent at $SCOPED_SOCK"
        else
            rm -f "$SCOPED_SOCK"
            eval "$(ssh-agent -a "$SCOPED_SOCK")" >/dev/null
            info "started scoped agent at $SCOPED_SOCK"
        fi
        for k in "$KEY" ${SCOPE_AGENT_KEYS:-}; do
            [[ -f "$k" ]] || { warn "scoped agent: no key at $k"; continue; }
            SSH_AUTH_SOCK="$SCOPED_SOCK" ssh-add "$k" || warn "could not add $k to scoped agent"
        done
        warn "a socket-bound agent does NOT survive a reboot. Recreate it with:"
        note "    ssh-agent -a ${SCOPED_SOCK} && SSH_AUTH_SOCK=${SCOPED_SOCK} ssh-add ${KEY}"
    else
        warn "OpenSSH $(ssh -V 2>&1) does not accept a socket path for ForwardAgent (needs >= 8.9)"
        note "NOT forwarding any agent ('ForwardAgent no'). Upgrade OpenSSH, or opt in to"
        note "all keys explicitly with FORWARD_AGENT=all if you accept that exposure."
    fi
fi
FORWARD_VALUE="$(ssh_forward_value "$FORWARD_MODE" "$SCOPED_SOCK" "$ssh_major" "$ssh_minor")"

# --- 6. Copy public key for passwordless login (prompts for password once) ---
# Runs BEFORE the Host block is written, addressing the box directly, so the
# tunnel-port probe below can reach it without a second password prompt.
step "Passwordless login (ssh-copy-id)"
BOX_TARGET="${BOX_USER}@${HOSTNAME_VALUE}"
note "you'll be asked for your box login password ONCE (entered live, never stored)"
if command -v ssh-copy-id >/dev/null 2>&1; then
    ssh-copy-id -i "${KEY}.pub" "$BOX_TARGET" || warn "ssh-copy-id failed — you can add ${KEY}.pub to ${BOX_USER}:~/.ssh/authorized_keys manually"
else
    warn "ssh-copy-id not found — append this to ${BOX_TARGET}:~/.ssh/authorized_keys:"
    cat "${KEY}.pub"
fi

# --- 7. Reverse tunnel for the local model endpoint (OPT-IN; issue #86) ------
# Optional: carries THIS machine's model endpoint to the box so local routing
# there has something to call. Under the hub-and-spoke design the models stay on
# the hub and the hub drives the box, so the tunnel is not needed by default.
#
# Exposure: the forwarded port is bound on the box's LOOPBACK only (sshd's
# GatewayPorts defaults to no). It is still reachable by anyone with a shell on
# that box while your session is open — the account is shared, so that is every
# colleague. Nothing authenticates to it. Set LOCAL_MODEL_TUNNEL=true to opt in.
step "Local model tunnel"
TUNNEL_LINE=""
if [[ "${LOCAL_MODEL_TUNNEL:-false}" != "true" ]]; then
    note "no local-model tunnel (opt in with LOCAL_MODEL_TUNNEL=true; unauthenticated to box co-users)"
else
    warn "LOCAL_MODEL_TUNNEL=true — every user on the box can reach your local model while connected"
    ask LOCAL_MODEL_PORT "Local model port on THIS machine" "11434"
    if ! curl --silent --fail --connect-timeout 2 "http://127.0.0.1:${LOCAL_MODEL_PORT}" >/dev/null 2>&1; then
        warn "nothing answers on http://127.0.0.1:${LOCAL_MODEL_PORT} on this machine"
        note "not writing a tunnel to a dead endpoint. Start the model server, then re-run."
        note "the box will keep routing everything to Claude until then."
    else
        REMOTE_MODEL_PORT="${REMOTE_MODEL_PORT:-$LOCAL_MODEL_PORT}"
        # A collision on a shared box is worse than a failed bind: if a colleague
        # already forwards this port, sshd refuses yours and the endpoint that
        # answers on the box is THEIRS — your prompts would leave for another
        # developer's machine. Detect it rather than discover it later.
        probe_remote_port() {
            ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
                "$BOX_TARGET" "ss -ltn 2>/dev/null | awk '{print \$4}' | grep -qE '[:.]${1}\$'" \
                >/dev/null 2>&1
        }
        if probe_remote_port "$REMOTE_MODEL_PORT"; then
            warn "port ${REMOTE_MODEL_PORT} is ALREADY bound on the box"
            note "that is most likely another developer's tunnel. Using it would send your"
            note "prompts to THEIR machine, and your own bind would be refused."
            ask REMOTE_MODEL_PORT_ALT "Different port to use on the box" "$((REMOTE_MODEL_PORT + 1))"
            REMOTE_MODEL_PORT="$REMOTE_MODEL_PORT_ALT"
            if probe_remote_port "$REMOTE_MODEL_PORT"; then
                warn "port ${REMOTE_MODEL_PORT} is also bound — pick one by hand and re-run"
                REMOTE_MODEL_PORT=""
            fi
        fi
        if [[ -n "$REMOTE_MODEL_PORT" ]]; then
            TUNNEL_LINE="  RemoteForward 127.0.0.1:${REMOTE_MODEL_PORT} 127.0.0.1:${LOCAL_MODEL_PORT}"
            info "tunnel: box 127.0.0.1:${REMOTE_MODEL_PORT} -> this machine 127.0.0.1:${LOCAL_MODEL_PORT}"
        fi
    fi
fi

# --- 8. ~/.ssh/config Host block (idempotent; lives outside the repo) ---------
step "SSH config (\$HOME/.ssh/config)"
mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
CFG="$HOME/.ssh/config"
touch "$CFG"; chmod 600 "$CFG"
# Match an existing Host block by FQDN or short alias (catches legacy
# combined-format entries too) so a re-run never appends a duplicate.
esc_host="${HOST//./\\.}"
if grep -qiE "^[[:space:]]*Host[[:space:]]([^#]*[[:space:]])?(${ALIAS}|${esc_host})([[:space:]]|$)" "$CFG"; then
    info "Host entry for ${HOST} already in $CFG — leaving your block as-is"
    # Defaults changed (issue #86): flag what an older run may have written.
    RISKY="$(ssh_risky_directives "$ALIAS" "$HOST" <"$CFG")"
    if [[ -n "$RISKY" ]]; then
        warn "your existing block still has directives this script no longer writes by default:"
        printf '%s\n' "$RISKY" | while IFS= read -r d; do note "    $d"; done
        note "edit them out of $CFG (ForwardAgent no; drop RemoteForward) unless you need them"
    fi
    # A re-run must still pick up directives your original block predates
    # (IdentityFile for the box key, RemoteForward for the local-model tunnel)
    # without touching what you wrote. Any gaps go into a separate, clearly-
    # marked block that SSH merges in additively (issue #38).
    MISSING="$(ssh_managed_missing "$CFG" "$ALIAS" "$HOST" "$KEY" "${TUNNEL_LINE#  }")"
    if [[ -n "$MISSING" ]]; then
        note "your block is missing directives this script now sets:"
        printf '%s\n' "$MISSING" | while IFS= read -r d; do note "    $d"; done
        if confirm "add them in a marked 'devbox-managed' block? (your block stays untouched)"; then
            printf '%s\n' "$MISSING" | ssh_write_managed_block "$CFG" "$ALIAS" "$HOST"
            info "wrote devbox-managed block for '${ALIAS}' — delete it any time; SSH merges it"
        else
            note "skipped — add them by hand, or re-run and accept"
        fi
    elif grep -q "devbox-managed ${ALIAS} " "$CFG"; then
        # Nothing missing but a managed block lingers (you folded the directives
        # into your own block): clear ours so the file self-heals.
        printf '' | ssh_write_managed_block "$CFG" "$ALIAS" "$HOST"
        info "removed a now-redundant devbox-managed block for '${ALIAS}'"
    fi
else
    ssh_host_block "$ALIAS" "$HOST" "$HOSTNAME_VALUE" "$BOX_USER" "$KEY" "$FORWARD_VALUE" "$TUNNEL_LINE" >> "$CFG"
    info "added Host '${ALIAS} ${HOST}' -> ${BOX_USER}@${HOSTNAME_VALUE} (ForwardAgent ${FORWARD_VALUE})"
fi

# --- 9. Local VSCode: Remote-SSH extension + useExecServer=false -------------
step "Local VSCode (Remote-SSH)"
if command -v code >/dev/null 2>&1; then
    if code --install-extension ms-vscode-remote.remote-ssh >/dev/null 2>&1; then
        info "Remote-SSH extension present"
    else
        note "could not auto-install Remote-SSH extension"
    fi
    # Set remote.SSH.useExecServer=false in the local User settings (merge).
    US_DIR="$HOME/.config/Code/User"
    [[ "$(uname)" == "Darwin" ]] && US_DIR="$HOME/Library/Application Support/Code/User"
    US="$US_DIR/settings.json"
    if command -v python3 >/dev/null 2>&1; then
        mkdir -p "$US_DIR"; [[ -f "$US" ]] || echo '{}' > "$US"
        # VSCode's agent-forwarding setting is GLOBAL to every Remote-SSH host, so
        # it is only ever switched ON (when the developer opts in to forwarding,
        # issue #86) and never forced off: forcing it off would break forwarding
        # for other hosts the developer deliberately configured. The Host block's
        # `ForwardAgent no` is what keeps this box's default safe.
        FWD_ON="false"; [[ "$FORWARD_VALUE" != "no" ]] && FWD_ON="true"
        US_PATH="$US" FWD_ON="$FWD_ON" python3 - <<'PY'
import json, os, sys
p = os.environ["US_PATH"]
fwd = os.environ.get("FWD_ON") == "true"
try:
    d = json.load(open(p))
    assert isinstance(d, dict)
except Exception:
    print(f"  !!  {p} not valid JSON; set remote.SSH.useExecServer=false + "
          f"remote.SSH.enableAgentForwarding={'true' if fwd else 'false'} by hand",
          file=sys.stderr); sys.exit(0)
desired = {"remote.SSH.useExecServer": False}  # guide-mandated
if fwd:  # only switched on by an explicit opt-in; never forced off (global setting)
    desired["remote.SSH.enableAgentForwarding"] = True
changed = [k for k, v in desired.items() if d.get(k) is not v]
for k, v in desired.items():
    d[k] = v
if changed:
    json.dump(d, open(p, "w"), indent=2); open(p, "a").write("\n")
    print("  ++  set " + ", ".join(changed))
else:
    print("  --  remote.SSH settings already correct")
PY
    else
        note "python3 missing — set \"remote.SSH.useExecServer\": false in VSCode settings manually"
    fi
    # VSCode can be pointed at a DIFFERENT ssh config, in which case the Host
    # block written above is never read and forwarding silently does not apply.
    if [[ -f "$US" ]] && grep -q 'remote.SSH.configFile' "$US"; then
        warn "remote.SSH.configFile is set in your VSCode settings — it OVERRIDES ~/.ssh/config"
        note "either remove it, or add the Host block above to the file it points at"
    fi
else
    note "VSCode 'code' CLI not on PATH — install Remote-SSH from the Marketplace and set remote.SSH.useExecServer=false"
fi

# --- 10. Register the public key at the git server (manual browser step) ------
step "Git server key (one-time, manual)"
if [[ -n "${NEEDS_REGISTRATION:-}" ]]; then
    warn "this key is NEW and the git server does not know it yet"
else
    note "if you reused a key the server already accepted, this is already done"
fi
cat <<EOF
  --  Add your PUBLIC key to the git server so you can clone/pull/push:
        1) copy:  cat ${KEY}.pub
        2) paste at: https://${GIT_HOST}/-/user_settings/ssh_keys
           (that path is GitLab's; adjust for a different git server)
        3) test:  ssh -T git@${GIT_HOST} -p ${GIT_SSH_PORT}
EOF
confirm "have you registered ${KEY}.pub at ${GIT_HOST}?" || {
    warn "skipping identity verification — re-run this script after registering the key"
    exit 0
}

# --- 11. Verify the identity, and pin ONLY if the box gets it wrong ----------
# A wrong identity authenticates SUCCESSFULLY. Nothing errors until a push is
# refused, so this check is the only thing between you and a confusing failure
# hours later. Verify, then pin only on mismatch: pinning a developer who does
# not need one adds configuration to a shared account for no benefit.
step "Identity verification"
LAPTOP_ID="$( { probe_key "$KEY" || true; } | head -1)"
info "from this machine, pinned to $(basename "$KEY"):"
echo "       ${LAPTOP_ID:-<no response>}"

if [[ "$FORWARD_VALUE" == "no" ]]; then
    # The box-side check authenticates with the FORWARDED agent. With forwarding
    # off (the default, issue #86) it cannot succeed, and a failure here would
    # wrongly suggest pinning. Skip it and say why.
    note "box-side identity check skipped: no agent is forwarded (ForwardAgent no)"
    note "git over SSH from the box needs a forwarded key; re-run with SCOPE_AGENT=true or"
    note "FORWARD_AGENT=all to verify, or use HTTPS remotes on the box"
    BOX_ID="skipped"
else
    BOX_ID="$(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 \
        "${ALIAS}" \
        "ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -p ${GIT_SSH_PORT} -T git@${GIT_HOST} 2>&1 | head -1" \
        2>/dev/null || true)"
    info "from the box, unpinned (whichever key the agent offers first):"
    echo "       ${BOX_ID:-<no response — is the agent forwarded? run scripts/host/diagnose-git-auth.sh on the box>}"
fi

if [[ "$BOX_ID" == "skipped" ]]; then
    :
elif [[ -n "$BOX_ID" && "$BOX_ID" == "$LAPTOP_ID" ]]; then
    info "the box already resolves to the same identity — NO pin needed"
    note "leaving the box's ssh config untouched (it is a shared account)"
else
    warn "the box does NOT resolve to the identity this machine uses"
    note "cause: ssh offers agent keys in order and stops at the first the server accepts."
    note "  Root-cause fix, if available: stop loading the competing key on this machine."
    note "  Identify it by FINGERPRINT, never by filename, and RENAME rather than delete:"
    note "      ssh-keygen -lf ~/.ssh/<name>.pub          # confirm before touching anything"
    note "      cp -a ~/.ssh ~/ssh-backup-\$(date +%F)     # a default identity cannot be regenerated"
    note "  Otherwise, pin on the box: an ALIAS block, public keys only."
    if confirm "write the pinned alias '${GIT_ALIAS}' to ${BOX_USER}@${HOST}:~/.ssh/config?"; then
        scp -q "${KEY}.pub" "${ALIAS}:.ssh/${IDENTITY}.pub" \
            || { warn "could not copy the public key to the box"; exit 1; }
        # Accumulative by design: one IdentityFile per registered machine, each
        # named for that machine, so the registered set is readable from the
        # config alone and a second machine adds exactly one line.
        ssh "${ALIAS}" 'bash -s' -- "$GIT_ALIAS" "$GIT_HOST" "$GIT_SSH_PORT" "$IDENTITY" <<'REMOTE'
set -euo pipefail
alias_name="$1"; git_host="$2"; git_port="$3"; ident="$4"
cfg="$HOME/.ssh/config"
mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
touch "$cfg"; chmod 600 "$cfg"
chmod 644 "$HOME/.ssh/${ident}.pub"
idline="    IdentityFile ~/.ssh/${ident}.pub"
if ! grep -qE "^[[:space:]]*Host[[:space:]]+${alias_name}([[:space:]]|\$)" "$cfg"; then
    printf '\nHost %s\n    HostName %s\n    Port %s\n    User git\n    IdentitiesOnly yes\n%s\n' \
        "$alias_name" "$git_host" "$git_port" "$idline" >> "$cfg"
    echo "  ++  added alias '${alias_name}' with ${ident}"
elif grep -qF "$idline" "$cfg"; then
    echo "  --  alias '${alias_name}' already lists ${ident} — nothing to do"
else
    awk -v a="$alias_name" -v line="$idline" \
        '$0 ~ "^[[:space:]]*Host[[:space:]]+" a "([[:space:]]|$)" { print; print line; next } { print }' \
        "$cfg" > "$cfg.new" && mv "$cfg.new" "$cfg" && chmod 600 "$cfg"
    echo "  ++  added ${ident} to existing alias '${alias_name}'"
fi
REMOTE
        info "pin written. Verifying through the alias:"
        PINNED_ID="$(ssh -o BatchMode=yes "${ALIAS}" \
            "ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -T ${GIT_ALIAS} 2>&1 | head -1" 2>/dev/null || true)"
        echo "       ${PINNED_ID:-<no response>}"
        if [[ -n "$PINNED_ID" && "$PINNED_ID" == "$LAPTOP_ID" ]]; then
            info "the box now resolves to the intended identity"
        else
            warn "the alias did not return the expected identity"
            note "if ${KEY}.pub is not registered at ${GIT_HOST} yet, this is 'not registered',"
            note "not 'pin is wrong'. Register it and re-run. Otherwise:"
            note "    bash scripts/host/diagnose-git-auth.sh   (on the box)"
        fi
        cat <<EOF
  --  To use the pin, point the project's remote at the alias ON THE BOX:
        git remote set-url origin git@${GIT_ALIAS}:<group>/<project>.git
      Not done automatically: the project may not be cloned yet.
      Per-repository alternative that touches no shared file:
        git config core.sshCommand "ssh -i ~/.ssh/${IDENTITY}.pub -o IdentitiesOnly=yes -p ${GIT_SSH_PORT}"
EOF
    else
        note "skipped. Until the identity is fixed, pushes will be attributed to the wrong account."
    fi
fi

# --- 12. Connect + provision (pull-after-connect) ----------------------------
step "Next: connect and provision the box"
cat <<EOF
  Connect with VSCode Remote-SSH (F1 -> "Remote-SSH: Connect to Host" -> ${ALIAS})
  or from a shell:  ssh ${ALIAS}
EOF
if [[ "$FORWARD_VALUE" == "no" ]]; then
cat <<EOF

  Agent forwarding is OFF (ForwardAgent no). The build tooling on the box needs a
  forwarded key to deploy; if you deploy from this box, re-run with ONE of:
    SCOPE_AGENT=true SCOPE_AGENT_KEYS="<keys the tooling needs>" bash $0   (preferred)
    FORWARD_AGENT=all bash $0                                              (every agent key)
  For onward hops from your own machine, use ProxyJump instead:  ssh -J ${ALIAS} <next-host>
EOF
else
cat <<EOF

  IMPORTANT — agent forwarding (the downstream build tooling needs your
  FORWARDED key):
    1) This script set VSCode remote.SSH.useExecServer=false. Those settings only
       take effect on a FRESH connection, so fully CLOSE and REOPEN the Remote-SSH
       window after the first connect.
    2) Verify on the box:   ssh-add -l
       You should see your key (comment ${KEY_COMMENT}). If it says
       "no identities", forwarding is broken — check, in order:
         - key is in your LOCAL agent:              ssh-add -l   (on your laptop)
         - config forwards it:                      grep -A4 '^Host ${ALIAS}' ~/.ssh/config
         - VSCode remote.SSH.useExecServer is off   (then reconnect)
         - the box permits it:                      sshd -T | grep allowagentforwarding
    3) If it says "Error connecting to agent: No such file or directory" AFTER a
       reconnect, the agent socket is stale, not missing. On the box:
                eval "\$(bash scripts/host/fix-agent-sock.sh)"
EOF
fi
cat <<EOF

  Then ON THE BOX, clone this repo (if not already) and run:
      git clone https://github.com/Moon-Knight13/my_claude_dev
      cd my_claude_dev
      sudo bash scripts/host/provision-remote-box.sh --verify-cmd '<command>'

  That installs the killswitch, Claude + Ansible extensions, caveman and plugins,
  sets your git identity, and — given --verify-cmd — proves the build tooling
  actually works before it records the box as provisioned. Without that flag it
  says so rather than claiming a golden state it never checked.
  Finally run 'make start' to configure the downstream build tooling (it prompts
  for a password interactively — that secret is never stored by these scripts).
EOF
info "local bootstrap complete"
