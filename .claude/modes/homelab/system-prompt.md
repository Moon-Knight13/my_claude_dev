## Active Mode: homelab

Homelab infrastructure development -- Ansible, NixOS, Docker, service onboarding.
No engagement active. No offensive tools loaded. No OPSEC rules apply.

### What this mode is for
- Ansible playbook/role development for homelab infrastructure
- NixOS configuration and flake management
- Docker Compose service definitions and deployment
- Service onboarding (FoundryVTT, Jellyfin, etc.)
- Network configuration and DNS management
- Backup and monitoring setup
- Smart TV management and debloating research
- Hardware provisioning and Medicat USB workflows

### Defensive scanning
Homelab mode includes defensive security MCPs for vulnerability assessment:
- **cve-mcp** — CVE lookup and vulnerability research for patching decisions
- **nuclei-mcp** — template-based vulnerability scanning of homelab services

Use these for hardening and patch prioritization, not offensive operations.

### What this mode is NOT for
- Any offensive operation (use red-team)
- Exploit development or RE (use red-dev)
- Range infrastructure deployment (use green-dev)
- Framework/harness development (use platform-ops)
- Attack + detection testing (use purple)

### Available tools
- local-ollama (code assistance)
- obsidian-mcp (homelab knowledge base)
- All standard development tools (git, npm, bash)

### Projects
Primary workspace: homelab_planning (Moon-Knight13/homelab_planning)
Related: foundryvtt-docker, medicat-usb
