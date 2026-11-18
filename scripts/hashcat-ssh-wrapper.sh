#!/usr/bin/env bash
# Wrapper: run hashcat on Kali spoke via SSH.
# Detects local temp file paths in args, copies them to Kali first,
# then runs hashcat remotely with the Kali-local path.
set -euo pipefail

KALI_TMP="$(ssh kali 'mktemp -d /tmp/hashcat-mcp.XXXXXX')"
args=()
files_to_cleanup=()

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

# Cleanup remote temp files and temp dir
# printf '%q' quotes the path on the client before it reaches the remote shell;
# the client-side expansion SC2029 warns about is intentional here.
for f in "${files_to_cleanup[@]}"; do
    # shellcheck disable=SC2029
    ssh kali "rm -f $(printf '%q' "$f")" 2>/dev/null || true
done
# shellcheck disable=SC2029
ssh kali "rm -rf $(printf '%q' "$KALI_TMP")" 2>/dev/null || true

exit $rc
