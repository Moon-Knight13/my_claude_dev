#!/usr/bin/env bash
# pretooluse-provenance.sh — PreToolUse hook: provenance-based tool verification.
#
# Verifies tool-call provenance before allowing execution of critical and
# sensitive tools. Provenance = session identity + active mode + origin type.
#
# Checks performed:
#   1. Session registration — a file in .claude/sessions/ proves this session
#      was started through a legitimate entry point (start-mode.sh or similar).
#   2. Session freshness — registration must not be stale (max_session_age).
#   3. Mode alignment — critical/sensitive tools require specific modes.
#   4. Destructive command detection — Bash commands matching dangerous patterns
#      get critical-class treatment regardless of tool name.
#
# Provenance metadata is logged to .claude/audit/provenance.jsonl for every
# classified tool call (critical, sensitive, monitored).
#
# Exit protocol:
#   0 + deny JSON  = blocked
#   0 + no output  = no opinion (allow)
#   2              = block (error / fail-closed)
set -euo pipefail
trap 'exit 2' ERR

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
POLICY_FILE="$PROJECT_DIR/.claude/provenance-policy.yaml"
SESSION_DIR="$PROJECT_DIR/.claude/sessions"
AUDIT_DIR="$PROJECT_DIR/.claude/audit"
PROVENANCE_LOG="$AUDIT_DIR/provenance.jsonl"

# No policy file = no provenance enforcement
[[ -f "$POLICY_FILE" ]] || exit 0

mkdir -p "$AUDIT_DIR" 2>/dev/null || true

input="$(cat)"

# Parse with python — handles JSON + YAML + provenance logic in one pass.
python3 -I -c '
import sys, json, os, time, fnmatch, re

def main():
    try:
        data = json.loads(sys.argv[1])
    except Exception:
        return  # unparseable input = no opinion

    policy_file = sys.argv[2]
    session_dir = sys.argv[3]
    provenance_log = sys.argv[4]
    project_dir = sys.argv[5]

    tool_name = data.get("tool_name", "")
    tool_input = data.get("tool_input", {})

    # --- Load policy (lightweight YAML parse, no PyYAML needed) ---------------
    policy = parse_policy(policy_file)
    if not policy:
        return  # no policy = no gate

    # --- Resolve provenance attributes ----------------------------------------
    session_id = os.environ.get("CLAUDE_CODE_SESSION_ID", "")

    # Active mode
    mode = "unknown"
    mode_file = os.path.join(project_dir, ".claude", ".active-mode")
    override_dir = os.path.join(project_dir, ".claude", ".mode-overrides")
    if session_id and os.path.isfile(os.path.join(override_dir, session_id)):
        try:
            with open(os.path.join(override_dir, session_id)) as f:
                mode = f.read().strip()
        except Exception:
            pass
    elif os.path.isfile(mode_file):
        try:
            with open(mode_file) as f:
                mode = f.read().strip()
        except Exception:
            pass

    # Session registration check
    session_registered = False
    session_age = -1
    if session_id and os.path.isdir(session_dir):
        session_file = os.path.join(session_dir, session_id)
        if os.path.isfile(session_file):
            session_registered = True
            try:
                session_age = time.time() - os.path.getmtime(session_file)
            except Exception:
                session_age = -1

    max_age = policy.get("max_session_age", 86400)

    # --- Classify tool call ---------------------------------------------------
    classification = classify_tool(tool_name, tool_input, policy)

    if not classification:
        return  # not in any provenance class

    # --- Log provenance (all classified calls) --------------------------------
    provenance = {
        "t": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "session": session_id[:12] if session_id else "none",
        "mode": mode,
        "tool": tool_name,
        "class": classification,
        "registered": session_registered,
    }
    if session_age >= 0:
        provenance["age_s"] = int(session_age)

    try:
        with open(provenance_log, "a") as f:
            f.write(json.dumps(provenance, separators=(",", ":")) + "\n")
    except Exception:
        pass

    # --- Monitored class: log only, no gate -----------------------------------
    if classification == "monitored":
        return

    # --- Gate: session registration -------------------------------------------
    if not session_id:
        deny("Provenance denied: no session ID. Tool %s requires a registered session. "
             "Start via start-mode.sh or register with: "
             "scripts/hooks/register-session.sh" % tool_name)
        return

    if not session_registered:
        deny("Provenance denied: session %s is not registered. Tool %s requires "
             "a registered session. Register with: "
             "scripts/hooks/register-session.sh" % (session_id[:12], tool_name))
        return

    # --- Gate: session freshness ----------------------------------------------
    if session_age > max_age:
        deny("Provenance denied: session %s is stale (%dh old, max %dh). "
             "Re-register session." % (
                 session_id[:12], int(session_age / 3600), int(max_age / 3600)))
        return

    # --- Gate: mode alignment -------------------------------------------------
    allowed_modes = policy.get(classification + "_modes", [])
    if allowed_modes and mode not in allowed_modes:
        # Check infra bootstrap override — critical tools allowed in platform-ops
        infra_tools = policy.get("critical_infra_bootstrap", [])
        if mode == "platform-ops" and tool_name in infra_tools:
            pass  # allowed: infra bootstrap tool in platform-ops
        else:
            deny("Provenance denied: tool %s (class: %s) not allowed in mode '%s'. "
                 "Allowed modes: %s. Switch with /mode." % (
                     tool_name, classification, mode, ", ".join(allowed_modes)))
            return

    # All checks passed — no output = allow


def classify_tool(tool_name, tool_input, policy):
    """Return 'critical', 'sensitive', 'monitored', or None."""
    # Check destructive Bash patterns first (always critical)
    if tool_name == "Bash":
        cmd = tool_input.get("command", "")
        for pattern in policy.get("destructive_patterns", []):
            try:
                if re.search(pattern, cmd):
                    return "critical"
            except re.error:
                continue

    # Check tool name against policy classes
    for cls in ("critical", "sensitive", "monitored"):
        for pattern in policy.get(cls, []):
            if fnmatch.fnmatch(tool_name, pattern):
                return cls

    return None


def parse_policy(path):
    """Lightweight YAML parser for the flat provenance policy."""
    try:
        with open(path) as f:
            content = f.read()
    except Exception:
        return {}

    policy = {}
    current_key = None
    for line in content.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue

        # Top-level scalar: key: value
        if ":" in stripped and not stripped.startswith("-"):
            key, _, val = stripped.partition(":")
            key = key.strip()
            val = val.strip().strip("\"").strip("'\''")
            if val:
                # Scalar value
                if val.isdigit():
                    policy[key] = int(val)
                else:
                    policy[key] = val
                current_key = None
            else:
                # Start of list
                current_key = key
                policy[current_key] = []
            continue

        # List item
        if stripped.startswith("- ") and current_key is not None:
            item = stripped[2:].strip().strip("\"").strip("'\''")
            policy[current_key].append(item)

    return policy


def deny(reason):
    """Emit deny JSON and exit."""
    out = {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }
    print(json.dumps(out, separators=(",", ":")))


if __name__ == "__main__":
    main()
' "$input" "$POLICY_FILE" "$SESSION_DIR" "$PROVENANCE_LOG" "$PROJECT_DIR" 2>/dev/null

exit 0
