#!/usr/bin/env bash
# setup-ansible-lint.sh — configure Ansible lint (redhat.ansible + Docker
# execution environment) on the remote dev box, matching the documented developer
# setup guide. Applies to a Remote-SSH box (settings go in the VSCode *server*
# Machine scope) or a local install.
#
# Steps: verify the redhat.ansible extension, merge the ansible settings
# (without clobbering existing keys), and ensure Docker prereqs (daemon active +
# user in the docker group). The execution environment runs ansible-lint inside
# a container, so a local ansible-lint on PATH is NOT required.
#
# Idempotent; docker group change is confirm-gated. Usage:
#   bash scripts/host/setup-ansible-lint.sh [--yes]
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$_SCRIPT_DIR/lib/host-common.sh"

for a in "$@"; do [[ "$a" == "--yes" ]] && export ASSUME_YES=1; done

# --- 1. Locate the correct settings.json scope -------------------------------
# Paths and the docker group belong to the DEVELOPER, not to root. This script is
# reached through a sudo-elevated provisioner, and using $HOME there merged the
# settings into /root/.config/Code/User/settings.json — a file no VSCode session
# will ever read — and offered to add *root* to the docker group.
# CLAUDE_TARGET_HOME/USER resolve to the developer whether or not we are elevated.
if [[ -d "$CLAUDE_TARGET_HOME/.vscode-server" ]]; then
    SETTINGS_DIR="$CLAUDE_TARGET_HOME/.vscode-server/data/Machine"
    SCOPE="Remote-SSH (Machine)"
    EXT_GLOB="$CLAUDE_TARGET_HOME/.vscode-server/extensions/redhat.ansible-*"
else
    SETTINGS_DIR="$CLAUDE_TARGET_HOME/.config/Code/User"
    SCOPE="Local (User)"
    EXT_GLOB=""
fi
SETTINGS="$SETTINGS_DIR/settings.json"
host_step "Ansible-lint setup — scope: $SCOPE"

# --- 2. Verify the redhat.ansible extension ----------------------------------
# `code` is not on PATH on a Remote-SSH box; the shim lives under the VSCode
# server directory in the developer's home. Looking only at PATH reported "no
# 'code' CLI" on boxes that had one.
_find_code() {
    if command -v code >/dev/null 2>&1; then command -v code; return 0; fi
    local c="" cand
    for cand in "$CLAUDE_TARGET_HOME"/.vscode-server/bin/*/bin/remote-cli/code; do
        [[ -x "$cand" ]] && c="$cand"
    done
    [[ -n "$c" ]] && { echo "$c"; return 0; }
    return 1
}
CODE_BIN="$(_find_code || true)"

host_step "Checking redhat.ansible extension"
_ext_ok=0
if [[ -n "$EXT_GLOB" ]]; then
    # shellcheck disable=SC2086
    if compgen -G "$EXT_GLOB" >/dev/null 2>&1; then _ext_ok=1; fi
elif [[ -n "$CODE_BIN" ]] && "$CODE_BIN" --list-extensions 2>/dev/null | grep -qi '^redhat.ansible$'; then
    _ext_ok=1
fi
if [[ "$_ext_ok" == "1" ]]; then
    host_info "redhat.ansible present"
else
    host_warn "redhat.ansible not found — attempting install"
    if [[ -n "$CODE_BIN" ]]; then
        if "$CODE_BIN" --install-extension redhat.ansible 2>/dev/null; then
            host_info "installed redhat.ansible"
        else
            host_warn "auto-install failed — install it from the VSCode Extensions view (redhat.ansible)"
        fi
    else
        host_warn "no 'code' CLI found for ${CLAUDE_TARGET_USER} — install redhat.ansible from the VSCode Extensions view"
    fi
fi

# --- 3. Merge the ansible settings (no clobber) via python3 ------------------
host_step "Merging ansible settings into $SETTINGS"
if ! command -v python3 >/dev/null 2>&1; then
    host_warn "python3 not available — cannot safely merge JSON. Add these keys by hand:"
    host_warn '  ansible.validation.enabled, ansible.validation.lint.enabled,'
    host_warn '  ansible.executionEnvironment.enabled, ...containerEngine=docker, files.associations'
    exit 1
fi
mkdir -p "$SETTINGS_DIR"
[[ -f "$SETTINGS" ]] || echo '{}' > "$SETTINGS"

SETTINGS_PATH="$SETTINGS" python3 - <<'PY'
import json, os, sys

path = os.environ["SETTINGS_PATH"]
try:
    with open(path) as f:
        data = json.load(f)
    if not isinstance(data, dict):
        raise ValueError("not an object")
except (json.JSONDecodeError, ValueError) as e:
    print(f"  !!  {path} is not valid JSON ({e}); refusing to touch it.", file=sys.stderr)
    sys.exit(1)
except FileNotFoundError:
    data = {}

desired = {
    "ansible.validation.enabled": True,
    "ansible.validation.lint.enabled": True,
    "ansible.executionEnvironment.enabled": True,
    "ansible.executionEnvironment.containerEngine": "docker",
}
changed = False
for k, v in desired.items():
    if data.get(k) != v:
        data[k] = v
        changed = True

# files.associations: add only our two mappings, keep any the user already has.
assoc = data.get("files.associations")
if not isinstance(assoc, dict):
    assoc = {}
for pat in ("**/tasks/*.yml", "**/meta/*.yml"):
    if assoc.get(pat) != "ansible":
        assoc[pat] = "ansible"
        changed = True
data["files.associations"] = assoc

if changed:
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    print("  ++  ansible settings merged")
else:
    print("  --  ansible settings already present — no change")
PY

# --- 4. Docker prerequisites -------------------------------------------------
host_step "Checking Docker prerequisites"
if ! command -v docker >/dev/null 2>&1; then
    host_warn "docker not installed — install Docker Engine, then re-run (see docs.docker.com)"
elif [[ "$(systemctl is-active docker 2>/dev/null)" != "active" ]]; then
    host_warn "docker daemon not active — start it: sudo systemctl enable --now docker"
else
    host_info "docker present + daemon active"
    if [[ "$CLAUDE_TARGET_USER" == "root" ]]; then
        host_note "target user is root — skipping the docker group step (root already has access)"
    elif id -nG "$CLAUDE_TARGET_USER" | tr ' ' '\n' | grep -qx docker; then
        host_info "${CLAUDE_TARGET_USER} already in 'docker' group"
    elif confirm "add ${CLAUDE_TARGET_USER} to the 'docker' group (root-equivalent; needs reboot to take effect)"; then
        if command -v sudo >/dev/null 2>&1; then
            if sudo usermod -aG docker "$CLAUDE_TARGET_USER"; then
                host_info "added to docker group — REBOOT (or re-login) required to take effect"
            else
                host_warn "usermod failed"
            fi
        else
            host_warn "sudo not available — run: sudo usermod -aG docker $CLAUDE_TARGET_USER"
        fi
    else
        host_note "skipped docker group change"
    fi
    if docker info >/dev/null 2>&1; then
        host_info "docker usable without sudo (docker OK)"
    else
        host_note "docker needs sudo until you reboot/re-login after the group add"
    fi
fi

host_step "Ansible-lint setup complete"
