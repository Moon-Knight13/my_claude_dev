#!/usr/bin/env bash
set -euo pipefail

for p in "$HOME/.local/bin" /usr/local/bin; do
  [[ -x "$p/yq" ]] && { export PATH="$p:$PATH"; break; }
done
command -v yq >/dev/null 2>&1 || { echo "FATAL: yq not found"; exit 2; }

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

if [[ "$(yq -r 'type' "$FILE")" == "null" ]]; then
  echo "ERROR: empty or null document"; exit 1
fi

REQUIRED_KEYS="metadata phase targets agents cred_refs findings persistence lateral_moves handoff"
for key in $REQUIRED_KEYS; do
  [[ "$(yq -r ".$key // \"__MISSING__\"" "$FILE")" != "__MISSING__" ]] || err "missing required key: $key"
done

[[ "$(yq -r '.metadata.id // empty' "$FILE")" ]] || err "metadata.id required"
[[ "$(yq -r '.metadata.operator // empty' "$FILE")" ]] || err "metadata.operator required"

VALID_PHASES="targeting recon initial-access discovery priv-esc cred-harvest persist lateral collection exfil cleanup complete"
phase="$(yq -r '.phase // empty' "$FILE")"
if [[ -n "$phase" ]]; then
  valid=false
  for vp in $VALID_PHASES; do [[ "$phase" == "$vp" ]] && { valid=true; break; }; done
  $valid || err "invalid phase: $phase"
fi

target_count="$(yq -r '.targets | length' "$FILE" 2>/dev/null || echo 0)"
for ((i=0; i<target_count; i++)); do
  h="$(yq -r ".targets[$i].hostname // empty" "$FILE")"
  [[ -n "$h" ]] || err "targets[$i] missing hostname"
  approved="$(yq -r ".targets[$i].approved // empty" "$FILE")"
  if [[ "$approved" != "true" ]]; then
    warn "targets[$i] ($h) not approved — RT-TGT-001 requires explicit approval"
  fi
done

BANNED_FIELDS="password hash secret ntlm plaintext passwd cleartext credential token private_key"
cred_count="$(yq -r '.cred_refs | length' "$FILE" 2>/dev/null || echo 0)"
for ((i=0; i<cred_count; i++)); do
  keys="$(yq -r ".cred_refs[$i] | keys[]" "$FILE")"
  for k in $keys; do
    for banned in $BANNED_FIELDS; do
      if [[ "$k" == "$banned" ]]; then
        err "cred_refs[$i] contains banned field '$k' — no plaintext secrets (use tuoni_cred_id)"
      fi
    done
  done
  tcid="$(yq -r ".cred_refs[$i].tuoni_cred_id // empty" "$FILE")"
  [[ -n "$tcid" ]] || err "cred_refs[$i] missing tuoni_cred_id"
done

agent_count="$(yq -r '.agents | length' "$FILE" 2>/dev/null || echo 0)"
declare -A seen_payloads=()
for ((i=0; i<agent_count; i++)); do
  pid="$(yq -r ".agents[$i].payload_id // empty" "$FILE")"
  if [[ -n "$pid" ]]; then
    if [[ -n "${seen_payloads[$pid]:-}" ]]; then
      err "duplicate payload_id '$pid' — RT-SIG-002 requires unique IDs"
    fi
    seen_payloads[$pid]=1
  fi
done

persist_count="$(yq -r '.persistence | length' "$FILE" 2>/dev/null || echo 0)"
for ((i=0; i<persist_count; i++)); do
  [[ "$(yq -r ".persistence[$i].target // empty" "$FILE")" ]] || err "persistence[$i] missing target"
  [[ "$(yq -r ".persistence[$i].method // empty" "$FILE")" ]] || err "persistence[$i] missing method"
done

lat_count="$(yq -r '.lateral_moves | length' "$FILE" 2>/dev/null || echo 0)"
if ((lat_count > 0 && cred_count > 0)); then
  valid_refs="$(yq -r '.cred_refs[].ref_id' "$FILE")"
  for ((i=0; i<lat_count; i++)); do
    cr="$(yq -r ".lateral_moves[$i].cred_ref // empty" "$FILE")"
    if [[ -n "$cr" ]]; then
      found=false
      while IFS= read -r ref; do [[ "$cr" == "$ref" ]] && { found=true; break; }; done <<< "$valid_refs"
      $found || err "lateral_moves[$i].cred_ref '$cr' not found in cred_refs"
    fi
  done
fi

if ((ERRORS > 0)); then
  echo "Validation failed: $ERRORS error(s)"
  exit 1
fi
echo "Validation passed"
exit 0
