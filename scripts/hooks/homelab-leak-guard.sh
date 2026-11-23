#!/usr/bin/env bash
# homelab-leak-guard.sh — PreToolUse hook: AD-13 context isolation for homelab mode.
#
# Prevents cross-contamination between homelab and range/engagement contexts:
#   1. In homelab mode: warns if tool input contains range-specific patterns
#      (10.10.x.x, 172.21.x.x, dcm/cr14, engagement IDs)
#   2. In any non-homelab mode: warns if committing files that contain homelab
#      private data (10.5.x.x subnet, device hostnames) outside homelab repos
#
# Boundary rules:
#   - Homelab data stays in: homelab_infra, homelab_planning
#   - Range data stays in: my_claude_dev engagement paths
#   - Cross-contamination in either direction triggers a warning
#
# This is a soft guard (warn, not block) because legitimate cross-references
# exist (e.g., documenting network segmentation). The warning gives the
# operator visibility to catch accidental leaks.
#
# Trigger: PreToolUse on Bash, Write, Edit tools
# Mode detection: .claude/.active-mode or per-session override
#
# Exit codes:
#   0 — always (soft guard: warn via notification, never block)
set -euo pipefail

HOOK_INPUT="$(cat)"

# ── Extract tool name ────────────────────────────────────────────────────────
TOOL_NAME="$(printf '%s' "$HOOK_INPUT" | python3 -I -c '
import sys, json
try: print(json.load(sys.stdin).get("tool_name",""))
except: print("")' 2>/dev/null || true)"

# Only check tools that write or execute
case "$TOOL_NAME" in
    Bash|Write|Edit) ;;
    *) exit 0 ;;
esac

# ── Detect active mode ───────────────────────────────────────────────────────
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-.}"
SESSION_ID="${CLAUDE_CODE_SESSION_ID:-}"
ACTIVE_MODE=""

# Per-session override takes precedence
if [[ -n "$SESSION_ID" && -f "$PROJECT_DIR/.claude/.mode-overrides/$SESSION_ID" ]]; then
    ACTIVE_MODE="$(cat "$PROJECT_DIR/.claude/.mode-overrides/$SESSION_ID" 2>/dev/null || true)"
fi

# Fall back to global active mode
if [[ -z "$ACTIVE_MODE" && -f "$PROJECT_DIR/.claude/.active-mode" ]]; then
    ACTIVE_MODE="$(cat "$PROJECT_DIR/.claude/.active-mode" 2>/dev/null || true)"
fi

# No mode set — nothing to enforce
[[ -n "$ACTIVE_MODE" ]] || exit 0

# ── Extract tool input text ──────────────────────────────────────────────────
TOOL_TEXT="$(printf '%s' "$HOOK_INPUT" | python3 -I -c '
import sys, json
try:
    data = json.load(sys.stdin)
    inp = data.get("tool_input", {})
    if isinstance(inp, dict):
        parts = []
        for k in ("command", "content", "file_path", "new_string", "old_string"):
            v = inp.get(k, "")
            if v:
                parts.append(str(v))
        print("\n".join(parts))
    elif isinstance(inp, str):
        print(inp)
    else:
        print("")
except: print("")' 2>/dev/null || true)"

[[ -n "$TOOL_TEXT" ]] || exit 0

# Strip heredoc bodies to reduce false positives from documentation/examples
TOOL_TEXT_CHECK="$(printf '%s' "$TOOL_TEXT" | sed "/<<[[:space:]]*['\"]\\{0,1\\}EOF/,/^EOF/d")"

# ── Pattern definitions ──────────────────────────────────────────────────────

# Range/engagement patterns (should not appear in homelab context)
RANGE_PATTERNS=(
    '10\.10\.[0-9]{1,3}\.[0-9]{1,3}'
    '172\.21\.[0-9]{1,3}\.[0-9]{1,3}'
    '\bdcm[0-9]*[-.]'
    '\bcr14\b'
    '\bcrp\.cr14\b'
    'engagement[-_]?(id|state|yaml)'
    '\btuoni\b'
    '\bRT-DEP-[0-9]+'
)

# Homelab private patterns (should not appear outside homelab repos)
HOMELAB_PATTERNS=(
    '10\.5\.[0-9]{1,3}\.[0-9]{1,3}'
    '\budr7\b'
    '\bUDR7\b'
    '\bassets\.yml\b'
)

FINDINGS=()

# ── Helper: check text against pattern list ──────────────────────────────────
check_patterns() {
    local text="$1"
    shift
    local patterns=("$@")
    local matched=()
    for pattern in "${patterns[@]}"; do
        if printf '%s' "$text" | grep -qEi "$pattern"; then
            local match
            match="$(printf '%s' "$text" | grep -oEi "$pattern" | head -1)"
            matched+=("$match")
        fi
    done
    printf '%s\n' "${matched[@]}"
}

# ── Direction 1: Range data leaking into homelab mode ────────────────────────
if [[ "$ACTIVE_MODE" == "homelab" ]]; then
    while IFS= read -r match; do
        [[ -n "$match" ]] && FINDINGS+=("range pattern in homelab context: $match")
    done < <(check_patterns "$TOOL_TEXT_CHECK" "${RANGE_PATTERNS[@]}")
fi

# ── Direction 2: Homelab data leaking into non-homelab modes ─────────────────
if [[ "$ACTIVE_MODE" != "homelab" ]]; then
    # Only check git commit commands (the actual contamination vector)
    if [[ "$TOOL_NAME" == "Bash" ]] && printf '%s' "$TOOL_TEXT_CHECK" | grep -qE 'git\s+(add|commit|push)'; then
        # Check if we're in a homelab repo (where homelab data is expected)
        IN_HOMELAB_REPO=false
        if printf '%s' "$TOOL_TEXT_CHECK" | grep -qEi 'homelab_(infra|planning)'; then
            IN_HOMELAB_REPO=true
        fi
        # Check working directory
        if [[ "$PWD" == *homelab_infra* || "$PWD" == *homelab_planning* ]]; then
            IN_HOMELAB_REPO=true
        fi

        if [[ "$IN_HOMELAB_REPO" == "false" ]]; then
            while IFS= read -r match; do
                [[ -n "$match" ]] && FINDINGS+=("homelab data in non-homelab commit: $match")
            done < <(check_patterns "$TOOL_TEXT_CHECK" "${HOMELAB_PATTERNS[@]}")
        fi
    fi

    # Also check Write/Edit to non-homelab paths
    if [[ "$TOOL_NAME" == "Write" || "$TOOL_NAME" == "Edit" ]]; then
        FILE_PATH="$(printf '%s' "$HOOK_INPUT" | python3 -I -c '
import sys, json
try: print(json.load(sys.stdin).get("tool_input",{}).get("file_path",""))
except: print("")' 2>/dev/null || true)"

        # Skip if writing to homelab repos (expected location)
        if [[ "$FILE_PATH" != *homelab_infra* && "$FILE_PATH" != *homelab_planning* ]]; then
            CONTENT="$(printf '%s' "$HOOK_INPUT" | python3 -I -c '
import sys, json
try:
    inp = json.load(sys.stdin).get("tool_input",{})
    print(inp.get("content","") + inp.get("new_string",""))
except: print("")' 2>/dev/null || true)"

            if [[ -n "$CONTENT" ]]; then
                while IFS= read -r match; do
                    [[ -n "$match" ]] && FINDINGS+=("homelab data written to non-homelab file ($FILE_PATH): $match")
                done < <(check_patterns "$CONTENT" "${HOMELAB_PATTERNS[@]}")
            fi
        fi
    fi
fi

# ── Verdict ──────────────────────────────────────────────────────────────────
if (( ${#FINDINGS[@]} == 0 )); then
    exit 0
fi

# Deduplicate
declare -A seen
unique=()
for f in "${FINDINGS[@]}"; do
    [[ -n "${seen[$f]:-}" ]] && continue
    seen[$f]=1
    unique+=("$f")
done

# Log to audit trail
AUDIT_DIR="${PROJECT_DIR}/.claude/audit"
mkdir -p "$AUDIT_DIR" 2>/dev/null || true
AUDIT_FILE="$AUDIT_DIR/leak-guard.jsonl"

python3 -I -c '
import json, sys, datetime
mode = sys.argv[1]
findings = sys.argv[2:]
entry = {
    "timestamp": datetime.datetime.utcnow().isoformat() + "Z",
    "event": "leak_guard_warning",
    "mode": mode,
    "findings": findings,
}
print(json.dumps(entry))
' "$ACTIVE_MODE" "${unique[@]}" >> "$AUDIT_FILE" 2>/dev/null || true

# Warn operator (soft guard — notification, not deny)
notification="$(python3 -I -c '
import sys, json
findings = sys.argv[1:]
msg = "AD-13 LEAK GUARD: " + "; ".join(findings) + ". Review for context cross-contamination."
print(json.dumps(msg)[1:-1])
' "${unique[@]}")"

printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","notification":"%s"}}\n' "$notification"
exit 0
