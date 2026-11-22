#!/usr/bin/env bash
# Inventory skill sizes and flag large skills missing mini variants.
# Informational only — always exits 0.
#
# Output format: path:lines (sorted descending by size)
# Skills over THRESHOLD lines without a SKILL.mini.md get flagged.
set -euo pipefail

THRESHOLD="${SKILL_SIZE_THRESHOLD:-200}"
SKILL_DIR=".claude/skills"
FOUND=0
FLAGGED=0
HAS_MINI=0

if [[ ! -d "$SKILL_DIR" ]]; then
    echo "No skills directory at $SKILL_DIR — nothing to check."
    exit 0
fi

echo "Skill Size Inventory"
echo "===================="
echo ""

# Collect full skill files and their line counts, sorted descending.
# shellcheck disable=SC2312
mapfile -t entries < <(
    find "$SKILL_DIR" -name 'SKILL.md' -print0 \
        | xargs -0 wc -l \
        | grep -v ' total$' \
        | sort -rn
)

if [[ ${#entries[@]} -eq 0 ]]; then
    echo "No SKILL.md files found."
    exit 0
fi

echo "All skills (descending by line count):"
echo ""

for entry in "${entries[@]}"; do
    # shellcheck disable=SC2155
    local_lines=$(echo "$entry" | awk '{print $1}')
    # shellcheck disable=SC2155
    local_path=$(echo "$entry" | awk '{print $2}')
    # shellcheck disable=SC2155
    local_dir=$(dirname "$local_path")
    # shellcheck disable=SC2155
    local_name=$(basename "$local_dir")
    mini_path="${local_dir}/SKILL.mini.md"

    FOUND=$((FOUND + 1))

    if [[ -f "$mini_path" ]]; then
        # shellcheck disable=SC2155
        mini_lines=$(wc -l < "$mini_path")
        HAS_MINI=$((HAS_MINI + 1))
        printf "  %4s lines  %s  (mini: %s lines, %.0f%% reduction)\n" \
            "$local_lines" "$local_path" "$mini_lines" \
            "$(awk "BEGIN {printf \"%.0f\", (1 - $mini_lines/$local_lines) * 100}")"
    elif [[ "$local_lines" -gt "$THRESHOLD" ]]; then
        FLAGGED=$((FLAGGED + 1))
        printf "  %4s lines  %s  ** NO MINI (over %s-line threshold)\n" \
            "$local_lines" "$local_path" "$THRESHOLD"
    else
        printf "  %4s lines  %s\n" "$local_lines" "$local_path"
    fi
done

echo ""
echo "---"
echo "Total: $FOUND skills, $HAS_MINI with mini variant, $FLAGGED over ${THRESHOLD} lines without mini"

if [[ "$FLAGGED" -gt 0 ]]; then
    echo ""
    echo "Consider creating SKILL.mini.md for flagged skills to reduce dispatch token cost."
fi

exit 0
