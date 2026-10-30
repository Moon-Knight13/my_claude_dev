#!/usr/bin/env bash
# Tests for scripts/check-health.sh — validates output format, section routing, exit codes.
# Uses PATH shims so no real Docker/SSH/gh needed.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
HEALTH="$REPO_ROOT/scripts/check-health.sh"

pass=0
fail=0
ok()  { echo "PASS $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1: $2"; fail=$((fail + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── Shims ────────────────────────────────────────────────────────────────────
SHIMS="$TMP/shims"
mkdir -p "$SHIMS"

cat > "$SHIMS/docker" <<'SHIM'
#!/usr/bin/env bash
case "$1" in
  info) exit 0 ;;
  system)
    echo "TYPE            TOTAL     ACTIVE    SIZE      RECLAIMABLE"
    echo "Images          5         2         1.2GB     800MB (66%)"
    echo "Containers      3         1         50MB      30MB"
    exit 0 ;;
  images) echo ""; exit 0 ;;  # no dangling
  ps) echo ""; exit 0 ;;      # no stopped
esac
exit 0
SHIM

cat > "$SHIMS/gh" <<'SHIM'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "auth status") exit 0 ;;
  "repo view") echo "main"; exit 0 ;;
  "run list") echo '[{"conclusion":"success","headSha":"abc1234","createdAt":"2026-10-30","name":"CI"}]'; exit 0 ;;
  "pr list") echo '[{"number":1}]'; exit 0 ;;
esac
exit 0
SHIM

cat > "$SHIMS/ssh" <<'SHIM'
#!/usr/bin/env bash
# Simulate spoke unreachable
exit 1
SHIM

cat > "$SHIMS/npm" <<'SHIM'
#!/usr/bin/env bash
echo '{"metadata":{"vulnerabilities":{"critical":0,"high":0,"moderate":0,"low":0}}}'
exit 0
SHIM

chmod +x "$SHIMS"/*

# Sandbox with settings.json
SANDBOX="$TMP/sandbox"
mkdir -p "$SANDBOX/.claude" "$SANDBOX/scripts/lib"
cp -r "$REPO_ROOT/scripts/lib/"*.sh "$SANDBOX/scripts/lib/" 2>/dev/null || true
cp "$HEALTH" "$SANDBOX/scripts/check-health.sh"
[[ -f "$REPO_ROOT/template.conf" ]] && cp "$REPO_ROOT/template.conf" "$SANDBOX/"
echo '{"_mode":"platform-ops","mcpServers":{"local-ollama":{"command":"npx","args":["-y","ollama-mcp"]}}}' > "$SANDBOX/.claude/settings.json"

run_health() {
    local section="${1:-all}"
    (cd "$SANDBOX" && PATH="$SHIMS:$PATH" bash scripts/check-health.sh "$section") > "$TMP/out" 2>&1
    echo $?
}

echo "=== check-health tests ==="

# --- T1: script exists and is executable ---
rc=0; [[ -x "$HEALTH" ]] || rc=1
ok_or_bad() { [[ $1 -eq 0 ]] && ok "$2" || bad "$2" "$3"; }
ok_or_bad $rc "script exists and is executable" "not found or not executable"

# --- T2: --section docker runs docker section ---
rc=$(run_health docker)
if [[ "$rc" -eq 0 ]] && grep -q "Docker" "$TMP/out"; then
    ok "docker section runs"
else
    bad "docker section runs" "exit=$rc"
fi

# --- T3: --section mcp runs MCP section ---
rc=$(run_health mcp)
if [[ "$rc" -eq 0 ]] && grep -q "MCP Servers" "$TMP/out"; then
    ok "mcp section runs"
else
    bad "mcp section runs" "exit=$rc"
fi

# --- T4: --section deps runs dependency section ---
rc=$(run_health deps)
if grep -q "Dependencies" "$TMP/out"; then
    ok "deps section runs"
else
    bad "deps section runs" "no Dependencies header"
fi

# --- T5: --section ci runs CI section ---
rc=$(run_health ci)
if grep -q "CI Status" "$TMP/out"; then
    ok "ci section runs"
else
    bad "ci section runs" "no CI Status header"
fi

# --- T6: --section spoke runs spoke section ---
rc=$(run_health spoke)
if grep -q "Spoke Preflight" "$TMP/out"; then
    ok "spoke section runs"
else
    bad "spoke section runs" "no Spoke Preflight header"
fi

# --- T7: invalid section exits 2 ---
rc=$(run_health "bogus")
if [[ "$rc" -eq 2 ]] && grep -q "Unknown section" "$TMP/out"; then
    ok "invalid section rejected"
else
    bad "invalid section rejected" "exit=$rc"
fi

# --- T8: all section runs all headers ---
rc=$(run_health all)
all_ok=true
for header in "Docker" "MCP Servers" "Dependencies" "CI Status" "Spoke Preflight"; do
    grep -q "$header" "$TMP/out" || all_ok=false
done
if $all_ok; then
    ok "all section runs all headers"
else
    bad "all section runs all headers" "missing headers"
fi

# --- T9: output has OK format ---
if grep -q "  OK " "$TMP/out"; then
    ok "output uses OK format"
else
    bad "output uses OK format" "no '  OK ' lines found"
fi

# --- T10: output has health summary ---
if grep -q "Health:" "$TMP/out"; then
    ok "output has health summary"
else
    bad "output has health summary" "no Health: line"
fi

# --- T11: MCP section reports active mode ---
rc=$(run_health mcp)
if grep -q "Active mode: platform-ops" "$TMP/out"; then
    ok "MCP reports active mode"
else
    bad "MCP reports active mode" "mode not shown"
fi

# --- T12: MCP section reports server count ---
if grep -q "MCP servers configured: 1" "$TMP/out"; then
    ok "MCP reports server count"
else
    bad "MCP reports server count" "count not shown"
fi

# --- T13: spoke unreachable shows WARN ---
rc=$(run_health spoke)
if grep -q "WARN" "$TMP/out"; then
    ok "spoke unreachable shows WARN"
else
    bad "spoke unreachable shows WARN" "no WARN for unreachable spoke"
fi

echo ""
echo "Results: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
