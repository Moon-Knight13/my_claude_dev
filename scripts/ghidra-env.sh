#!/usr/bin/env bash
# Source this file to set Ghidra + JDK environment for rea-mcp.
# Usage: source scripts/ghidra-env.sh
#   or:  eval "$(scripts/ghidra-env.sh --export)"

GHIDRA_VERSION="${GHIDRA_VERSION:-12.1.4}"
JDK_VERSION="${JDK_VERSION:-21.0.7+6}"
GHIDRA_BASE="${GHIDRA_BASE:-${HOME}/.local/share/ghidra}"

_ghidra_dir="${GHIDRA_BASE}/ghidra_${GHIDRA_VERSION}_PUBLIC"
_jdk_dir="${GHIDRA_BASE}/jdk-${JDK_VERSION}"

if [[ ! -d "$_ghidra_dir" ]]; then
  echo "Ghidra not installed. Run: scripts/install-ghidra-backend.sh" >&2
  # shellcheck disable=SC2317
  return 1 2>/dev/null || exit 1
fi

if [[ "${1:-}" == "--export" ]]; then
  echo "export GHIDRA_INSTALL_DIR=\"${_ghidra_dir}\""
  echo "export JAVA_HOME=\"${_jdk_dir}\""
  echo "export PATH=\"${_jdk_dir}/bin:\${PATH}\""
else
  export GHIDRA_INSTALL_DIR="$_ghidra_dir"
  export JAVA_HOME="$_jdk_dir"
  export PATH="${_jdk_dir}/bin:${PATH}"
fi
