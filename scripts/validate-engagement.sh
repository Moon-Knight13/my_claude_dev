#!/usr/bin/env bash
set -euo pipefail

for p in "$HOME/.local/bin" /usr/local/bin; do
  [[ -x "$p/yq" ]] && { export PATH="$p:$PATH"; break; }
done
command -v yq >/dev/null 2>&1 || { echo "FATAL: yq not found"; exit 2; }

# Detect yq flavor: mikefarah/yq (Go, outputs raw by default) vs kislyuk/yq (Python, needs -r)
if yq --version 2>&1 | grep -qi "mikefarah\|https://github.com/mikefarah\|version v\?[34]\."; then
  _yq() { yq "$@"; }
else
  _yq() { yq -r "$@"; }
fi

usage() { echo "Usage: $0 <engagement.yaml>"; exit 2; }
[[ $# -eq 1 ]] || usage
[[ -f "$1" ]] || { echo "ERROR: file not found: $1"; exit 2; }

FILE="$1"
ERRORS=0
err() { echo "ERROR: $*"; ERRORS=$((ERRORS + 1)); }
warn() { echo "WARN: $*"; }

if ! yq '.' "$FILE" >/dev/null 2>&1; then
  echo "ERROR: invalid YAML"; exit 1
fi

_doc_type="$(_yq 'type' "$FILE")"
if [[ "$_doc_type" == "null" || "$_doc_type" == "!!null" ]]; then
  echo "ERROR: empty or null document"; exit 1
fi

REQUIRED_KEYS="metadata phase targets agents cred_refs findings persistence lateral_moves handoff"
for key in $REQUIRED_KEYS; do
  [[ "$(_yq ".$key // \"__MISSING__\"" "$FILE")" != "__MISSING__" ]] || err "missing required key: $key"
done

[[ "$(_yq '.metadata.id // ""' "$FILE")" ]] || err "metadata.id required"
[[ "$(_yq '.metadata.operator // ""' "$FILE")" ]] || err "metadata.operator required"

VALID_PHASES="targeting recon initial-access discovery priv-esc cred-harvest persist lateral collection exfil cleanup complete"
phase="$(_yq '.phase // ""' "$FILE")"
if [[ -n "$phase" ]]; then
  valid=false
  for vp in $VALID_PHASES; do [[ "$phase" == "$vp" ]] && { valid=true; break; }; done
  $valid || err "invalid phase: $phase"
fi

target_count="$(_yq '.targets | length' "$FILE" 2>/dev/null || echo 0)"
for ((i=0; i<target_count; i++)); do
  h="$(_yq ".targets[$i].hostname // \"\"" "$FILE")"
  [[ -n "$h" ]] || err "targets[$i] missing hostname"
  approved="$(_yq ".targets[$i].approved // \"\"" "$FILE")"
  if [[ "$approved" != "true" ]]; then
    warn "targets[$i] ($h) not approved — RT-TGT-001 requires explicit approval"
  fi
done

BANNED_FIELDS="password hash secret ntlm plaintext passwd cleartext credential token private_key"
cred_count="$(_yq '.cred_refs | length' "$FILE" 2>/dev/null || echo 0)"
for ((i=0; i<cred_count; i++)); do
  keys="$(_yq ".cred_refs[$i] | keys | .[]" "$FILE")"
  for k in $keys; do
    for banned in $BANNED_FIELDS; do
      if [[ "$k" == "$banned" ]]; then
        err "cred_refs[$i] contains banned field '$k' — no plaintext secrets (use tuoni_cred_id)"
      fi
    done
  done
  tcid="$(_yq ".cred_refs[$i].tuoni_cred_id // \"\"" "$FILE")"
  [[ -n "$tcid" ]] || err "cred_refs[$i] missing tuoni_cred_id"
done

agent_count="$(_yq '.agents | length' "$FILE" 2>/dev/null || echo 0)"
declare -A seen_payloads=()
for ((i=0; i<agent_count; i++)); do
  pid="$(_yq ".agents[$i].payload_id // \"\"" "$FILE")"
  if [[ -n "$pid" ]]; then
    if [[ -n "${seen_payloads[$pid]:-}" ]]; then
      err "duplicate payload_id '$pid' — RT-SIG-002 requires unique IDs"
    fi
    seen_payloads[$pid]=1
  fi
done

persist_count="$(_yq '.persistence | length' "$FILE" 2>/dev/null || echo 0)"
for ((i=0; i<persist_count; i++)); do
  [[ "$(_yq ".persistence[$i].target // \"\"" "$FILE")" ]] || err "persistence[$i] missing target"
  [[ "$(_yq ".persistence[$i].method // \"\"" "$FILE")" ]] || err "persistence[$i] missing method"
done

lat_count="$(_yq '.lateral_moves | length' "$FILE" 2>/dev/null || echo 0)"
if ((lat_count > 0 && cred_count > 0)); then
  valid_refs="$(_yq '.cred_refs[].ref_id' "$FILE")"
  for ((i=0; i<lat_count; i++)); do
    cr="$(_yq ".lateral_moves[$i].cred_ref // \"\"" "$FILE")"
    if [[ -n "$cr" ]]; then
      found=false
      while IFS= read -r ref; do [[ "$cr" == "$ref" ]] && { found=true; break; }; done <<< "$valid_refs"
      $found || err "lateral_moves[$i].cred_ref '$cr' not found in cred_refs"
    fi
  done
fi

# Optional: type (engagement type — controls source priority)
eng_type="$(_yq '.type // ""' "$FILE")"
if [[ -n "$eng_type" ]]; then
  VALID_TYPES="black-box"
  type_valid=false
  for vt in $VALID_TYPES; do [[ "$eng_type" == "$vt" ]] && { type_valid=true; break; }; done
  if $type_valid; then
    echo "INFO: type: $eng_type"
  else
    err "invalid type: $eng_type (valid: $VALID_TYPES)"
  fi
fi

# Optional: guacamole_connections[]
guac_count="$(_yq '.guacamole_connections | length' "$FILE" 2>/dev/null || echo 0)"
VALID_PROTOCOLS="rdp ssh vnc"
VALID_CONN_STATUS="active removed"
for ((i=0; i<guac_count; i++)); do
  gh="$(_yq ".guacamole_connections[$i].hostname // \"\"" "$FILE")"
  [[ -n "$gh" ]] || err "guacamole_connections[$i] missing hostname"
  gp="$(_yq ".guacamole_connections[$i].protocol // \"\"" "$FILE")"
  if [[ -n "$gp" ]]; then
    pvalid=false
    for vp in $VALID_PROTOCOLS; do [[ "$gp" == "$vp" ]] && { pvalid=true; break; }; done
    $pvalid || err "guacamole_connections[$i] invalid protocol: $gp (valid: $VALID_PROTOCOLS)"
  else
    err "guacamole_connections[$i] missing protocol"
  fi
  gport="$(_yq ".guacamole_connections[$i].port // \"\"" "$FILE")"
  if [[ -n "$gport" ]]; then
    if ! [[ "$gport" =~ ^[0-9]+$ ]] || ((gport < 1 || gport > 65535)); then
      err "guacamole_connections[$i] invalid port: $gport"
    fi
  else
    err "guacamole_connections[$i] missing port"
  fi
  gs="$(_yq ".guacamole_connections[$i].status // \"\"" "$FILE")"
  if [[ -n "$gs" ]]; then
    svalid=false
    for vs in $VALID_CONN_STATUS; do [[ "$gs" == "$vs" ]] && { svalid=true; break; }; done
    $svalid || err "guacamole_connections[$i] invalid status: $gs (valid: $VALID_CONN_STATUS)"
  fi
  gcr="$(_yq ".guacamole_connections[$i].cred_ref // \"\"" "$FILE")"
  if [[ -n "$gcr" && "$gcr" != "null" && "$cred_count" -gt 0 ]]; then
    cvalid=false
    for ((j=0; j<cred_count; j++)); do
      rid="$(_yq ".cred_refs[$j].ref_id // \"\"" "$FILE")"
      [[ "$gcr" == "$rid" ]] && { cvalid=true; break; }
    done
    $cvalid || err "guacamole_connections[$i] cred_ref '$gcr' not found in cred_refs[]"
  fi
done

# Optional: socks_proxies[]
proxy_count="$(_yq '.socks_proxies | length' "$FILE" 2>/dev/null || echo 0)"
VALID_PROXY_TYPES="socks5 socks4"
VALID_PROXY_STATUS="active down"
declare -A seen_proxy_ids=()
for ((i=0; i<proxy_count; i++)); do
  pid="$(_yq ".socks_proxies[$i].id // \"\"" "$FILE")"
  [[ -n "$pid" ]] || err "socks_proxies[$i] missing id"
  if [[ -n "$pid" && -n "${seen_proxy_ids[$pid]:-}" ]]; then
    err "socks_proxies[$i] duplicate id '$pid'"
  fi
  [[ -n "$pid" ]] && seen_proxy_ids[$pid]=1
  [[ "$(_yq ".socks_proxies[$i].foothold_agent // \"\"" "$FILE")" ]] || err "socks_proxies[$i] missing foothold_agent"
  [[ "$(_yq ".socks_proxies[$i].listen_host // \"\"" "$FILE")" ]] || err "socks_proxies[$i] missing listen_host"
  pport="$(_yq ".socks_proxies[$i].listen_port // \"\"" "$FILE")"
  if [[ -n "$pport" ]]; then
    if ! [[ "$pport" =~ ^[0-9]+$ ]] || ((pport < 1 || pport > 65535)); then
      err "socks_proxies[$i] invalid listen_port: $pport"
    fi
  else
    err "socks_proxies[$i] missing listen_port"
  fi
  pt="$(_yq ".socks_proxies[$i].type // \"\"" "$FILE")"
  if [[ -n "$pt" ]]; then
    ptvalid=false
    for vt in $VALID_PROXY_TYPES; do [[ "$pt" == "$vt" ]] && { ptvalid=true; break; }; done
    $ptvalid || err "socks_proxies[$i] invalid type: $pt (valid: $VALID_PROXY_TYPES)"
  fi
  ps="$(_yq ".socks_proxies[$i].status // \"\"" "$FILE")"
  if [[ -n "$ps" ]]; then
    psvalid=false
    for vs in $VALID_PROXY_STATUS; do [[ "$ps" == "$vs" ]] && { psvalid=true; break; }; done
    $psvalid || err "socks_proxies[$i] invalid status: $ps (valid: $VALID_PROXY_STATUS)"
  fi
done

# Cross-ref: guacamole_connections[].proxy must reference a socks_proxies[].id
for ((i=0; i<guac_count; i++)); do
  gpx="$(_yq ".guacamole_connections[$i].proxy // \"\"" "$FILE")"
  if [[ -n "$gpx" && "$gpx" != "null" && "$proxy_count" -gt 0 ]]; then
    pxvalid=false
    for ((j=0; j<proxy_count; j++)); do
      pxid="$(_yq ".socks_proxies[$j].id // \"\"" "$FILE")"
      [[ "$gpx" == "$pxid" ]] && { pxvalid=true; break; }
    done
    $pxvalid || err "guacamole_connections[$i] proxy '$gpx' not found in socks_proxies[]"
  fi
done

# Optional: listeners[]
listener_count="$(_yq '.listeners | length' "$FILE" 2>/dev/null || echo 0)"
VALID_LISTENER_TYPES="reverse_https reverse_http reverse_dns bind_smb bind_tcp"
VALID_LISTENER_STATUS="active planned disabled"
declare -A seen_listener_ids=()
for ((i=0; i<listener_count; i++)); do
  lid="$(_yq ".listeners[$i].id // \"\"" "$FILE")"
  [[ -n "$lid" ]] || err "listeners[$i] missing id"
  if [[ -n "$lid" && -n "${seen_listener_ids[$lid]:-}" ]]; then
    err "listeners[$i] duplicate id '$lid'"
  fi
  [[ -n "$lid" ]] && seen_listener_ids[$lid]=1
  lt="$(_yq ".listeners[$i].type // \"\"" "$FILE")"
  if [[ -n "$lt" ]]; then
    ltvalid=false
    for vt in $VALID_LISTENER_TYPES; do [[ "$lt" == "$vt" ]] && { ltvalid=true; break; }; done
    $ltvalid || err "listeners[$i] invalid type: $lt (valid: $VALID_LISTENER_TYPES)"
  else
    err "listeners[$i] missing type"
  fi
  ls_val="$(_yq ".listeners[$i].status // \"\"" "$FILE")"
  if [[ -n "$ls_val" ]]; then
    lsvalid=false
    for vs in $VALID_LISTENER_STATUS; do [[ "$ls_val" == "$vs" ]] && { lsvalid=true; break; }; done
    $lsvalid || err "listeners[$i] invalid status: $ls_val (valid: $VALID_LISTENER_STATUS)"
  fi
  lport="$(_yq ".listeners[$i].port // \"\"" "$FILE")"
  if [[ -n "$lport" ]]; then
    if ! [[ "$lport" =~ ^[0-9]+$ ]] || ((lport < 1 || lport > 65535)); then
      err "listeners[$i] invalid port: $lport"
    fi
  fi
  ljitter="$(_yq ".listeners[$i].jitter // \"\"" "$FILE")"
  if [[ -n "$ljitter" ]]; then
    if ! [[ "$ljitter" =~ ^[0-9]+$ ]] || ((ljitter < 0 || ljitter > 100)); then
      err "listeners[$i] invalid jitter: $ljitter (must be 0-100)"
    fi
  fi
done

# Optional: kali_agent_id (Tuoni self-agent on Kali)
kali_id="$(_yq '.kali_agent_id // ""' "$FILE")"
if [[ -n "$kali_id" ]]; then
  echo "INFO: kali_agent_id: $kali_id"
fi

# Optional: cache_timestamp (pre-engagement intel cache)
cache_ts="$(_yq '.cache_timestamp // ""' "$FILE")"
if [[ -n "$cache_ts" ]]; then
  cache_epoch=$(date -d "$cache_ts" +%s 2>/dev/null || echo 0)
  now_epoch=$(date +%s)
  if [[ "$cache_epoch" -gt 0 ]]; then
    age_hours=$(( (now_epoch - cache_epoch) / 3600 ))
    if [[ $age_hours -gt 24 ]]; then
      warn "cache_timestamp is ${age_hours}h old — consider refreshing with /pre-engagement-cache"
    else
      echo "INFO: cache_timestamp: $cache_ts (${age_hours}h ago)"
    fi
  else
    warn "cache_timestamp '$cache_ts' — could not parse as date"
  fi
fi

if ((ERRORS > 0)); then
  echo "Validation failed: $ERRORS error(s)"
  exit 1
fi
echo "Validation passed"
exit 0
