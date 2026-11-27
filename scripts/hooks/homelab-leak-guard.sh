#!/usr/bin/env bash
# homelab-leak-guard.sh — PreToolUse hook: AD-13 context isolation.
#
# Bidirectional guard between homelab and other operational contexts.
# Patterns loaded from external config (private repo); no-op if missing.
# Soft guard: warns via notification, never blocks.
#
# Trigger: PreToolUse on Bash, Write, Edit tools
# Exit codes: 0 — always
set -euo pipefail

HOOK_INPUT="$(cat)"

# ── Extract tool name ────────────────────────────────────────────────────────
TOOL_NAME="$(printf '%s' "$HOOK_INPUT" | python3 -I -c '
import sys, json
try: print(json.load(sys.stdin).get("tool_name",""))
except: print("")' 2>/dev/null || true)"

case "$TOOL_NAME" in
    Bash|Write|Edit) ;;
    *) exit 0 ;;
esac

# ── Load patterns from external config ──────────────────────────────────────
PATTERN_FILE="${LEAK_GUARD_PATTERNS:-$HOME/Documents/homelab_planning/config/leak-guard-patterns.conf}"
if [[ ! -f "$PATTERN_FILE" ]]; then
    exit 0
fi

RANGE_PATTERNS=()
HOMELAB_PATTERNS=()
current_section=""
while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    if [[ "$line" == "[range]" ]]; then current_section="range"; continue; fi
    if [[ "$line" == "[homelab]" ]]; then current_section="homelab"; continue; fi
    case "$current_section" in
        range) RANGE_PATTERNS+=("$line") ;;
        homelab) HOMELAB_PATTERNS+=("$line") ;;
    esac
done < "$PATTERN_FILE"

if (( ${#RANGE_PATTERNS[@]} == 0 && ${#HOMELAB_PATTERNS[@]} == 0 )); then
    exit 0
fi

# ── Detect active mode ───────────────────────────────────────────────────────
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-.}"
SESSION_ID="${CLAUDE_CODE_SESSION_ID:-}"
ACTIVE_MODE=""

if [[ -n "$SESSION_ID" && -f "$PROJECT_DIR/.claude/.mode-overrides/$SESSION_ID" ]]; then
    ACTIVE_MODE="$(cat "$PROJECT_DIR/.claude/.mode-overrides/$SESSION_ID" 2>/dev/null || true)"
fi

if [[ -z "$ACTIVE_MODE" && -f "$PROJECT_DIR/.claude/.active-mode" ]]; then
    ACTIVE_MODE="$(cat "$PROJECT_DIR/.claude/.active-mode" 2>/dev/null || true)"
fi

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

# Strip heredoc bodies to reduce false positives
TOOL_TEXT_CHECK="$(printf '%s' "$TOOL_TEXT" | sed "/<<[[:space:]]*['\"]\\{0,1\\}EOF/,/^EOF/d")"

# gh issue/PR create/edit: scan full text including heredoc body content
IS_GH_PUBLISH=false
if [[ "$TOOL_NAME" == "Bash" ]] && printf '%s' "$TOOL_TEXT" | grep -qE 'gh\s+(issue|pr)\s+(create|edit)'; then
    IS_GH_PUBLISH=true
fi
SCAN_TEXT="$TOOL_TEXT_CHECK"
[[ "$IS_GH_PUBLISH" == "true" ]] && SCAN_TEXT="$TOOL_TEXT"

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

FINDINGS=()

# ── Direction 1: Range data leaking into homelab mode ────────────────────────
if [[ "$ACTIVE_MODE" == "homelab" ]]; then
    while IFS= read -r match; do
        [[ -n "$match" ]] && FINDINGS+=("range pattern in homelab context: $match")
    done < <(check_patterns "$SCAN_TEXT" "${RANGE_PATTERNS[@]}")
fi

# ── Direction 2: Homelab data leaking into non-homelab modes ─────────────────
if [[ "$ACTIVE_MODE" != "homelab" ]]; then
    if [[ "$TOOL_NAME" == "Bash" ]] && printf '%s' "$TOOL_TEXT_CHECK" | grep -qE 'git\s+(add|commit|push)'; then
        IN_HOMELAB_REPO=false
        if printf '%s' "$TOOL_TEXT_CHECK" | grep -qEi 'homelab_(infra|planning)'; then
            IN_HOMELAB_REPO=true
        fi
        if [[ "$PWD" == *homelab_infra* || "$PWD" == *homelab_planning* ]]; then
            IN_HOMELAB_REPO=true
        fi

        if [[ "$IN_HOMELAB_REPO" == "false" ]]; then
            while IFS= read -r match; do
                [[ -n "$match" ]] && FINDINGS+=("homelab data in non-homelab commit: $match")
            done < <(check_patterns "$TOOL_TEXT_CHECK" "${HOMELAB_PATTERNS[@]}")
        fi
    fi

    # gh issue/PR create/edit: scan full command including heredoc body
    if [[ "$IS_GH_PUBLISH" == "true" ]]; then
        IN_HOMELAB_CONTEXT=false
        if printf '%s' "$TOOL_TEXT" | grep -qEi 'homelab_(infra|planning)'; then
            IN_HOMELAB_CONTEXT=true
        fi
        if [[ "$PWD" == *homelab_infra* || "$PWD" == *homelab_planning* ]]; then
            IN_HOMELAB_CONTEXT=true
        fi

        if [[ "$IN_HOMELAB_CONTEXT" == "false" ]]; then
            while IFS= read -r match; do
                [[ -n "$match" ]] && FINDINGS+=("homelab data in gh publish command: $match")
            done < <(check_patterns "$TOOL_TEXT" "${HOMELAB_PATTERNS[@]}")
        fi
    fi

    if [[ "$TOOL_NAME" == "Write" || "$TOOL_NAME" == "Edit" ]]; then
        FILE_PATH="$(printf '%s' "$HOOK_INPUT" | python3 -I -c '
import sys, json
try: print(json.load(sys.stdin).get("tool_input",{}).get("file_path",""))
except: print("")' 2>/dev/null || true)"

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

declare -A seen
unique=()
for f in "${FINDINGS[@]}"; do
    [[ -n "${seen[$f]:-}" ]] && continue
    seen[$f]=1
    unique+=("$f")
done

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

notification="$(python3 -I -c '
import sys, json
findings = sys.argv[1:]
msg = "AD-13 LEAK GUARD: " + "; ".join(findings) + ". Review for context cross-contamination."
print(json.dumps(msg)[1:-1])
' "${unique[@]}")"

printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","notification":"%s"}}\n' "$notification"
exit 0
