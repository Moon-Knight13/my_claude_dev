#!/usr/bin/env bash
# bootstrap-devbox.sh — run on the DEVELOPER'S laptop (macOS/Linux; Windows uses
# the .ps1 sibling). Configures local SSH + VSCode Remote-SSH for a MCD
# Deploybox, mirroring the manual developer-setup guide, then hands off to the
# on-box provisioning.
#
# It PROMPTS for per-dev values and secrets and NEVER writes them into the repo:
#   - the SSH key passphrase and the box login password are entered live,
#   - the ~/.ssh/config Host block and the copied *public* key live outside the
#     repo. Nothing sensitive is committed.
#
# Idempotent. Usage:
#   bash scripts/local/bootstrap-devbox.sh
#   DEVBOX_NUM=07 RANGE_USER=jdoe bash scripts/local/bootstrap-devbox.sh   # non-interactive-ish
set -euo pipefail

info() { echo "  ++  $*"; }
note() { echo "  --  $*"; }
warn() { echo "  !!  $*" >&2; }
step() { echo ""; echo ">> $*"; }

# Internal domain is NOT hardcoded (this repo is public). Provide it via the
# DEVBOX_DOMAIN env var or the prompt below.
DOMAIN="${DEVBOX_DOMAIN:-}"
BOX_USER="${DEVBOX_USER:-gt}"
KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519_MCD}"

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

step "MCD Deploybox local bootstrap"

# --- 1. Prompt for per-dev values (never persisted to the repo) --------------
ask DEVBOX_NUM "Deploybox number (e.g. 07)" ""
[[ -z "${DEVBOX_NUM:-}" ]] && { warn "Deploybox number required"; exit 1; }
ask RANGE_USER "Your range username (for the key comment / git identity)" "$(id -un)"
ask DOMAIN "Deploybox domain (e.g. dev.example.net)" ""
[[ -z "${DOMAIN:-}" ]] && { warn "domain required (set DEVBOX_DOMAIN or answer the prompt)"; exit 1; }
ask DEVBOX_IP "Deploybox IP address (blank = use hostname)" ""
HOST="deploybox${DEVBOX_NUM}.${DOMAIN}"
ALIAS="deploybox${DEVBOX_NUM}"
HOSTNAME_VALUE="${DEVBOX_IP:-$HOST}"
info "Target: ${BOX_USER}@${HOST} (HostName ${HOSTNAME_VALUE})"

# --- 2. SSH keypair (reuse or generate) --------------------------------------
step "SSH keypair"
if [[ -f "$KEY" ]]; then
    info "reusing existing key: $KEY"
else
    note "no key at $KEY — generating an ed25519 keypair (you'll set a passphrase)"
    ssh-keygen -t ed25519 -C "MCD_${RANGE_USER}" -f "$KEY"
fi

# --- 3. SSH agent + add key --------------------------------------------------
# The key MUST live in a PERSISTENT agent (your login session), because VSCode
# forwards THAT agent to the box and downstream tools (Catapult/ctp) use the
# forwarded key. We must NOT spawn a throwaway `ssh-agent` here — one started in
# this script dies when the script exits, so your shell/VSCode would forward an
# empty agent and ctp would fail. Detect a real agent instead of creating one.
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
fi

# --- 4. ~/.ssh/config Host block (idempotent; lives outside the repo) ---------
step "SSH config (\$HOME/.ssh/config)"
mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
CFG="$HOME/.ssh/config"
touch "$CFG"; chmod 600 "$CFG"
# Match an existing Host block by FQDN or short alias (catches legacy
# combined-format entries too) so a re-run never appends a duplicate.
esc_host="${HOST//./\\.}"
if grep -qiE "^[[:space:]]*Host[[:space:]]([^#]*[[:space:]])?(${ALIAS}|${esc_host})([[:space:]]|$)" "$CFG"; then
    info "Host entry for ${HOST} already in $CFG — leaving it as-is"
else
    {
        echo ""
        echo "Host ${HOST}"
        echo "  HostName ${HOSTNAME_VALUE}"
        echo "  User ${BOX_USER}"
        echo "  ForwardAgent yes"
    } >> "$CFG"
    info "added Host '${HOST}' -> ${BOX_USER}@${HOSTNAME_VALUE} (ForwardAgent yes)"
fi

# --- 5. Copy public key for passwordless login (prompts for password once) ---
step "Passwordless login (ssh-copy-id)"
note "you'll be asked for your Deploybox login password ONCE (entered live, never stored)"
if command -v ssh-copy-id >/dev/null 2>&1; then
    ssh-copy-id "${BOX_USER}@${HOST}" || warn "ssh-copy-id failed — you can add ${KEY}.pub to ${BOX_USER}:~/.ssh/authorized_keys manually"
else
    warn "ssh-copy-id not found — append this to ${BOX_USER}@${HOST}:~/.ssh/authorized_keys:"
    cat "${KEY}.pub"
fi

# --- 6. Local VSCode: Remote-SSH extension + useExecServer=false -------------
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
        US_PATH="$US" python3 - <<'PY'
import json, os, sys
p = os.environ["US_PATH"]
try:
    d = json.load(open(p))
    assert isinstance(d, dict)
except Exception:
    print(f"  !!  {p} not valid JSON; set remote.SSH.useExecServer=false + "
          "remote.SSH.enableAgentForwarding=true by hand", file=sys.stderr); sys.exit(0)
desired = {
    "remote.SSH.useExecServer": False,       # guide-mandated
    "remote.SSH.enableAgentForwarding": True, # forward the agent to the box (-A)
}
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
else
    note "VSCode 'code' CLI not on PATH — install Remote-SSH from the Marketplace and set remote.SSH.useExecServer=false"
fi

# --- 7. GitLab key reminder (manual browser step) ----------------------------
step "GitLab key (one-time, manual)"
cat <<EOF
  --  Add your PUBLIC key to GitLab so you can clone/pull/push:
        1) copy:  cat ${KEY}.pub
        2) paste at: https://git.${DOMAIN}/-/user_settings/ssh_keys
        3) test:  ssh -T git@git.${DOMAIN} -p 10022   (expects: Welcome to GitLab, @you!)
EOF

# --- 8. Connect + provision (pull-after-connect) -----------------------------
step "Next: connect and provision the box"
cat <<EOF
  Connect with VSCode Remote-SSH (F1 -> "Remote-SSH: Connect to Host" -> ${HOST})
  or from a shell:  ssh ${HOST}

  IMPORTANT — agent forwarding (Catapult/ctp need your FORWARDED key):
    1) This script set VSCode remote.SSH.useExecServer=false. Those settings only
       take effect on a FRESH connection, so fully CLOSE and REOPEN the Remote-SSH
       window after the first connect.
    2) Verify on the box:   ssh-add -l
       You should see your key (comment MCD_${RANGE_USER}). If it says
       "no identities", forwarding is broken — check, in order:
         - key is in your LOCAL agent:              ssh-add -l   (on your laptop)
         - config forwards it:                      grep -A3 '^Host ${HOST}' ~/.ssh/config
         - VSCode remote.SSH.useExecServer is off   (then reconnect)
         - the box permits it:                      sshd -T | grep allowagentforwarding

  Then ON THE BOX, clone this repo (if not already) and run:
      git clone https://github.com/Moon-Knight13/my_claude_dev
      cd my_claude_dev
      sudo bash scripts/host/provision-remote-box.sh

  That installs the killswitch, Claude + Ansible extensions, caveman, and plugins.
  Finally run 'make start' to configure Catapult (uses your GitLab/VPN password
  interactively — that secret is never stored by these scripts).
EOF
info "local bootstrap complete"
