#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VALIDATOR="$SCRIPT_DIR/../validate-engagement.sh"

# Skip if yq not available (CI may not have it)
if ! command -v yq >/dev/null 2>&1; then
  echo "SKIP: yq not found — engagement YAML tests require yq"
  exit 0
fi
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

PASS=0 FAIL=0
run_test() {
  local name="$1" file="$2" expect="$3"
  local rc=0
  output="$("$VALIDATOR" "$file" 2>&1)" || rc=$?
  if [[ "$rc" -eq "$expect" ]]; then
    echo "PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $name (expected exit $expect, got $rc)"
    echo "  output: $output"
    FAIL=$((FAIL + 1))
  fi
}

# Minimal valid engagement YAML
VALID="$TMPDIR/valid.yaml"
cat > "$VALID" << 'EOF'
metadata:
  id: test-001
  operator: tester
phase: recon
targets:
  - hostname: host-a
    approved: true
agents:
  - agent_id: a1
    payload_id: pl-001
cred_refs:
  - ref_id: cr-001
    tuoni_cred_id: tc-abc
findings: []
persistence:
  - target: host-a
    method: cron
lateral_moves:
  - from_host: host-a
    to_host: host-b
    cred_ref: cr-001
handoff: "Next steps here"
EOF

run_test "valid file passes" "$VALID" 0

# Missing required keys
MISSING="$TMPDIR/missing.yaml"
cat > "$MISSING" << 'EOF'
metadata:
  id: test-002
  operator: tester
phase: recon
EOF
run_test "missing keys fail" "$MISSING" 1

# Invalid phase
BAD_PHASE="$TMPDIR/bad-phase.yaml"
cat > "$BAD_PHASE" << 'EOF'
metadata:
  id: test-003
  operator: tester
phase: pwned
targets: []
agents: []
cred_refs: []
findings: []
persistence: []
lateral_moves: []
handoff: ""
EOF
run_test "invalid phase fails" "$BAD_PHASE" 1

# Duplicate payload_id
DUP_PID="$TMPDIR/dup-pid.yaml"
cat > "$DUP_PID" << 'EOF'
metadata:
  id: test-004
  operator: tester
phase: lateral
targets: []
agents:
  - agent_id: a1
    payload_id: pl-dup
  - agent_id: a2
    payload_id: pl-dup
cred_refs: []
findings: []
persistence: []
lateral_moves: []
handoff: ""
EOF
run_test "duplicate payload_id fails" "$DUP_PID" 1

# Plaintext cred field (SECURITY)
PLAINTEXT="$TMPDIR/plaintext.yaml"
cat > "$PLAINTEXT" << 'EOF'
metadata:
  id: test-005
  operator: tester
phase: recon
targets: []
agents: []
cred_refs:
  - ref_id: cr-bad
    tuoni_cred_id: tc-xyz
    password: "hunter2"
findings: []
persistence: []
lateral_moves: []
handoff: ""
EOF
run_test "plaintext cred field fails" "$PLAINTEXT" 1

# Missing tuoni_cred_id
NO_TCID="$TMPDIR/no-tcid.yaml"
cat > "$NO_TCID" << 'EOF'
metadata:
  id: test-006
  operator: tester
phase: recon
targets: []
agents: []
cred_refs:
  - ref_id: cr-noid
    type: ldap
findings: []
persistence: []
lateral_moves: []
handoff: ""
EOF
run_test "missing tuoni_cred_id fails" "$NO_TCID" 1

# Broken YAML
BROKEN="$TMPDIR/broken.yaml"
printf '{\ninvalid: [yaml\n' > "$BROKEN"
run_test "broken YAML fails" "$BROKEN" 1

# Empty file
EMPTY="$TMPDIR/empty.yaml"
touch "$EMPTY"
run_test "empty file fails" "$EMPTY" 1

# kali_agent_id accepted (optional)
KALI_ID="$TMPDIR/kali-id.yaml"
cat > "$KALI_ID" << 'EOF'
metadata:
  id: test-kali
  operator: tester
phase: recon
targets: []
agents: []
cred_refs: []
findings: []
persistence: []
lateral_moves: []
handoff: ""
kali_agent_id: "a1b2c3d4"
EOF
run_test "kali_agent_id accepted" "$KALI_ID" 0

# cache_timestamp accepted (optional)
CACHE_TS="$TMPDIR/cache-ts.yaml"
cat > "$CACHE_TS" << 'EOF'
metadata:
  id: test-cache
  operator: tester
phase: recon
targets: []
agents: []
cred_refs: []
findings: []
persistence: []
lateral_moves: []
handoff: ""
cache_timestamp: "2026-11-02T14:30:00Z"
EOF
run_test "cache_timestamp accepted" "$CACHE_TS" 0

# type: black-box accepted
BLACKBOX="$TMPDIR/blackbox.yaml"
cat > "$BLACKBOX" << 'EOF'
metadata:
  id: test-bb
  operator: tester
phase: recon
type: black-box
targets: []
agents: []
cred_refs: []
findings: []
persistence: []
lateral_moves: []
handoff: ""
EOF
run_test "type black-box accepted" "$BLACKBOX" 0

# Invalid type rejected
BAD_TYPE="$TMPDIR/bad-type.yaml"
cat > "$BAD_TYPE" << 'EOF'
metadata:
  id: test-badtype
  operator: tester
phase: recon
type: grey-box
targets: []
agents: []
cred_refs: []
findings: []
persistence: []
lateral_moves: []
handoff: ""
EOF
run_test "invalid type fails" "$BAD_TYPE" 1

# type omitted (standard) still passes
STD_TYPE="$TMPDIR/std-type.yaml"
cat > "$STD_TYPE" << 'EOF'
metadata:
  id: test-stdtype
  operator: tester
phase: recon
targets: []
agents: []
cred_refs: []
findings: []
persistence: []
lateral_moves: []
handoff: ""
EOF
run_test "omitted type accepted (standard)" "$STD_TYPE" 0

# Both fields together
BOTH="$TMPDIR/both.yaml"
cat > "$BOTH" << 'EOF'
metadata:
  id: test-both
  operator: tester
phase: recon
targets: []
agents: []
cred_refs: []
findings: []
persistence: []
lateral_moves: []
handoff: ""
kali_agent_id: "abc123"
cache_timestamp: "2026-11-02T14:30:00Z"
EOF
run_test "both new fields accepted together" "$BOTH" 0

# --- Guacamole integration tests (#456) ---

# Valid guacamole_connections
GUAC_VALID="$TMPDIR/guac-valid.yaml"
cat > "$GUAC_VALID" << 'EOF'
metadata:
  id: test-guac
  operator: tester
phase: recon
targets: []
agents:
  - agent_id: agent-fw
    payload_id: pl-fw-001
cred_refs:
  - ref_id: cred-001
    tuoni_cred_id: tc-abc
findings: []
persistence: []
lateral_moves: []
handoff: ""
guacamole_connections:
  - hostname: fw-target
    protocol: rdp
    ip: "198.51.100.1"
    port: 3389
    cred_ref: cred-001
    proxy: null
    recording: true
    status: active
socks_proxies: []
listeners: []
EOF
run_test "valid guacamole_connections accepted" "$GUAC_VALID" 0

# Invalid protocol
GUAC_BAD_PROTO="$TMPDIR/guac-bad-proto.yaml"
cat > "$GUAC_BAD_PROTO" << 'EOF'
metadata:
  id: test-guac-bp
  operator: tester
phase: recon
targets: []
agents: []
cred_refs: []
findings: []
persistence: []
lateral_moves: []
handoff: ""
guacamole_connections:
  - hostname: host-a
    protocol: telnet
    ip: "198.51.100.1"
    port: 23
    status: active
EOF
run_test "invalid guac protocol fails" "$GUAC_BAD_PROTO" 1

# Invalid port
GUAC_BAD_PORT="$TMPDIR/guac-bad-port.yaml"
cat > "$GUAC_BAD_PORT" << 'EOF'
metadata:
  id: test-guac-bport
  operator: tester
phase: recon
targets: []
agents: []
cred_refs: []
findings: []
persistence: []
lateral_moves: []
handoff: ""
guacamole_connections:
  - hostname: host-a
    protocol: rdp
    ip: "198.51.100.1"
    port: 99999
    status: active
EOF
run_test "invalid guac port fails" "$GUAC_BAD_PORT" 1

# Invalid connection status
GUAC_BAD_STATUS="$TMPDIR/guac-bad-status.yaml"
cat > "$GUAC_BAD_STATUS" << 'EOF'
metadata:
  id: test-guac-bs
  operator: tester
phase: recon
targets: []
agents: []
cred_refs: []
findings: []
persistence: []
lateral_moves: []
handoff: ""
guacamole_connections:
  - hostname: host-a
    protocol: ssh
    ip: "198.51.100.1"
    port: 22
    status: pending
EOF
run_test "invalid guac connection status fails" "$GUAC_BAD_STATUS" 1

# Broken cred_ref cross-reference
GUAC_BAD_CRED="$TMPDIR/guac-bad-cred.yaml"
cat > "$GUAC_BAD_CRED" << 'EOF'
metadata:
  id: test-guac-bc
  operator: tester
phase: recon
targets: []
agents: []
cred_refs:
  - ref_id: cred-001
    tuoni_cred_id: tc-abc
findings: []
persistence: []
lateral_moves: []
handoff: ""
guacamole_connections:
  - hostname: host-a
    protocol: rdp
    ip: "198.51.100.1"
    port: 3389
    cred_ref: cred-999
    status: active
EOF
run_test "guac broken cred_ref cross-ref fails" "$GUAC_BAD_CRED" 1

# Valid socks_proxies
SOCKS_VALID="$TMPDIR/socks-valid.yaml"
cat > "$SOCKS_VALID" << 'EOF'
metadata:
  id: test-socks
  operator: tester
phase: recon
targets: []
agents:
  - agent_id: agent-fw
    payload_id: pl-001
cred_refs: []
findings: []
persistence: []
lateral_moves: []
handoff: ""
socks_proxies:
  - id: socks-fw
    foothold_agent: agent-fw
    listen_host: "127.0.0.1"
    listen_port: 1080
    type: socks5
    status: active
    reachable_nets:
      - "198.51.100.0/24"
EOF
run_test "valid socks_proxies accepted" "$SOCKS_VALID" 0

# Invalid proxy type
SOCKS_BAD_TYPE="$TMPDIR/socks-bad-type.yaml"
cat > "$SOCKS_BAD_TYPE" << 'EOF'
metadata:
  id: test-socks-bt
  operator: tester
phase: recon
targets: []
agents: []
cred_refs: []
findings: []
persistence: []
lateral_moves: []
handoff: ""
socks_proxies:
  - id: socks-bad
    foothold_agent: agent-x
    listen_host: "127.0.0.1"
    listen_port: 1080
    type: http
    status: active
EOF
run_test "invalid socks proxy type fails" "$SOCKS_BAD_TYPE" 1

# Duplicate proxy id
SOCKS_DUP="$TMPDIR/socks-dup.yaml"
cat > "$SOCKS_DUP" << 'EOF'
metadata:
  id: test-socks-dup
  operator: tester
phase: recon
targets: []
agents: []
cred_refs: []
findings: []
persistence: []
lateral_moves: []
handoff: ""
socks_proxies:
  - id: socks-dup
    foothold_agent: agent-x
    listen_host: "127.0.0.1"
    listen_port: 1080
    type: socks5
    status: active
  - id: socks-dup
    foothold_agent: agent-y
    listen_host: "127.0.0.1"
    listen_port: 1081
    type: socks5
    status: active
EOF
run_test "duplicate socks proxy id fails" "$SOCKS_DUP" 1

# Broken proxy cross-reference in guac connection
GUAC_BAD_PROXY="$TMPDIR/guac-bad-proxy.yaml"
cat > "$GUAC_BAD_PROXY" << 'EOF'
metadata:
  id: test-guac-bp
  operator: tester
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
    foothold_agent: agent-x
    listen_host: "127.0.0.1"
    listen_port: 1080
    type: socks5
    status: active
guacamole_connections:
  - hostname: host-a
    protocol: rdp
    ip: "198.51.100.1"
    port: 3389
    proxy: socks-nonexistent
    status: active
EOF
run_test "guac broken proxy cross-ref fails" "$GUAC_BAD_PROXY" 1

# Valid listeners
LISTENER_VALID="$TMPDIR/listener-valid.yaml"
cat > "$LISTENER_VALID" << 'EOF'
metadata:
  id: test-listener
  operator: tester
phase: recon
targets: []
agents: []
cred_refs: []
findings: []
persistence: []
lateral_moves: []
handoff: ""
listeners:
  - id: https-primary
    type: reverse_https
    port: 443
    uris: ["/api/health"]
    sleep: 30
    jitter: 15
    tls_cert: letsencrypt
    status: active
  - id: smb-relay
    type: bind_smb
    pipe_name: "\\spoolss"
    status: active
EOF
run_test "valid listeners accepted" "$LISTENER_VALID" 0

# Invalid listener type
LISTENER_BAD_TYPE="$TMPDIR/listener-bad-type.yaml"
cat > "$LISTENER_BAD_TYPE" << 'EOF'
metadata:
  id: test-listener-bt
  operator: tester
phase: recon
targets: []
agents: []
cred_refs: []
findings: []
persistence: []
lateral_moves: []
handoff: ""
listeners:
  - id: bad-listener
    type: reverse_websocket
    status: active
EOF
run_test "invalid listener type fails" "$LISTENER_BAD_TYPE" 1

# Invalid listener status
LISTENER_BAD_STATUS="$TMPDIR/listener-bad-status.yaml"
cat > "$LISTENER_BAD_STATUS" << 'EOF'
metadata:
  id: test-listener-bs
  operator: tester
phase: recon
targets: []
agents: []
cred_refs: []
findings: []
persistence: []
lateral_moves: []
handoff: ""
listeners:
  - id: bad-status
    type: reverse_https
    port: 443
    status: broken
EOF
run_test "invalid listener status fails" "$LISTENER_BAD_STATUS" 1

# Duplicate listener id
LISTENER_DUP="$TMPDIR/listener-dup.yaml"
cat > "$LISTENER_DUP" << 'EOF'
metadata:
  id: test-listener-dup
  operator: tester
phase: recon
targets: []
agents: []
cred_refs: []
findings: []
persistence: []
lateral_moves: []
handoff: ""
listeners:
  - id: dup-id
    type: reverse_https
    port: 443
    status: active
  - id: dup-id
    type: reverse_http
    port: 8080
    status: active
EOF
run_test "duplicate listener id fails" "$LISTENER_DUP" 1

# Invalid jitter (> 100)
LISTENER_BAD_JITTER="$TMPDIR/listener-bad-jitter.yaml"
cat > "$LISTENER_BAD_JITTER" << 'EOF'
metadata:
  id: test-listener-bj
  operator: tester
phase: recon
targets: []
agents: []
cred_refs: []
findings: []
persistence: []
lateral_moves: []
handoff: ""
listeners:
  - id: jitter-bad
    type: reverse_https
    port: 443
    jitter: 150
    status: active
EOF
run_test "listener jitter > 100 fails" "$LISTENER_BAD_JITTER" 1

# Existing files still valid with new optional sections omitted
run_test "original valid file still passes (backward compat)" "$VALID" 0

# Full example with all three new sections
FULL_GUAC="$TMPDIR/full-guac.yaml"
cat > "$FULL_GUAC" << 'EOF'
metadata:
  id: test-full-guac
  operator: tester
phase: lateral
targets:
  - hostname: host-a
    approved: true
agents:
  - agent_id: agent-a
    payload_id: pl-001
cred_refs:
  - ref_id: cred-001
    tuoni_cred_id: tc-abc
findings: []
persistence:
  - target: host-a
    method: cron
lateral_moves: []
handoff: ""
guacamole_connections:
  - hostname: host-a
    protocol: rdp
    ip: "198.51.100.1"
    port: 3389
    cred_ref: cred-001
    proxy: socks-a
    recording: true
    status: active
socks_proxies:
  - id: socks-a
    foothold_agent: agent-a
    listen_host: "127.0.0.1"
    listen_port: 1080
    type: socks5
    status: active
    reachable_nets:
      - "198.51.100.0/24"
listeners:
  - id: https-main
    type: reverse_https
    port: 443
    sleep: 30
    jitter: 10
    status: active
  - id: smb-lat
    type: bind_smb
    status: active
EOF
run_test "full engagement with all guac sections passes" "$FULL_GUAC" 0

echo ""
echo "Results: $PASS passed, $FAIL failed"
exit "$FAIL"
