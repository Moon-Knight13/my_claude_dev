#!/usr/bin/env bash
# scaffold-project.sh — create a T3-compatible project with security hooks
# templated from my_claude_dev.
#
# Usage: scaffold-project.sh <project-name> <default-mode> <workspace-path>
# Example: scaffold-project.sh ctf ctf ~/ctf
#
# Idempotent: safe to re-run. Updates configs, preserves custom files.
set -euo pipefail

# ── Args ───────────────────────────────────────────────────────────────────
PROJECT_NAME="${1:?Usage: scaffold-project.sh <project-name> <default-mode> <workspace-path>}"
DEFAULT_MODE="${2:?Usage: scaffold-project.sh <project-name> <default-mode> <workspace-path>}"
WORKSPACE_PATH="${3:?Usage: scaffold-project.sh <project-name> <default-mode> <workspace-path>}"

# Expand ~ in path
WORKSPACE_PATH="${WORKSPACE_PATH/#\~/$HOME}"

# Framework source (my_claude_dev root)
FRAMEWORK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Supported modes
SUPPORTED_MODES=(ctf dev pentest research)

validate_mode() {
    local mode="$1"
    for m in "${SUPPORTED_MODES[@]}"; do
        [[ "$m" == "$mode" ]] && return 0
    done
    echo "ERROR: unsupported mode '$mode'. Supported: ${SUPPORTED_MODES[*]}" >&2
    return 1
}

validate_mode "$DEFAULT_MODE"

# ── Workspace + git ────────────────────────────────────────────────────────
echo "=== Creating workspace: $WORKSPACE_PATH ==="

mkdir -p "$WORKSPACE_PATH"

if [[ ! -d "$WORKSPACE_PATH/.git" ]]; then
    git -C "$WORKSPACE_PATH" init
    echo "  git repo initialized"
else
    echo "  git repo exists, skipping init"
fi

# ── Directory structure ────────────────────────────────────────────────────
echo "=== Creating directory structure ==="

mkdir -p "$WORKSPACE_PATH/.claude/hooks"
mkdir -p "$WORKSPACE_PATH/.claude/audit"
mkdir -p "$WORKSPACE_PATH/scripts/hooks"

for mode in "${SUPPORTED_MODES[@]}"; do
    mkdir -p "$WORKSPACE_PATH/.claude/modes/$mode"
done

echo "  directories created"

# ── Copy universal hook scripts ────────────────────────────────────────────
echo "=== Copying hook scripts ==="

# .claude/hooks/ — mode-tool-gate is universal
cp "$FRAMEWORK_DIR/.claude/hooks/mode-tool-gate.sh" "$WORKSPACE_PATH/.claude/hooks/mode-tool-gate.sh"
chmod +x "$WORKSPACE_PATH/.claude/hooks/mode-tool-gate.sh"
echo "  .claude/hooks/mode-tool-gate.sh"

# scripts/hooks/ — universal hooks
for hook in audit-trail.sh mode-inject.sh secret-scan.sh response-scanner.sh; do
    cp "$FRAMEWORK_DIR/scripts/hooks/$hook" "$WORKSPACE_PATH/scripts/hooks/$hook"
    chmod +x "$WORKSPACE_PATH/scripts/hooks/$hook"
    echo "  scripts/hooks/$hook"
done

# ── Generate tool-policy.yaml per mode ─────────────────────────────────────
echo "=== Generating mode configs ==="

generate_tool_policy() {
    local mode="$1"
    local outfile="$WORKSPACE_PATH/.claude/modes/$mode/tool-policy.yaml"

    case "$mode" in
        ctf)
            cat > "$outfile" <<'YAML'
# ctf mode — CTF challenges and security competitions.
# Offensive research MCPs allowed. No range or C2 tools.
deny:
  - "mcp__tuoni-mcp__*"
  - "mcp__range-intel__*"
  - "mcp__outline-readonly__*"
YAML
            ;;
        dev)
            cat > "$outfile" <<'YAML'
# dev mode — general software development.
# Minimal security MCPs. No offensive or range tools.
deny:
  - "mcp__tuoni-mcp__*"
  - "mcp__range-intel__*"
  - "mcp__outline-readonly__*"
  - "mcp__hacktricks-mcp__*"
  - "mcp__lolbins-mcp__*"
  - "mcp__mitre-mcp__*"
YAML
            ;;
        pentest)
            cat > "$outfile" <<'YAML'
# pentest mode — authorized penetration testing.
# Full offensive research MCPs. No range or C2 tools.
deny:
  - "mcp__tuoni-mcp__*"
  - "mcp__range-intel__*"
  - "mcp__outline-readonly__*"
YAML
            ;;
        research)
            cat > "$outfile" <<'YAML'
# research mode — security research and analysis.
# Reference MCPs allowed. No offensive execution tools.
deny:
  - "mcp__tuoni-mcp__*"
  - "mcp__range-intel__*"
  - "mcp__outline-readonly__*"
  - "mcp__lolbins-mcp__*"
  - "mcp__rea-mcp__*"
YAML
            ;;
    esac

    echo "  .claude/modes/$mode/tool-policy.yaml"
}

generate_system_prompt() {
    local mode="$1"
    local outfile="$WORKSPACE_PATH/.claude/modes/$mode/system-prompt.md"

    case "$mode" in
        ctf)
            cat > "$outfile" <<'MD'

## Active Mode: ctf

CTF challenges and security competitions. Authorized puzzle-solving context.

### What this mode is for
- Capture the flag challenges and competitions
- Binary exploitation, reverse engineering, crypto, forensics, web exploitation
- Security puzzles and wargames
- Learning and practicing offensive security techniques

### What this mode is NOT for
- Authorized penetration testing of real systems (use pentest)
- Production software development (use dev)
- Academic security research and analysis (use research)

### Available tools
- CVE research (cve-mcp)
- MITRE ATT&CK mapping (mitre-mcp)
- HackTricks references (hacktricks-mcp)
- LOLBins/LOLBas techniques (lolbins-mcp)
- Binary analysis (rea-mcp)
- Notes and knowledge base (obsidian-mcp)
- All standard development tools (git, bash, python)

### Rules
- Document solutions with methodology notes
- Flag format validation before submission
- No attacking infrastructure outside the challenge scope
MD
            ;;
        dev)
            cat > "$outfile" <<'MD'

## Active Mode: dev

General software development. No offensive tools loaded.

### What this mode is for
- Application development, feature work, bug fixes
- Code review and refactoring
- Testing and CI/CD pipeline work
- Documentation and technical writing

### What this mode is NOT for
- Security competitions (use ctf)
- Penetration testing (use pentest)
- Security research (use research)

### Available tools
- CVE research for dependency audit (cve-mcp)
- Binary analysis for debugging (rea-mcp)
- Notes and knowledge base (obsidian-mcp)
- Local model assistance (local-ollama)
- All standard development tools (git, npm, bash, python)

### Rules
- Quality gates before merge: linting, tests, type checks
- No secrets in repository files
- Security-first: validate inputs, sanitize outputs
MD
            ;;
        pentest)
            cat > "$outfile" <<'MD'

## Active Mode: pentest

Authorized penetration testing. Requires explicit scope and authorization.

### What this mode is for
- Authorized penetration testing engagements
- Vulnerability assessment of in-scope targets
- Security auditing with written authorization
- Report writing and finding documentation

### What this mode is NOT for
- CTF challenges (use ctf)
- General development (use dev)
- Academic research without live targets (use research)

### Available tools
- CVE research (cve-mcp)
- MITRE ATT&CK mapping (mitre-mcp)
- HackTricks references (hacktricks-mcp)
- LOLBins/LOLBas techniques (lolbins-mcp)
- Binary analysis (rea-mcp)
- Notes and knowledge base (obsidian-mcp)
- All standard development tools (git, bash, python)

### Rules
- Verify authorization scope before any active testing
- Document all findings with evidence
- No actions outside authorized scope
- Credential handling: store securely, never in repo files
MD
            ;;
        research)
            cat > "$outfile" <<'MD'

## Active Mode: research

Security research and analysis. Reference-heavy, no live execution tools.

### What this mode is for
- CVE analysis and vulnerability research
- Threat intelligence and MITRE ATT&CK mapping
- Security architecture review
- Technical writing and documentation
- Learning and knowledge building

### What this mode is NOT for
- Live exploitation (use ctf or pentest)
- Binary reverse engineering (use ctf)
- General development (use dev)

### Available tools
- CVE research (cve-mcp)
- MITRE ATT&CK mapping (mitre-mcp)
- HackTricks references (hacktricks-mcp)
- Notes and knowledge base (obsidian-mcp)
- Local model assistance (local-ollama)
- All standard development tools (git, bash, python)

### Rules
- Cite sources for findings
- Validate CVE data against multiple sources
- No live exploitation or active scanning
MD
            ;;
    esac

    echo "  .claude/modes/$mode/system-prompt.md"
}

for mode in "${SUPPORTED_MODES[@]}"; do
    generate_tool_policy "$mode"
    generate_system_prompt "$mode"
done

# ── Set active mode ────────────────────────────────────────────────────────
echo "$DEFAULT_MODE" > "$WORKSPACE_PATH/.claude/.active-mode"
echo "  active mode set to: $DEFAULT_MODE"

# ── Generate settings.json ─────────────────────────────────────────────────
echo "=== Generating .claude/settings.json ==="

cat > "$WORKSPACE_PATH/.claude/settings.json" <<'JSON'
{
  "_comment": "Scaffolded from my_claude_dev framework. Hooks use $CLAUDE_PROJECT_DIR for portability.",
  "hooks": {
    "UserPromptSubmit": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "$CLAUDE_PROJECT_DIR/scripts/hooks/secret-scan.sh"
          },
          {
            "type": "command",
            "command": "$CLAUDE_PROJECT_DIR/scripts/hooks/mode-inject.sh"
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "$CLAUDE_PROJECT_DIR/scripts/hooks/audit-trail.sh"
          },
          {
            "type": "command",
            "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/mode-tool-gate.sh"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "$CLAUDE_PROJECT_DIR/scripts/hooks/response-scanner.sh"
          }
        ]
      }
    ]
  }
}
JSON

echo "  .claude/settings.json written"

# ── Generate CLAUDE.md ─────────────────────────────────────────────────────
echo "=== Generating CLAUDE.md ==="

cat > "$WORKSPACE_PATH/CLAUDE.md" <<EOF
# Claude Workflow Contract — $PROJECT_NAME

Scaffolded from [my_claude_dev](https://github.com/MoonKnight13/my_claude_dev) framework.

## Priority Order
1. Security
2. Correctness
3. Maintainability
4. Delivery speed
5. Token efficiency

## Modes

Active mode is stored in \`.claude/.active-mode\`. Switch with \`/mode\`.

Available modes: ${SUPPORTED_MODES[*]}

Default mode: $DEFAULT_MODE

## Guardrails
- Never place credentials or tokens in repository files.
- Run quality checks before merge.
- All tool calls are audit-logged to \`.claude/audit/tool-calls.jsonl\`.
- Prompts are scanned for secrets before reaching the model.
- Tool responses are scanned for leaked credentials.
- Mode-based tool gating enforces MCP deny lists per mode.

## Hook Architecture

Hooks run via \$CLAUDE_PROJECT_DIR-relative paths:

| Hook | Phase | Purpose |
|------|-------|---------|
| secret-scan.sh | UserPromptSubmit | Block secrets in prompts |
| mode-inject.sh | UserPromptSubmit | Inject mode system prompt |
| audit-trail.sh | PreToolUse | Log all tool calls |
| mode-tool-gate.sh | PreToolUse | Enforce mode MCP deny list |
| response-scanner.sh | PostToolUse | Warn on secrets in responses |

## Style
Default response style should be concise and precise.
EOF

echo "  CLAUDE.md written"

# ── Generate .gitignore ────────────────────────────────────────────────────
if [[ ! -f "$WORKSPACE_PATH/.gitignore" ]]; then
    cat > "$WORKSPACE_PATH/.gitignore" <<'GITIGNORE'
# Secrets
.env
*.pem
*.key
*.keystore

# Audit logs (local only)
.claude/audit/

# OS
.DS_Store
Thumbs.db
GITIGNORE
    echo "  .gitignore written"
fi

# ── Validate scaffold ──────────────────────────────────────────────────────
echo ""
echo "=== Validating scaffold ==="

ERRORS=0

# Check all hook scripts exist and are executable
for hook in \
    "$WORKSPACE_PATH/.claude/hooks/mode-tool-gate.sh" \
    "$WORKSPACE_PATH/scripts/hooks/audit-trail.sh" \
    "$WORKSPACE_PATH/scripts/hooks/mode-inject.sh" \
    "$WORKSPACE_PATH/scripts/hooks/secret-scan.sh" \
    "$WORKSPACE_PATH/scripts/hooks/response-scanner.sh"; do
    if [[ ! -x "$hook" ]]; then
        echo "  FAIL: $hook missing or not executable"
        ERRORS=$((ERRORS + 1))
    fi
done

# Check settings.json is valid JSON
if ! python3 -I -c "import json; json.load(open('$WORKSPACE_PATH/.claude/settings.json'))" 2>/dev/null; then
    echo "  FAIL: .claude/settings.json is not valid JSON"
    ERRORS=$((ERRORS + 1))
fi

# Check active mode file
if [[ ! -f "$WORKSPACE_PATH/.claude/.active-mode" ]]; then
    echo "  FAIL: .claude/.active-mode missing"
    ERRORS=$((ERRORS + 1))
fi

# Check mode configs exist for each supported mode
for mode in "${SUPPORTED_MODES[@]}"; do
    if [[ ! -f "$WORKSPACE_PATH/.claude/modes/$mode/tool-policy.yaml" ]]; then
        echo "  FAIL: .claude/modes/$mode/tool-policy.yaml missing"
        ERRORS=$((ERRORS + 1))
    fi
    if [[ ! -f "$WORKSPACE_PATH/.claude/modes/$mode/system-prompt.md" ]]; then
        echo "  FAIL: .claude/modes/$mode/system-prompt.md missing"
        ERRORS=$((ERRORS + 1))
    fi
done

# Check CLAUDE.md
if [[ ! -f "$WORKSPACE_PATH/CLAUDE.md" ]]; then
    echo "  FAIL: CLAUDE.md missing"
    ERRORS=$((ERRORS + 1))
fi

if (( ERRORS > 0 )); then
    echo "  $ERRORS validation error(s) found"
    exit 1
fi

echo "  All checks passed"

# ── Summary ────────────────────────────────────────────────────────────────
echo ""
echo "=== Scaffold complete ==="
echo "  Project:  $PROJECT_NAME"
echo "  Path:     $WORKSPACE_PATH"
echo "  Mode:     $DEFAULT_MODE"
echo ""
echo "  Structure:"
echo "    .claude/"
echo "      settings.json         — hook config"
echo "      .active-mode          — current mode ($DEFAULT_MODE)"
echo "      hooks/"
echo "        mode-tool-gate.sh   — MCP deny list enforcement"
echo "      modes/"
for mode in "${SUPPORTED_MODES[@]}"; do
    echo "        $mode/"
    echo "          tool-policy.yaml"
    echo "          system-prompt.md"
done
echo "      audit/                — tool call logs (gitignored)"
echo "    scripts/"
echo "      hooks/"
echo "        audit-trail.sh      — tool call logging"
echo "        mode-inject.sh      — mode prompt injection"
echo "        secret-scan.sh      — prompt secret scanning"
echo "        response-scanner.sh — response secret scanning"
echo "    CLAUDE.md               — project contract"
echo ""
echo "  Next steps:"
echo "    cd $WORKSPACE_PATH"
echo "    claude                  # start Claude Code in the project"
echo "    /mode $DEFAULT_MODE     # verify mode is active"
