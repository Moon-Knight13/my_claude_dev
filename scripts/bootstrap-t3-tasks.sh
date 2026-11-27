#!/usr/bin/env bash
# Bootstrap T3 scheduled tasks from config/t3-scheduled-tasks.yaml.
#
# Reads task definitions from the YAML config (source of truth) and creates
# matching scheduled tasks in T3 via a Claude thread that calls the MCP tools.
# Idempotent: tasks whose title already exists are skipped.
#
# Prerequisites:
#   - T3 Code server running (t3 or t3 serve)
#   - yq installed (https://github.com/mikefarah/yq/)
#   - my_claude_dev project registered in T3
#
# Usage:
#   bash scripts/bootstrap-t3-tasks.sh              # dry run (shows tasks)
#   APPLY=true bash scripts/bootstrap-t3-tasks.sh   # create missing tasks
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG="${CONFIG:-$REPO_ROOT/config/t3-scheduled-tasks.yaml}"
APPLY="${APPLY:-false}"
PROJECT_PATH="${PROJECT_PATH:-$REPO_ROOT}"

# --- Preflight ---------------------------------------------------------------

for cmd in yq t3; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: $cmd is required but not found." >&2
    exit 1
  fi
done

if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: Config not found: $CONFIG" >&2
  exit 1
fi

# Validate YAML has tasks
TASK_COUNT="$(yq '.tasks | length' "$CONFIG")"
if [[ "$TASK_COUNT" -eq 0 ]]; then
  echo "No tasks defined in $CONFIG"
  exit 0
fi

echo "Config:     $CONFIG"
echo "Tasks:      $TASK_COUNT"
echo "Apply mode: $APPLY"
echo

# --- Extract task definitions ------------------------------------------------

declare -a TASK_NAMES=()
declare -A TASK_TITLES=()
declare -A TASK_SCHEDULE_TYPES=()
declare -A TASK_SCHEDULE_TIME=()
declare -A TASK_SCHEDULE_INTERVAL=()
declare -A TASK_FRESH_SESSION=()
declare -A TASK_BIND_THREAD=()
declare -A TASK_PROMPTS=()

while IFS= read -r name; do
  TASK_NAMES+=("$name")
  TASK_TITLES["$name"]="$(yq ".tasks.$name.title" "$CONFIG")"
  TASK_SCHEDULE_TYPES["$name"]="$(yq ".tasks.$name.schedule.type" "$CONFIG")"
  TASK_SCHEDULE_TIME["$name"]="$(yq ".tasks.$name.schedule.timeOfDay // \"\"" "$CONFIG")"
  TASK_SCHEDULE_INTERVAL["$name"]="$(yq ".tasks.$name.schedule.everyMs // 0" "$CONFIG")"
  TASK_FRESH_SESSION["$name"]="$(yq ".tasks.$name.freshSession // false" "$CONFIG")"
  TASK_BIND_THREAD["$name"]="$(yq ".tasks.$name.bindToCurrentThread // false" "$CONFIG")"
  TASK_PROMPTS["$name"]="$(yq ".tasks.$name.prompt" "$CONFIG")"
done < <(yq '.tasks | keys | .[]' "$CONFIG")

# --- Display plan ------------------------------------------------------------

echo "Scheduled tasks to bootstrap:"
echo "─────────────────────────────────────────────────────"
for name in "${TASK_NAMES[@]}"; do
  stype="${TASK_SCHEDULE_TYPES[$name]}"
  if [[ "$stype" == "fixed_time" ]]; then
    schedule_desc="daily at ${TASK_SCHEDULE_TIME[$name]}"
  elif [[ "$stype" == "interval" ]]; then
    ms="${TASK_SCHEDULE_INTERVAL[$name]}"
    hours=$(( ms / 3600000 ))
    schedule_desc="every ${hours}h"
  else
    schedule_desc="$stype"
  fi
  printf "  %-20s  %-40s  %s\n" "$name" "${TASK_TITLES[$name]}" "$schedule_desc"
done
echo

if [[ "$APPLY" != "true" ]]; then
  echo "Dry run only. Set APPLY=true to create tasks in T3."
  exit 0
fi

# --- Build agent prompt ------------------------------------------------------
# Single prompt sent to a T3 thread. The thread lists existing tasks, compares
# titles, and creates missing ones. This keeps all MCP tool calls in one place.

build_agent_prompt() {
  cat <<'PREAMBLE'
You are bootstrapping T3 scheduled tasks from config. Follow these steps exactly:

1. Call list_scheduled_tasks to get all existing tasks.
2. For each task below, check if a task with the same title already exists.
   - If it exists: print "SKIP: <title>" and do nothing.
   - If missing: create it with schedule_task using the exact parameters shown, then print "CREATED: <title>".
3. After processing all tasks, print a summary line: "Bootstrap complete: X created, Y skipped, Z errors."

Do NOT modify or delete existing tasks. Only create missing ones.

PREAMBLE

  echo "Tasks to bootstrap:"
  echo

  for name in "${TASK_NAMES[@]}"; do
    echo "### Task: $name"
    echo "Title: ${TASK_TITLES[$name]}"
    echo "Schedule type: ${TASK_SCHEDULE_TYPES[$name]}"
    if [[ "${TASK_SCHEDULE_TYPES[$name]}" == "fixed_time" ]]; then
      echo "timeOfDay: ${TASK_SCHEDULE_TIME[$name]}"
    elif [[ "${TASK_SCHEDULE_TYPES[$name]}" == "interval" ]]; then
      echo "everyMs: ${TASK_SCHEDULE_INTERVAL[$name]}"
    fi
    echo "freshSession: ${TASK_FRESH_SESSION[$name]}"
    echo "bindToCurrentThread: ${TASK_BIND_THREAD[$name]}"
    echo "Prompt:"
    echo '```'
    echo "${TASK_PROMPTS[$name]}"
    echo '```'
    echo
  done
}

# --- Execute via T3 thread ---------------------------------------------------

echo "Launching T3 bootstrap thread..."

PROMPT="$(build_agent_prompt)"

OUTPUT="$(t3 thread start \
  --title "Bootstrap scheduled tasks" \
  --wait \
  "$PROJECT_PATH" \
  "$PROMPT" 2>&1)" || {
  echo "ERROR: T3 thread failed." >&2
  echo "$OUTPUT" >&2
  exit 1
}

echo
echo "$OUTPUT"
echo
echo "Bootstrap complete. Verify with: list_scheduled_tasks in any T3 thread."
