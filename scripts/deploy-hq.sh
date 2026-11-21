#!/usr/bin/env bash
# deploy-hq.sh — deploy HQ Phase 0 hooks to ~/.claude/
# Usage: deploy-hq.sh [--dry-run] [--verify-only]
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="$HOME/.claude"
HOOKS_SRC="$REPO_DIR/scripts/deploy/hooks"
SETTINGS_SRC="$REPO_DIR/scripts/deploy/settings-phase0.json"

DRY_RUN=false
VERIFY_ONLY=false

for arg in "$@"; do
    case "$arg" in
        --dry-run)     DRY_RUN=true ;;
        --verify-only) VERIFY_ONLY=true ;;
        *)             echo "Unknown flag: $arg"; exit 1 ;;
    esac
done

HOOKS=(
    master-dispatch-guard.sh
    pretooluse-ctp.sh
    tuoni-secret-guard.sh
    dispatch-wakeup-enforcer.sh
)

# --- Verify mode ---
if [[ "$VERIFY_ONLY" == "true" ]]; then
    echo "=== Verifying HQ Phase 0 deployment ==="
    errors=0

    if [[ ! -d "$TARGET/hooks" ]]; then
        echo "  FAIL  hooks directory missing"
        errors=$((errors + 1))
    else
        perms="$(stat -c %a "$TARGET/hooks" 2>/dev/null || echo "unknown")"
        if [[ "$perms" != "700" ]]; then
            echo "  FAIL  hooks dir permissions: $perms (want 700)"
            errors=$((errors + 1))
        else
            echo "  OK    hooks directory exists (700)"
        fi
    fi

    for hook in "${HOOKS[@]}"; do
        if [[ ! -x "$TARGET/hooks/$hook" ]]; then
            echo "  FAIL  $hook missing or not executable"
            errors=$((errors + 1))
        elif ! diff -q "$HOOKS_SRC/$hook" "$TARGET/hooks/$hook" >/dev/null 2>&1; then
            echo "  WARN  $hook differs from source (stale deploy?)"
            errors=$((errors + 1))
        else
            echo "  OK    $hook matches source"
        fi
    done

    if [[ -f "$TARGET/settings.json" ]]; then
        if python3 -I -c "import json; json.load(open('$TARGET/settings.json'))" 2>/dev/null; then
            echo "  OK    settings.json valid JSON"
        else
            echo "  FAIL  settings.json invalid"
            errors=$((errors + 1))
        fi
    else
        echo "  FAIL  settings.json missing"
        errors=$((errors + 1))
    fi

    if [[ "$errors" -eq 0 ]]; then
        echo "=== Verification passed ==="
    else
        echo "=== Verification failed: $errors issue(s) ==="
        exit 1
    fi
    exit 0
fi

# --- Dry run ---
if [[ "$DRY_RUN" == "true" ]]; then
    echo "=== Dry run: would deploy ==="
    echo "  Create: $TARGET/hooks/ (chmod 700)"
    for hook in "${HOOKS[@]}"; do
        echo "  Copy:   $HOOKS_SRC/$hook -> $TARGET/hooks/$hook (chmod 755)"
    done
    echo "  Merge:  hooks from $SETTINGS_SRC into $TARGET/settings.json"
    echo "=== No changes made ==="
    exit 0
fi

# --- Real deploy ---
echo "=== Deploying HQ Phase 0 to $TARGET ==="

# Create hooks directory
mkdir -p "$TARGET/hooks"
chmod 700 "$TARGET/hooks"
echo "  Created $TARGET/hooks/ (chmod 700)"

# Copy hooks
for hook in "${HOOKS[@]}"; do
    cp "$HOOKS_SRC/$hook" "$TARGET/hooks/$hook"
    chmod 755 "$TARGET/hooks/$hook"
    echo "  Deployed $hook"
done

# Merge settings.json
if [[ -f "$TARGET/settings.json" ]]; then
    python3 -I -c "
import json, sys

with open(sys.argv[1]) as f:
    existing = json.load(f)
with open(sys.argv[2]) as f:
    phase0 = json.load(f)

existing['hooks'] = phase0['hooks']

with open(sys.argv[1], 'w') as f:
    json.dump(existing, f, indent=2)
    f.write('\n')
" "$TARGET/settings.json" "$SETTINGS_SRC"
    echo "  Merged hooks into existing settings.json"
else
    cp "$SETTINGS_SRC" "$TARGET/settings.json"
    echo "  Created settings.json from phase0 template"
fi

# Verify
python3 -I -c "import json; json.load(open('$TARGET/settings.json'))" 2>/dev/null \
    || { echo "ERROR: settings.json is invalid JSON after merge"; exit 1; }

echo ""
echo "=== HQ Phase 0 deployed ==="
echo "  Kill switch: rm -rf ~/.claude/hooks/"
echo "    Removes ALL user-level hooks. Sessions return to project-level only."
echo "    Re-run deploy-hq.sh to redeploy after fixing."
