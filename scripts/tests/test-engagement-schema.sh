#!/usr/bin/env bash
set -euo pipefail

# Tests for Python JSON Schema validator (schemas/validate-engagement.py).
# Complements test-engagement-yaml.sh (bash validator).
# Requires: python3, pyyaml, jsonschema

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VALIDATOR="$REPO_ROOT/schemas/validate-engagement.py"

if ! python3 -c "import yaml, jsonschema" 2>/dev/null; then
  echo "SKIP: pyyaml or jsonschema not installed"
  exit 0
fi

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

PASS=0 FAIL=0
run_test() {
  local name="$1" file="$2" expect="$3"
  local rc=0
  output="$(python3 "$VALIDATOR" "$file" 2>&1)" || rc=$?
  if [[ "$rc" -eq "$expect" ]]; then
    echo "PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $name (expected exit $expect, got $rc)"
    echo "  output: $output"
    FAIL=$((FAIL + 1))
  fi
}

check_error() {
  local name="$1" file="$2" pattern="$3"
  local output
  output="$(python3 "$VALIDATOR" "$file" 2>&1)" || true
  if echo "$output" | grep -qF "$pattern"; then
    echo "PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $name (expected pattern '$pattern' in output)"
    echo "  output: $output"
    FAIL=$((FAIL + 1))
  fi
}

# Schema template validates
run_test "schema template passes" "$REPO_ROOT/schemas/engagement.yaml" 0

# Guacamole example validates
run_test "guacamole example passes" "$REPO_ROOT/schemas/engagement-guacamole-example.yaml" 0

# Empty file
touch "$TMPDIR/empty.yaml"
run_test "empty file fails" "$TMPDIR/empty.yaml" 1

# Invalid protocol enum
cat > "$TMPDIR/bad-proto.yaml" << 'EOF'
metadata: { id: t1, operator: op }
phase: recon
targets: []
agents: []
cred_refs: []
findings: []
persistence: []
lateral_moves: []
handoff: ""
guacamole_connections:
  - hostname: h1
    protocol: telnet
    ip: "198.51.100.1"
    port: 23
    status: active
EOF
run_test "invalid protocol rejected" "$TMPDIR/bad-proto.yaml" 1
check_error "protocol error mentions enum" "$TMPDIR/bad-proto.yaml" "'telnet' is not one of"

# Cross-ref: guac cred_ref must exist
cat > "$TMPDIR/bad-xref.yaml" << 'EOF'
metadata: { id: t2, operator: op }
phase: recon
targets: []
agents: []
cred_refs:
  - ref_id: cred-real
    tuoni_cred_id: tc-123
findings: []
persistence: []
lateral_moves: []
handoff: ""
guacamole_connections:
  - hostname: h1
    protocol: rdp
    ip: "198.51.100.1"
    port: 3389
    cred_ref: cred-nonexistent
    status: active
EOF
run_test "broken cred cross-ref fails" "$TMPDIR/bad-xref.yaml" 1
check_error "cross-ref error identifies field" "$TMPDIR/bad-xref.yaml" "cred_ref 'cred-nonexistent' not found"

# Cross-ref: proxy must exist in socks_proxies
cat > "$TMPDIR/bad-proxy-xref.yaml" << 'EOF'
metadata: { id: t3, operator: op }
phase: recon
targets: []
agents: []
cred_refs: []
findings: []
persistence: []
lateral_moves: []
handoff: ""
socks_proxies:
  - id: socks-real
    foothold_agent: a1
    listen_host: "127.0.0.1"
    listen_port: 1080
    type: socks5
    status: active
guacamole_connections:
  - hostname: h1
    protocol: rdp
    ip: "198.51.100.1"
    port: 3389
    proxy: socks-fake
    status: active
EOF
run_test "broken proxy cross-ref fails" "$TMPDIR/bad-proxy-xref.yaml" 1
check_error "proxy cross-ref error" "$TMPDIR/bad-proxy-xref.yaml" "proxy 'socks-fake' not found"

# Duplicate listener id
cat > "$TMPDIR/dup-listener.yaml" << 'EOF'
metadata: { id: t4, operator: op }
phase: recon
targets: []
agents: []
cred_refs: []
findings: []
persistence: []
lateral_moves: []
handoff: ""
listeners:
  - id: dup
    type: reverse_https
    status: active
  - id: dup
    type: reverse_http
    status: active
EOF
run_test "duplicate listener id fails" "$TMPDIR/dup-listener.yaml" 1
check_error "dup listener error" "$TMPDIR/dup-listener.yaml" "duplicate id 'dup'"

# Banned cred field detected
cat > "$TMPDIR/banned-cred.yaml" << 'EOF'
metadata: { id: t5, operator: op }
phase: recon
targets: []
agents: []
cred_refs:
  - ref_id: bad
    tuoni_cred_id: tc-123
    password: "hunter2"
findings: []
persistence: []
lateral_moves: []
handoff: ""
EOF
run_test "banned cred field fails" "$TMPDIR/banned-cred.yaml" 1
check_error "banned field error" "$TMPDIR/banned-cred.yaml" "banned field 'password'"

# Backward compat: file without new sections passes
cat > "$TMPDIR/legacy.yaml" << 'EOF'
metadata: { id: legacy, operator: op }
phase: recon
targets: []
agents: []
cred_refs: []
findings: []
persistence: []
lateral_moves: []
handoff: ""
EOF
run_test "legacy file without guac sections passes" "$TMPDIR/legacy.yaml" 0

# Listener type enum
cat > "$TMPDIR/bad-listener-type.yaml" << 'EOF'
metadata: { id: t6, operator: op }
phase: recon
targets: []
agents: []
cred_refs: []
findings: []
persistence: []
lateral_moves: []
handoff: ""
listeners:
  - id: bad
    type: reverse_websocket
    status: active
EOF
run_test "invalid listener type rejected" "$TMPDIR/bad-listener-type.yaml" 1

# Port range enforcement
cat > "$TMPDIR/bad-port.yaml" << 'EOF'
metadata: { id: t7, operator: op }
phase: recon
targets: []
agents: []
cred_refs: []
findings: []
persistence: []
lateral_moves: []
handoff: ""
guacamole_connections:
  - hostname: h1
    protocol: rdp
    ip: "198.51.100.1"
    port: 70000
    status: active
EOF
run_test "port > 65535 rejected" "$TMPDIR/bad-port.yaml" 1

echo ""
echo "Results: $PASS passed, $FAIL failed"
exit "$FAIL"
