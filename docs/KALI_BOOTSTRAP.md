# Kali Bootstrap

Ansible playbook and Docker Compose for provisioning a Kali attack box with
Tuoni C2, Java 25, and standard offensive tooling.

## Quick start — Ansible

```bash
# 1. Copy and fill in inventory
cp playbooks/inventory.ini.example playbooks/inventory.ini
# Edit inventory.ini with target host details

# 2. Run the playbook
ansible-playbook -i playbooks/inventory.ini playbooks/kali-bootstrap.yml
```

### What it installs

| Role | What |
|------|------|
| `java` | OpenJDK 25 JRE |
| `offensive-tools` | nmap, netexec, impacket, responder, bloodhound |
| `tuoni` | Tuoni server jar + systemd service (auto-restart) |
| `ssh-keys` | Authorized keys for hub access |

### Variables

Override in `playbooks/vars/tuoni.yml` or per-host in inventory:

| Variable | Default | Description |
|----------|---------|-------------|
| `tuoni_heap_size` | `2G` | JVM max heap |
| `tuoni_install_dir` | `/app` | Jar install path |
| `tuoni_jar_source` | (unset) | Local path to jar for initial deploy |
| `java_package` | `openjdk-25-jre-headless` | Apt package name |
| `ssh_authorized_keys_file` | (empty) | Path to public key file |

## Quick start — Docker Compose

For local dev/testing without a remote Kali box:

```bash
# 1. Place the Tuoni jar (not committed)
cp /path/to/TuoniServerApplication.jar playbooks/files/

# 2. Build and run
cd playbooks
docker compose up -d

# 3. Shell into the container
docker compose exec kali bash
```

Environment variables (`TUONI_PORT`, `TUONI_HEAP_SIZE`) can be set in a `.env`
file next to `docker-compose.yml`.

## Notes

- The Tuoni jar is never committed. Place it manually or configure
  `tuoni_jar_source` to copy from a local path during provisioning.
- `inventory.ini` is gitignored — it contains real host details.
- The playbook is idempotent. Re-running updates packages and restarts
  the Tuoni service only when configuration changes.
