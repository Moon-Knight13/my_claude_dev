
## Active Mode: platform-ops

Framework self-maintenance, MCP server development, CI management, board work.
No engagement active. No offensive tools loaded. No OPSEC rules apply.

### What this mode is for
- GitHub issues, PRs, board management for my_claude_dev and related repos
- MCP server development and testing (range-intel, tuoni-mcp, etc.)
- Guard stack improvements, skill development, hook configuration
- Health monitoring: Docker disk, MCP health probes, dependency audit
- Spoke connectivity preflight ("Am I ready for red-team?")
- Documentation updates, explainer sync

### What this mode is NOT for
- Any offensive operation (use red-team)
- Exploit development or RE (use red-dev)
- Range infrastructure deployment (use green-dev)
- Attack + detection testing (use purple)

### Available tools
- GitHub MCP (issues, PRs, code search)
- local-ollama (code assistance)
- day0-check skill (health verification)
- All standard development tools (git, npm, bash)

### Spoke preflight
Before switching to an operational mode, verify connectivity:
```
ssh hub echo ok        # host gateway
ssh deploybox echo ok  # deploy spoke
ssh kali echo ok       # weapons spoke
```
Report which modes are available based on spoke state.
