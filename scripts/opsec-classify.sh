#!/usr/bin/env bash
# opsec-classify.sh — Look up OPSEC metadata for a tuoni-plugins command.
#
# Usage:
#   bash scripts/opsec-classify.sh <command_name>
#   bash scripts/opsec-classify.sh --json <command_name>
#   bash scripts/opsec-classify.sh --batch <cmd1> <cmd2> ...
#   bash scripts/opsec-classify.sh --summary <cmd1> <cmd2> ...
#
# Modes:
#   (default)   Human-readable single-command output
#   --json      JSON output for single command (machine consumption)
#   --batch     JSON array of all named commands
#   --summary   One-line summary: "2 CRITICAL, 1 HIGH — confirm required: 3"
#
# Exit codes: 0 = found, 1 = not found, 2 = missing dependency
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLASSIFIER="${OPSEC_CLASSIFIER:-${SCRIPT_DIR}/../config/opsec-classifier.yaml}"

if [[ ! -f "$CLASSIFIER" ]]; then
    echo "ERROR: Classifier not found at $CLASSIFIER" >&2
    exit 2
fi

if ! python3 -c "import yaml" 2>/dev/null; then
    echo "ERROR: python3 + PyYAML required" >&2
    exit 2
fi

MODE="human"
COMMANDS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --json)    MODE="json"; shift ;;
        --batch)   MODE="batch"; shift ;;
        --summary) MODE="summary"; shift ;;
        --help|-h)
            echo "Usage: $0 [--json|--batch|--summary] <command> [command ...]"
            exit 0 ;;
        *)         COMMANDS+=("$1"); shift ;;
    esac
done

if [[ ${#COMMANDS[@]} -eq 0 ]]; then
    echo "ERROR: No command name provided" >&2
    echo "Usage: $0 [--json|--batch|--summary] <command> [command ...]" >&2
    exit 1
fi

# Pass mode and commands to Python for YAML lookup
python3 -I - "$CLASSIFIER" "$MODE" "${COMMANDS[@]}" << 'PYEOF'
import sys, yaml, json

classifier_path = sys.argv[1]
mode = sys.argv[2]
command_names = sys.argv[3:]

with open(classifier_path) as f:
    data = yaml.safe_load(f)

commands = data.get("commands", {})
ratings = data.get("ratings", {})
surfaces = data.get("detection_surfaces", {})


def lookup(name):
    cmd = commands.get(name)
    if cmd is None:
        return None
    return {
        "command": name,
        "description": cmd.get("description", ""),
        "opsec_rating": cmd.get("opsec_rating", "unknown"),
        "mitre_tactic": cmd.get("mitre_tactic", ""),
        "mitre_technique": cmd.get("mitre_technique", ""),
        "detection_surface": cmd.get("detection_surface", []),
        "detection_descriptions": {
            s: surfaces.get(s, "") for s in cmd.get("detection_surface", [])
        },
        "alternatives": cmd.get("alternatives", []),
        "requires_confirmation": cmd.get("requires_confirmation", False),
    }


if mode == "human":
    name = command_names[0]
    info = lookup(name)
    if info is None:
        print(f"ERROR: Command not found: {name}", file=sys.stderr)
        sys.exit(1)

    r = info["opsec_rating"]
    rating_meta = ratings.get(r, {})
    colour_map = {"critical": "\033[91m", "high": "\033[93m",
                  "medium": "\033[33m", "low": "\033[92m"}
    reset = "\033[0m"
    c = colour_map.get(r, "")

    print(f"Command:       {info['command']}")
    print(f"Description:   {info['description']}")
    print(f"OPSEC Rating:  {c}{r.upper()}{reset}")
    if info["mitre_tactic"]:
        print(f"MITRE:         {info['mitre_tactic']} / {info['mitre_technique']}")
    print(f"Confirmation:  {'REQUIRED' if info['requires_confirmation'] else 'not required'}")
    print()
    print("Detection surfaces:")
    for s in info["detection_surface"]:
        desc = surfaces.get(s, "")
        print(f"  - {s}: {desc}")
    if info["alternatives"]:
        print()
        print("Alternatives:")
        for a in info["alternatives"]:
            print(f"  - {a}")

elif mode == "json":
    name = command_names[0]
    info = lookup(name)
    if info is None:
        print(json.dumps({"error": f"Command not found: {name}"}))
        sys.exit(1)
    print(json.dumps(info, indent=2))

elif mode == "batch":
    results = []
    for name in command_names:
        info = lookup(name)
        if info is None:
            results.append({"command": name, "error": "not found"})
        else:
            results.append(info)
    print(json.dumps(results, indent=2))

elif mode == "summary":
    counts = {"critical": 0, "high": 0, "medium": 0, "low": 0}
    confirm_count = 0
    not_found = []
    for name in command_names:
        info = lookup(name)
        if info is None:
            not_found.append(name)
            continue
        r = info["opsec_rating"]
        counts[r] = counts.get(r, 0) + 1
        if info["requires_confirmation"]:
            confirm_count += 1

    parts = []
    for level in ("critical", "high", "medium", "low"):
        if counts.get(level, 0) > 0:
            parts.append(f"{counts[level]} {level.upper()}")
    summary = ", ".join(parts) if parts else "0 commands"
    print(f"{summary} — confirm required: {confirm_count}")
    if not_found:
        print(f"Unknown: {', '.join(not_found)}", file=sys.stderr)
        sys.exit(1)
PYEOF
