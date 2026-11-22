#!/usr/bin/env bash
# Discover all skills by reading SKILL.md frontmatter.
# Output: name | modes | description (one line per skill)
set -euo pipefail

project_dir="${CLAUDE_PROJECT_DIR:-.}"
skills_dir="$project_dir/.claude/skills"

if [ ! -d "$skills_dir" ]; then
  echo "ERROR: skills directory not found: $skills_dir" >&2
  exit 1
fi

find "$skills_dir" -name "SKILL.md" -type f -print0 | sort -z | while IFS= read -r -d '' file; do
  name=""
  modes=""
  description=""
  in_frontmatter=0

  while IFS= read -r line; do
    # Detect frontmatter boundaries
    if [ "$line" = "---" ]; then
      if [ "$in_frontmatter" -eq 0 ]; then
        in_frontmatter=1
        continue
      else
        break
      fi
    fi

    [ "$in_frontmatter" -eq 0 ] && continue

    # Parse frontmatter fields
    case "$line" in
      name:*)
        name="${line#name:}"
        name="${name# }"
        name="${name%\"}"
        name="${name#\"}"
        ;;
      description:*)
        description="${line#description:}"
        description="${description# }"
        description="${description%\"}"
        description="${description#\"}"
        ;;
      modes:*)
        modes="${line#modes:}"
        modes="${modes# }"
        # Strip brackets for clean display
        modes="${modes#\[}"
        modes="${modes%\]}"
        ;;
    esac
  done < "$file"

  [ -z "$name" ] && continue

  if [ -z "$modes" ]; then
    modes="all"
  fi

  printf '%s | %s | %s\n' "$name" "$modes" "$description"
done
