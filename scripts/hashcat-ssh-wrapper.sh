#!/usr/bin/env bash
# Wrapper: run hashcat on Kali spoke via SSH.
# Detects local temp file paths in args, copies them to Kali first,
# then runs hashcat remotely with the Kali-local path.
set -euo pipefail

KALI_TMP="/tmp/hashcat-mcp"
args=()
files_to_cleanup=()

# Ensure remote temp dir exists (client-side expansion intentional)
# shellcheck disable=SC2029
ssh kali "mkdir -p $KALI_TMP" 2>/dev/null

for arg in "$@"; do
    if [[ -f "$arg" && "$arg" == /tmp/* ]]; then
        # Local temp file — copy to Kali, rewrite path
        remote_path="$KALI_TMP/$(basename "$arg")"
        scp -q "$arg" "kali:$remote_path"
        args+=("$remote_path")
        files_to_cleanup+=("$remote_path")
    else
        args+=("$arg")
    fi
done

# Run hashcat on Kali (client-side expansion intentional)
# shellcheck disable=SC2029
ssh kali hashcat "${args[@]}"
rc=$?

# Cleanup remote temp files
for f in "${files_to_cleanup[@]}"; do
    # shellcheck disable=SC2029
    ssh kali "rm -f '$f'" 2>/dev/null || true
done

exit $rc
