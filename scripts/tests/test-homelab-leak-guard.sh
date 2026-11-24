#!/usr/bin/env bash
# test-homelab-leak-guard.sh — tests for AD-13 homelab leak guard hook.
# shellcheck disable=SC2015
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$ROOT/scripts/hooks/homelab-leak-guard.sh"
PASS=0; FAIL=0

# Patterns config must exist (private repo) — skip if missing
PATTERN_FILE="${LEAK_GUARD_PATTERNS:-$HOME/Documents/homelab_planning/config/leak-guard-patterns.conf}"
if [[ ! -f "$PATTERN_FILE" ]]; then
    echo "SKIP: patterns config not found at $PATTERN_FILE"
    echo "homelab-leak-guard: tests skipped (patterns config missing)"
    exit 0
fi

export LEAK_GUARD_PATTERNS="$PATTERN_FILE"

ok()  { echo "  OK  $1"; ((PASS++)) || true; }
bad() { echo " FAIL $1"; ((FAIL++)) || true; }

[[ -x "$HOOK" ]] || chmod +x "$HOOK"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT
mkdir -p "$TMPDIR/.claude"
export CLAUDE_PROJECT_DIR="$TMPDIR"

run_hook() {
    local mode="$1" input="$2"
    printf '%s' "$mode" > "$TMPDIR/.claude/.active-mode"
    printf '%s' "$input" | bash "$HOOK" 2>/dev/null
}

has_warning() { printf '%s' "$1" | grep -q "AD-13 LEAK GUARD"; }
is_silent()   { [[ -z "$1" ]]; }

# Read test values from patterns config at runtime
# Derive concrete test values from regex patterns in config.
# read -r preserves backslashes literally: \. stays as two chars \ and .
to_ip() { printf '%s' "$1" | sed 's/\\\././g' | sed 's/\[0-9\]{1,3}/'"$2"'/g'; }
to_word() { printf '%s' "$1" | sed 's/\\b//g'; }

RANGE_IP_1="" RANGE_IP_2="" HOMELAB_IP="" HOMELAB_DEVICE=""
current_section=""
while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    if [[ "$line" == "[range]" ]]; then current_section="range"; continue; fi
    if [[ "$line" == "[homelab]" ]]; then current_section="homelab"; continue; fi
    case "$current_section" in
        range)
            if [[ -z "$RANGE_IP_1" && "$line" == '10\.'* ]]; then
                RANGE_IP_1="$(to_ip "$line" 42)"
            elif [[ -z "$RANGE_IP_2" && "$line" == '172\.'* ]]; then
                RANGE_IP_2="$(to_ip "$line" 3)"
            fi
            ;;
        homelab)
            if [[ -z "$HOMELAB_IP" && "$line" == '10\.'* ]]; then
                HOMELAB_IP="$(to_ip "$line" 1)"
            elif [[ -z "$HOMELAB_DEVICE" && "$line" == '\b'* && "$line" != *'\.'* ]]; then
                HOMELAB_DEVICE="$(to_word "$line")"
            fi
            ;;
    esac
done < "$PATTERN_FILE"

if [[ -z "$RANGE_IP_1" || -z "$HOMELAB_IP" ]]; then
    echo "SKIP: could not derive test values from patterns config"
    exit 0
fi

# ══════════════════════════════════════════════════════════════════════════════
echo "== Irrelevant tools skipped =="
# ══════════════════════════════════════════════════════════════════════════════

OUT="$(run_hook "homelab" "{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"/tmp/$RANGE_IP_1\"}}")"
is_silent "$OUT" && ok "Read tool: ignored" || bad "Read tool triggered guard: $OUT"

OUT="$(run_hook "homelab" "{\"tool_name\":\"Agent\",\"tool_input\":{\"prompt\":\"check $RANGE_IP_1\"}}")"
is_silent "$OUT" && ok "Agent tool: ignored" || bad "Agent tool triggered guard: $OUT"

# ══════════════════════════════════════════════════════════════════════════════
echo "== No mode set =="
# ══════════════════════════════════════════════════════════════════════════════

rm -f "$TMPDIR/.claude/.active-mode"
OUT="$(printf '{"tool_name":"Bash","tool_input":{"command":"ping %s"}}' "$RANGE_IP_1" | CLAUDE_PROJECT_DIR="$TMPDIR" bash "$HOOK" 2>/dev/null)"
is_silent "$OUT" && ok "no active mode: silent" || bad "no mode produced output: $OUT"

# ══════════════════════════════════════════════════════════════════════════════
echo "== Direction 1: range data in homelab mode =="
# ══════════════════════════════════════════════════════════════════════════════

OUT="$(run_hook "homelab" "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ping $RANGE_IP_1\"}}")"
has_warning "$OUT" && ok "range IP 1 in Bash: warned" || bad "range IP 1 in Bash: no warning"

OUT="$(run_hook "homelab" "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ssh user@$RANGE_IP_2\"}}")"
has_warning "$OUT" && ok "range IP 2 in Bash: warned" || bad "range IP 2 in Bash: no warning"

OUT="$(run_hook "homelab" '{"tool_name":"Bash","tool_input":{"command":"curl dcm27-rt.crp.cr14.net"}}')"
has_warning "$OUT" && ok "range hostname in Bash: warned" || bad "range hostname in Bash: no warning"

OUT="$(run_hook "homelab" "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/test.yml\",\"content\":\"target: $RANGE_IP_1\\nhost: dcm15-ws\"}}")"
has_warning "$OUT" && ok "range IP in Write: warned" || bad "range IP in Write: no warning"

OUT="$(run_hook "homelab" '{"tool_name":"Edit","tool_input":{"file_path":"/tmp/test.sh","new_string":"connect to tuoni agent","old_string":"placeholder"}}')"
has_warning "$OUT" && ok "tuoni ref in Edit: warned" || bad "tuoni ref in Edit: no warning"

OUT="$(run_hook "homelab" '{"tool_name":"Bash","tool_input":{"command":"echo RT-DEP-001 deploy order"}}')"
has_warning "$OUT" && ok "RT-DEP in Bash: warned" || bad "RT-DEP in Bash: no warning"

OUT="$(run_hook "homelab" '{"tool_name":"Bash","tool_input":{"command":"check engagement_state.yaml"}}')"
has_warning "$OUT" && ok "engagement ref: warned" || bad "engagement ref: no warning"

# ── Clean homelab commands should pass silently ──────────────────────────────

OUT="$(run_hook "homelab" '{"tool_name":"Bash","tool_input":{"command":"docker compose up -d jellyfin"}}')"
is_silent "$OUT" && ok "clean docker cmd: silent" || bad "clean docker cmd triggered: $OUT"

OUT="$(run_hook "homelab" "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ping $HOMELAB_IP\"}}")"
is_silent "$OUT" && ok "homelab IP in homelab mode: silent" || bad "homelab IP triggered in homelab mode: $OUT"

OUT="$(run_hook "homelab" '{"tool_name":"Write","tool_input":{"file_path":"/tmp/docker-compose.yml","content":"image: jellyfin/jellyfin:latest"}}')"
is_silent "$OUT" && ok "clean Write: silent" || bad "clean Write triggered: $OUT"

# ══════════════════════════════════════════════════════════════════════════════
echo "== Direction 2: homelab data in non-homelab modes =="
# ══════════════════════════════════════════════════════════════════════════════

OUT="$(run_hook "red-team" "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m \\\"fix\\\" -- notes-with-${HOMELAB_IP}.md\"}}")"
has_warning "$OUT" && ok "homelab IP in red-team commit: warned" || bad "homelab IP in red-team commit: no warning"

OUT="$(run_hook "platform-ops" "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git add . && git commit -m \\\"update $HOMELAB_DEVICE config\\\"\"}}")"
has_warning "$OUT" && ok "device name in platform-ops commit: warned" || bad "device name in platform-ops commit: no warning"

OUT="$(run_hook "green-dev" "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/my_claude_dev/test.yml\",\"content\":\"router: $HOMELAB_IP\\ngateway: $HOMELAB_DEVICE\"}}")"
has_warning "$OUT" && ok "homelab data in Write to non-homelab: warned" || bad "homelab Write: no warning"

# ── Homelab data in homelab repos is expected ────────────────────────────────

OUT="$(run_hook "platform-ops" "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/home/chris/homelab_infra/ansible/host_vars.yml\",\"content\":\"ip: $HOMELAB_IP\\nrouter: $HOMELAB_DEVICE\"}}")"
is_silent "$OUT" && ok "homelab data in homelab_infra: silent" || bad "homelab_infra write triggered: $OUT"

OUT="$(run_hook "red-team" "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/homelab_planning/inventory.yml\",\"content\":\"$HOMELAB_IP\"}}")"
is_silent "$OUT" && ok "homelab data in homelab_planning: silent" || bad "homelab_planning write triggered: $OUT"

# ── Range data in non-homelab modes should NOT trigger ───────────────────────

OUT="$(run_hook "red-team" "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ping $RANGE_IP_1\"}}")"
is_silent "$OUT" && ok "range IP in red-team: silent (expected context)" || bad "range IP in red-team triggered: $OUT"

OUT="$(run_hook "green-dev" '{"tool_name":"Bash","tool_input":{"command":"ssh dcm15-ws.crp.cr14.net"}}')"
is_silent "$OUT" && ok "range hostname in green-dev: silent (expected)" || bad "range hostname in green-dev triggered: $OUT"

# ── Non-git Bash in non-homelab mode: homelab IP no warning ──────────────────

OUT="$(run_hook "red-team" "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo $HOMELAB_IP in a note\"}}")"
is_silent "$OUT" && ok "homelab IP in non-git Bash: silent" || bad "non-git Bash triggered: $OUT"

# ══════════════════════════════════════════════════════════════════════════════
echo "== Heredoc false-positive prevention =="
# ══════════════════════════════════════════════════════════════════════════════

OUT="$(run_hook "homelab" "$(printf '{"tool_name":"Bash","tool_input":{"command":"gh pr create --body \"$(cat <<'"'"'EOF'"'"'\\n%s is an example range IP\\nEOF\\n)\""}}' "$RANGE_IP_1")")"
is_silent "$OUT" && ok "heredoc with range IP: silent" || bad "heredoc triggered: $OUT"

# ══════════════════════════════════════════════════════════════════════════════
echo "== Audit logging =="
# ══════════════════════════════════════════════════════════════════════════════

rm -f "$TMPDIR/.claude/audit/leak-guard.jsonl"
run_hook "homelab" "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ping $RANGE_IP_1\"}}" >/dev/null
[[ -f "$TMPDIR/.claude/audit/leak-guard.jsonl" ]] && ok "audit file created" || bad "no audit file"
if [[ -f "$TMPDIR/.claude/audit/leak-guard.jsonl" ]]; then
    grep -q "leak_guard_warning" "$TMPDIR/.claude/audit/leak-guard.jsonl" && ok "audit entry logged" || bad "audit entry missing"
fi

# ══════════════════════════════════════════════════════════════════════════════
echo "== Per-session mode override =="
# ══════════════════════════════════════════════════════════════════════════════

export CLAUDE_CODE_SESSION_ID="test-session-$$"
mkdir -p "$TMPDIR/.claude/.mode-overrides"
printf 'homelab' > "$TMPDIR/.claude/.mode-overrides/$CLAUDE_CODE_SESSION_ID"
printf 'red-team' > "$TMPDIR/.claude/.active-mode"

OUT="$(printf '{"tool_name":"Bash","tool_input":{"command":"ping %s"}}' "$RANGE_IP_1" | CLAUDE_PROJECT_DIR="$TMPDIR" bash "$HOOK" 2>/dev/null)"
has_warning "$OUT" && ok "session override to homelab: range IP warned" || bad "session override not respected: $OUT"

rm -f "$TMPDIR/.claude/.mode-overrides/$CLAUDE_CODE_SESSION_ID"
unset CLAUDE_CODE_SESSION_ID

echo ""
echo "homelab-leak-guard: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
