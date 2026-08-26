# Deploying the Dolly Parton tribute webserver

Pure `ansible.builtin` — no collections to install.

```sh
# 1. point inventory.ini at your Ubuntu box
# 2. deploy
ansible-playbook -i inventory.ini deploy-dolly.yml
```

What it does on the target:

- installs `python3`
- creates the `dolly` system user (nologin, no home)
- drops `dolly.py` in `/opt/dolly`
- installs a hardened `dolly.service` systemd unit, enables and starts it
- waits for the page to answer 200 before declaring success

## Knobs

Override in `group_vars/`, the inventory, or with `-e`:

| var                 | default     | notes |
|---------------------|-------------|-------|
| `dolly_bind_host`   | `127.0.0.1` | set `0.0.0.0` to expose it directly |
| `dolly_port`        | `8080`      | keep it >1024; the service is unprivileged |
| `dolly_install_dir` | `/opt/dolly`| |
| `dolly_user`        | `dolly`     | |

```sh
ansible-playbook -i inventory.ini deploy-dolly.yml -e dolly_bind_host=0.0.0.0
```

The role does not touch the firewall. If you expose the port, open it yourself:

```sh
ufw allow 8080/tcp
```

`roles/dolly/files/dolly.py` is a symlink to `examples/dolly.py` — one copy of the
source, no drift.
