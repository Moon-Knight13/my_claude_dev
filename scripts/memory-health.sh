#!/usr/bin/env bash
# memory-health.sh — validate Claude Code memory directory integrity
#
# Checks:
#   1. Broken [[wiki-links]] (referenced memories that don't exist as files)
#   2. Orphan memory files (on disk but missing from MEMORY.md index)
#   3. Stale project-type memories (>30 days without update)
#   4. MEMORY.md line count under 200
#   5. Duplicate name: slugs across memory files
#
# Exit 0 = healthy, exit 1 = issues found
#
# T3 Scheduled Task setup:
#   schedule_task({
#     name: "memory-health-check",
#     schedule: "0 6 * * 1",          # weekly Monday 06:00 UTC
#     prompt: "Run scripts/memory-health.sh and report findings. If exit 1, summarize issues."
#   })

set -euo pipefail

MEMORY_DIR="${MEMORY_DIR:-$HOME/.claude/projects/-home-chris-Documents-my-claude-dev/memory}"
INDEX="$MEMORY_DIR/MEMORY.md"

issues=0
warnings=0

red() { printf '\033[1;31m%s\033[0m\n' "$1"; }
yellow() { printf '\033[1;33m%s\033[0m\n' "$1"; }
green() { printf '\033[1;32m%s\033[0m\n' "$1"; }
header() { printf '\n\033[1;36m=== %s ===\033[0m\n' "$1"; }

if [[ ! -d "$MEMORY_DIR" ]]; then
    red "FATAL: memory directory not found: $MEMORY_DIR"
    exit 1
fi

if [[ ! -f "$INDEX" ]]; then
    red "FATAL: MEMORY.md index not found: $INDEX"
    exit 1
fi

# ---------- 1. Broken [[wiki-links]] ----------
header "Broken wiki-links"

declare -A existing_slugs
for f in "$MEMORY_DIR"/*.md; do
    [[ "$(basename "$f")" == "MEMORY.md" ]] && continue
    slug="$(basename "$f" .md)"
    existing_slugs["$slug"]=1
done

broken_links=0
while IFS= read -r file; do
    [[ "$(basename "$file")" == "MEMORY.md" ]] && continue
    while IFS= read -r link; do
        if [[ -z "${existing_slugs[$link]+x}" ]]; then
            yellow "  $(basename "$file"): [[${link}]] -> no matching file"
            ((broken_links++)) || true
        fi
    done < <(grep -oP '\[\[\K[^\]]+' "$file" 2>/dev/null || true)
done < <(find "$MEMORY_DIR" -maxdepth 1 -name '*.md' -type f)

if ((broken_links > 0)); then
    red "  $broken_links broken link(s) found"
    ((issues += broken_links)) || true
else
    green "  No broken links"
fi

# ---------- 2. Orphan files ----------
header "Orphan memory files"

indexed_files=()
while IFS= read -r ref; do
    indexed_files+=("$ref")
done < <(grep -oP '\([^)]+\.md\)' "$INDEX" | tr -d '()' | sort -u)

orphans=0
for f in "$MEMORY_DIR"/*.md; do
    base="$(basename "$f")"
    [[ "$base" == "MEMORY.md" ]] && continue

    found=0
    for indexed in "${indexed_files[@]}"; do
        if [[ "$indexed" == "$base" ]]; then
            found=1
            break
        fi
    done

    if ((found == 0)); then
        yellow "  $base — on disk but not in MEMORY.md"
        ((orphans++)) || true
    fi
done

if ((orphans > 0)); then
    red "  $orphans orphan(s) found"
    ((issues += orphans)) || true
else
    green "  No orphans"
fi

# ---------- 3. Stale project memories ----------
header "Stale project memories (>30 days)"

now_epoch=$(date +%s)
stale_threshold=$((30 * 86400))
stale=0

for f in "$MEMORY_DIR"/*.md; do
    [[ "$(basename "$f")" == "MEMORY.md" ]] && continue

    mem_type=$(sed -n '/^---$/,/^---$/{ s/^  type: *//p }' "$f" | head -1)
    [[ "$mem_type" != "project" ]] && continue

    modified=$(sed -n '/^---$/,/^---$/{ s/^  modified: *//p }' "$f" | head -1 | tr -d '"')
    if [[ -z "$modified" ]]; then
        modified=$(sed -n '/^---$/,/^---$/{ s/^  originSessionDate: *//p }' "$f" | head -1 | tr -d '"')
    fi

    if [[ -z "$modified" ]]; then
        yellow "  $(basename "$f"): no modified date in frontmatter"
        ((warnings++)) || true
        continue
    fi

    mod_epoch=$(date -d "$modified" +%s 2>/dev/null || echo 0)
    if ((mod_epoch == 0)); then
        yellow "  $(basename "$f"): unparseable date '$modified'"
        ((warnings++)) || true
        continue
    fi

    age_days=$(( (now_epoch - mod_epoch) / 86400 ))
    if ((age_days > 30)); then
        yellow "  $(basename "$f"): project memory, $age_days days old"
        ((stale++)) || true
    fi
done

if ((stale > 0)); then
    red "  $stale stale project memory/memories"
    ((issues += stale)) || true
else
    green "  No stale project memories"
fi

# ---------- 4. MEMORY.md line count ----------
header "MEMORY.md size"

line_count=$(wc -l < "$INDEX")
if ((line_count >= 200)); then
    red "  MEMORY.md is $line_count lines (limit: 200)"
    ((issues++)) || true
else
    green "  $line_count lines (limit: 200)"
fi

# ---------- 5. Duplicate name slugs ----------
header "Duplicate name slugs"

declare -A slug_sources
dupes=0

for f in "$MEMORY_DIR"/*.md; do
    [[ "$(basename "$f")" == "MEMORY.md" ]] && continue

    name_slug=$(sed -n '/^---$/,/^---$/{ s/^name: *//p }' "$f" | head -1 | tr -d '"')
    [[ -z "$name_slug" ]] && continue

    if [[ -n "${slug_sources[$name_slug]+x}" ]]; then
        yellow "  Duplicate slug '$name_slug': ${slug_sources[$name_slug]} and $(basename "$f")"
        ((dupes++)) || true
    else
        slug_sources["$name_slug"]="$(basename "$f")"
    fi
done

if ((dupes > 0)); then
    red "  $dupes duplicate slug(s)"
    ((issues += dupes)) || true
else
    green "  No duplicate slugs"
fi

# ---------- Summary ----------
header "Summary"
total_files=$(find "$MEMORY_DIR" -maxdepth 1 -name '*.md' -not -name 'MEMORY.md' -type f | wc -l)
printf "  Memory files: %d\n" "$total_files"
printf "  Index lines:  %d / 200\n" "$line_count"
printf "  Issues:       %d\n" "$issues"
printf "  Warnings:     %d\n" "$warnings"

if ((issues > 0)); then
    red "UNHEALTHY — $issues issue(s) need attention"
    exit 1
else
    green "HEALTHY"
    exit 0
fi
