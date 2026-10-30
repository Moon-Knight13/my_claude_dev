#!/usr/bin/env bash
# Tests for mode switching — validates template structure, merge logic, safety.
#
# Runs against a temp copy of the repo's .claude/modes/ directory.
# No side effects on the real config.
#
# Usage: bash scripts/tests/test-mode-switching.sh
# Exit: 0 pass, non-zero = number of failures.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

fails=0
ok()   { echo "PASS $1"; }
bad()  { echo "FAIL $1: $2"; fails=$((fails + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Copy modes to temp for testing
cp -r "$REPO_ROOT/.claude/modes" "$TMP/modes"
MODES_DIR="$TMP/modes"

# --- 1. Base directory exists with required files ----------------------------
if [[ -f "$MODES_DIR/base/CLAUDE.md" ]] && [[ -f "$MODES_DIR/base/settings.json" ]]; then
    ok base-files-exist
else
    bad base-files-exist "missing base/CLAUDE.md or base/settings.json"
fi

# --- 2. Base settings.json is valid JSON ------------------------------------
if jq empty "$MODES_DIR/base/settings.json" 2>/dev/null; then
    ok base-settings-valid-json
else
    bad base-settings-valid-json "base/settings.json is not valid JSON"
fi

# --- 3. Base settings has hooks (guards must survive all modes) --------------
if jq -e '.hooks.PreToolUse | length > 0' "$MODES_DIR/base/settings.json" >/dev/null 2>&1; then
    ok base-has-hooks
else
    bad base-has-hooks "base/settings.json missing hooks.PreToolUse"
fi

# --- 4. Each mode directory has required files --------------------------------
for mode_dir in "$MODES_DIR"/*/; do
    mode="$(basename "$mode_dir")"
    [[ "$mode" == "base" ]] && continue

    if [[ -f "$mode_dir/CLAUDE.md" ]] && [[ -f "$mode_dir/settings.json" ]]; then
        ok "mode-$mode-files-exist"
    else
        bad "mode-$mode-files-exist" "missing CLAUDE.md or settings.json"
    fi

    if jq empty "$mode_dir/settings.json" 2>/dev/null; then
        ok "mode-$mode-settings-valid-json"
    else
        bad "mode-$mode-settings-valid-json" "settings.json is not valid JSON"
    fi
done

# --- 5. Settings merge preserves base hooks -----------------------------------
for mode_dir in "$MODES_DIR"/*/; do
    mode="$(basename "$mode_dir")"
    [[ "$mode" == "base" ]] && continue

    merged="$(jq -n --slurpfile base "$MODES_DIR/base/settings.json" --slurpfile mode "$mode_dir/settings.json" '
        $base[0] + {
            mcpServers: (($base[0].mcpServers // {}) + ($mode[0].mcpServers // {})),
            _mode: $mode[0]._mode,
            _description: $mode[0]._description
        }
    ' 2>/dev/null)"

    if echo "$merged" | jq -e '.hooks.PreToolUse | length > 0' >/dev/null 2>&1; then
        ok "merge-$mode-preserves-hooks"
    else
        bad "merge-$mode-preserves-hooks" "hooks lost after merge"
    fi

    if echo "$merged" | jq empty 2>/dev/null; then
        ok "merge-$mode-valid-json"
    else
        bad "merge-$mode-valid-json" "merged settings is not valid JSON"
    fi
done

# --- 6. Settings merge includes base MCP servers ----------------------------
merged_rt="$(jq -n --slurpfile base "$MODES_DIR/base/settings.json" --slurpfile mode "$MODES_DIR/red-team/settings.json" '
    $base[0] + {
        mcpServers: (($base[0].mcpServers // {}) + ($mode[0].mcpServers // {}))
    }
' 2>/dev/null)"

if echo "$merged_rt" | jq -e '.mcpServers["local-ollama"]' >/dev/null 2>&1; then
    ok merge-red-team-keeps-local-ollama
else
    bad merge-red-team-keeps-local-ollama "local-ollama lost in red-team merge"
fi

# --- 7. Red-team merge adds offensive MCP servers ----------------------------
if echo "$merged_rt" | jq -e '.mcpServers["tuoni-mcp"]' >/dev/null 2>&1 \
   && echo "$merged_rt" | jq -e '.mcpServers["range-intel"]' >/dev/null 2>&1 \
   && echo "$merged_rt" | jq -e '.mcpServers["hacktricks-mcp"]' >/dev/null 2>&1; then
    ok merge-red-team-adds-offensive-mcps
else
    bad merge-red-team-adds-offensive-mcps "missing offensive MCP servers in merged config"
fi

# --- 8. Platform-ops merge has no offensive MCP servers ----------------------
merged_po="$(jq -n --slurpfile base "$MODES_DIR/base/settings.json" --slurpfile mode "$MODES_DIR/platform-ops/settings.json" '
    $base[0] + {
        mcpServers: (($base[0].mcpServers // {}) + ($mode[0].mcpServers // {}))
    }
' 2>/dev/null)"

if echo "$merged_po" | jq -e '.mcpServers["tuoni-mcp"]' >/dev/null 2>&1; then
    bad platform-ops-no-offensive-mcps "tuoni-mcp present in platform-ops"
else
    ok platform-ops-no-offensive-mcps
fi

# --- 9. CLAUDE.md merge produces non-empty file ------------------------------
merged_claude="$(cat "$MODES_DIR/base/CLAUDE.md"; echo ""; cat "$MODES_DIR/red-team/CLAUDE.md")"
if [[ -n "$merged_claude" ]] && echo "$merged_claude" | grep -q "Workflow Contract" && echo "$merged_claude" | grep -q "red-team"; then
    ok claude-merge-has-base-and-mode
else
    bad claude-merge-has-base-and-mode "merged CLAUDE.md missing base or mode content"
fi

# --- 10. Red-team CLAUDE.md contains OPSEC rules ----------------------------
if grep -q "RT-TGT-001" "$MODES_DIR/red-team/CLAUDE.md" \
   && grep -q "RT-SIG-001" "$MODES_DIR/red-team/CLAUDE.md" \
   && grep -q "RT-DEP-001" "$MODES_DIR/red-team/CLAUDE.md"; then
    ok red-team-has-opsec-rules
else
    bad red-team-has-opsec-rules "missing OPSEC rules in red-team CLAUDE.md"
fi

# --- 11. Platform-ops CLAUDE.md has NO OPSEC rules ---------------------------
if grep -q "RT-TGT-001" "$MODES_DIR/platform-ops/CLAUDE.md" 2>/dev/null; then
    bad platform-ops-no-opsec "platform-ops CLAUDE.md contains OPSEC rules"
else
    ok platform-ops-no-opsec
fi

# --- 12. Red-dev has eip-mcp but no tuoni in production role ----------------
merged_rd="$(jq -n --slurpfile base "$MODES_DIR/base/settings.json" --slurpfile mode "$MODES_DIR/red-dev/settings.json" '
    $base[0] + {
        mcpServers: (($base[0].mcpServers // {}) + ($mode[0].mcpServers // {}))
    }
' 2>/dev/null)"

if echo "$merged_rd" | jq -e '.mcpServers["eip-mcp"]' >/dev/null 2>&1 \
   && echo "$merged_rd" | jq -e '.mcpServers["hacktricks-mcp"]' >/dev/null 2>&1; then
    ok red-dev-has-research-mcps
else
    bad red-dev-has-research-mcps "missing eip-mcp or hacktricks-mcp in red-dev"
fi

# --- 13. Red-dev CLAUDE.md has exploit hygiene rules -----------------------
if grep -q "Exploit Hygiene" "$MODES_DIR/red-dev/CLAUDE.md" \
   && grep -q "RT-TGT-001" "$MODES_DIR/red-dev/CLAUDE.md"; then
    ok red-dev-has-opsec
else
    bad red-dev-has-opsec "missing exploit hygiene or RT-TGT-001 in red-dev CLAUDE.md"
fi

# --- 14. Green-dev has range-intel but no offensive MCPs -------------------
merged_gd="$(jq -n --slurpfile base "$MODES_DIR/base/settings.json" --slurpfile mode "$MODES_DIR/green-dev/settings.json" '
    $base[0] + {
        mcpServers: (($base[0].mcpServers // {}) + ($mode[0].mcpServers // {}))
    }
' 2>/dev/null)"

if echo "$merged_gd" | jq -e '.mcpServers["range-intel"]' >/dev/null 2>&1 \
   && ! echo "$merged_gd" | jq -e '.mcpServers["tuoni-mcp"]' >/dev/null 2>&1; then
    ok green-dev-range-intel-no-offensive
else
    bad green-dev-range-intel-no-offensive "green-dev should have range-intel, no tuoni-mcp"
fi

# --- 15. Green-dev CLAUDE.md has DEV rules ---------------------------------
if grep -q "DEV-002" "$MODES_DIR/green-dev/CLAUDE.md" \
   && grep -q "Providentia" "$MODES_DIR/green-dev/CLAUDE.md"; then
    ok green-dev-has-dev-rules
else
    bad green-dev-has-dev-rules "missing DEV-002 or Providentia in green-dev CLAUDE.md"
fi

# --- 16. Purple has all red-team MCPs -------------------------------------
merged_pu="$(jq -n --slurpfile base "$MODES_DIR/base/settings.json" --slurpfile mode "$MODES_DIR/purple/settings.json" '
    $base[0] + {
        mcpServers: (($base[0].mcpServers // {}) + ($mode[0].mcpServers // {}))
    }
' 2>/dev/null)"

if echo "$merged_pu" | jq -e '.mcpServers["tuoni-mcp"]' >/dev/null 2>&1 \
   && echo "$merged_pu" | jq -e '.mcpServers["range-intel"]' >/dev/null 2>&1 \
   && echo "$merged_pu" | jq -e '.mcpServers["hacktricks-mcp"]' >/dev/null 2>&1 \
   && echo "$merged_pu" | jq -e '.mcpServers["mitre-mcp"]' >/dev/null 2>&1; then
    ok purple-has-full-mcp-stack
else
    bad purple-has-full-mcp-stack "purple missing expected MCP servers"
fi

# --- 17. Purple CLAUDE.md has detection scoring ----------------------------
if grep -q "Detection Scoring" "$MODES_DIR/purple/CLAUDE.md" \
   && grep -q "RT-TGT-001" "$MODES_DIR/purple/CLAUDE.md" \
   && grep -q "time_to_detect" "$MODES_DIR/purple/CLAUDE.md"; then
    ok purple-has-detection-scoring
else
    bad purple-has-detection-scoring "missing detection scoring or OPSEC in purple CLAUDE.md"
fi

# --- 18. Purple CLAUDE.md has OPSEC inherited from red-team ----------------
if grep -q "RT-SIG-001" "$MODES_DIR/purple/CLAUDE.md" \
   && grep -q "RT-SIG-002" "$MODES_DIR/purple/CLAUDE.md" \
   && grep -q "RT-DEP-001" "$MODES_DIR/purple/CLAUDE.md"; then
    ok purple-inherits-opsec
else
    bad purple-inherits-opsec "purple missing inherited OPSEC rules"
fi

# --- 19. All modes have _mode field in settings ----------------------------
all_have_mode=true
for mode_dir in "$MODES_DIR"/*/; do
    mode="$(basename "$mode_dir")"
    [[ "$mode" == "base" ]] && continue
    if ! jq -e '._mode' "$mode_dir/settings.json" >/dev/null 2>&1; then
        all_have_mode=false
        bad "mode-$mode-has-_mode-field" "missing _mode in settings.json"
    fi
done
$all_have_mode && ok all-modes-have-_mode-field

# --- 20. Invalid mode directory rejected ------------------------------------
if [[ ! -d "$MODES_DIR/nonexistent" ]]; then
    ok invalid-mode-rejected
else
    bad invalid-mode-rejected "nonexistent mode directory somehow exists"
fi

echo ""
if [[ "$fails" -eq 0 ]]; then
    echo "ALL PASS"
else
    echo "$fails FAILED"
fi
exit "$fails"
