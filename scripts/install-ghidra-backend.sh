#!/usr/bin/env bash
set -euo pipefail

# On-demand Ghidra backend for rea-mcp.
# Downloads Ghidra + Adoptium JDK 21 to $GHIDRA_BASE (default: ~/.local/share/ghidra).
# Sets GHIDRA_INSTALL_DIR and JAVA_HOME, validates with `rea doctor`.
# Idempotent: re-run is a no-op when versions match.

GHIDRA_VERSION="${GHIDRA_VERSION:-12.1.4}"
GHIDRA_DATE="${GHIDRA_DATE:-20260921}"
JDK_VERSION="${JDK_VERSION:-21.0.7+6}"
GHIDRA_BASE="${GHIDRA_BASE:-${HOME}/.local/share/ghidra}"
GHIDRA_SHA256="${GHIDRA_SHA256:-ddac49f903da9d5bac833e5cc79395098b9c33cfd3279be5f31bd00387d2d4db}"

ARCH="$(uname -m)"
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"

case "$ARCH" in
  x86_64)  JDK_ARCH="x64" ;;
  aarch64) JDK_ARCH="aarch64" ;;
  *)
    echo "ERROR: unsupported architecture: $ARCH"
    exit 1
    ;;
esac

GHIDRA_DIR="${GHIDRA_BASE}/ghidra_${GHIDRA_VERSION}_PUBLIC"
JDK_DIR="${GHIDRA_BASE}/jdk-${JDK_VERSION}"
MARKER_FILE="${GHIDRA_BASE}/.installed-version"

export GHIDRA_INSTALL_DIR="$GHIDRA_DIR"
export JAVA_HOME="$JDK_DIR"
export PATH="${JAVA_HOME}/bin:${PATH}"

if [[ -f "$MARKER_FILE" ]] && grep -qF "ghidra=${GHIDRA_VERSION} jdk=${JDK_VERSION}" "$MARKER_FILE"; then
  if [[ -d "$GHIDRA_DIR" ]] && [[ -d "$JDK_DIR" ]]; then
    echo "Ghidra ${GHIDRA_VERSION} + JDK ${JDK_VERSION} already installed."
    echo "GHIDRA_INSTALL_DIR=${GHIDRA_INSTALL_DIR}"
    echo "JAVA_HOME=${JAVA_HOME}"
    exit 0
  fi
fi

mkdir -p "$GHIDRA_BASE"

install_jdk() {
  if [[ -d "$JDK_DIR" ]] && "$JDK_DIR/bin/java" -version >/dev/null 2>&1; then
    echo "JDK ${JDK_VERSION} already present."
    return 0
  fi

  local jdk_version_url="${JDK_VERSION//+/%2B}"
  local jdk_url="https://github.com/adoptium/temurin21-binaries/releases/download/jdk-${jdk_version_url}/OpenJDK21U-jdk_${JDK_ARCH}_${OS}_hotspot_${JDK_VERSION//+/_}.tar.gz"
  local jdk_tar="${GHIDRA_BASE}/jdk.tar.gz"

  echo "Downloading Adoptium JDK ${JDK_VERSION} (${JDK_ARCH})..."
  curl -fSL --retry 3 --retry-delay 5 -o "$jdk_tar" "$jdk_url"

  echo "Extracting JDK..."
  tar -xzf "$jdk_tar" -C "$GHIDRA_BASE"
  rm -f "$jdk_tar"

  "$JDK_DIR/bin/java" -version
  echo "JDK installed at ${JDK_DIR}"
}

install_ghidra() {
  if [[ -d "$GHIDRA_DIR" ]] && [[ -f "$GHIDRA_DIR/support/analyzeHeadless" ]]; then
    echo "Ghidra ${GHIDRA_VERSION} already present."
    return 0
  fi

  local ghidra_url="https://github.com/NationalSecurityAgency/ghidra/releases/download/Ghidra_${GHIDRA_VERSION}_build/ghidra_${GHIDRA_VERSION}_PUBLIC_${GHIDRA_DATE}.zip"
  local ghidra_zip="${GHIDRA_BASE}/ghidra.zip"

  echo "Downloading Ghidra ${GHIDRA_VERSION}..."
  curl -fSL --retry 3 --retry-delay 5 -o "$ghidra_zip" "$ghidra_url"

  if command -v sha256sum >/dev/null 2>&1; then
    local actual_sha
    actual_sha="$(sha256sum "$ghidra_zip" | awk '{print $1}')"
    if [[ "$actual_sha" != "$GHIDRA_SHA256" ]]; then
      echo "ERROR: SHA256 mismatch."
      echo "  expected: ${GHIDRA_SHA256}"
      echo "  actual:   ${actual_sha}"
      rm -f "$ghidra_zip"
      exit 1
    fi
    echo "SHA256 verified."
  else
    echo "WARN: sha256sum not available, skipping integrity check."
  fi

  echo "Extracting Ghidra..."
  unzip -qo "$ghidra_zip" -d "$GHIDRA_BASE"
  rm -f "$ghidra_zip"

  chmod +x "$GHIDRA_DIR/support/analyzeHeadless"
  echo "Ghidra installed at ${GHIDRA_DIR}"
}

install_jdk
install_ghidra

echo "ghidra=${GHIDRA_VERSION} jdk=${JDK_VERSION}" > "$MARKER_FILE"

echo ""
echo "=== Environment ==="
echo "GHIDRA_INSTALL_DIR=${GHIDRA_INSTALL_DIR}"
echo "JAVA_HOME=${JAVA_HOME}"
echo ""
echo "Add to shell profile:"
echo "  export GHIDRA_INSTALL_DIR=\"${GHIDRA_INSTALL_DIR}\""
echo "  export JAVA_HOME=\"${JAVA_HOME}\""
echo "  export PATH=\"\${JAVA_HOME}/bin:\${PATH}\""

if command -v npx >/dev/null 2>&1; then
  echo ""
  echo "=== REA Doctor ==="
  npx -y rea-agents@6.8.0 doctor 2>&1 || echo "WARN: rea doctor returned non-zero (Ghidra may need first-run init)."
fi

echo ""
echo "Done. Run 'rea doctor' to verify backend connectivity."
