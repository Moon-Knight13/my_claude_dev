#!/usr/bin/env bash
# pretooluse-gitlab-write-guard.sh — PreToolUse Bash guard.
#
# Limits writes to the shared GitLab (git.crp.cr14.net) to our namespace.
# PAT has full API scope across ~50 developers; this hook restricts what
# Claude can touch to prevent accidental writes outside our projects.
#
# Rules:
#   1. Branch pushes: only devops-064/* or feat/devops-064-* prefixes
#   2. MR creation:   only in core/dcm-catapult project
#   3. MR comments:   allowed (low risk)
#   4. Issue/board writes: POST (create) only, no PUT/DELETE on others' items
#   5. Wiki writes:   vulns-docs namespace only
#   6. GET requests:  always pass
#
# Exit 0 with no output = allow.
# Exit 0 with deny JSON = block.
set -euo pipefail

GITLAB_HOST="git.crp.cr14.net"

input="$(cat)"
cmd="$(printf '%s' "$input" | python3 -I -c 'import sys,json
try: print(json.load(sys.stdin).get("tool_input",{}).get("command",""))
except Exception: print("")' 2>/dev/null || true)"

[[ -z "$cmd" ]] && exit 0

# Helper: emit deny decision
deny() {
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"GitLab write guard: %s"}}\n' "$1"
    exit 0
}

# --- git push to GitLab ---
if printf '%s' "$cmd" | grep -qiE 'git\s+((-[Cc]\s+\S+\s+)*)push\b' &&
   printf '%s' "$cmd" | grep -qiF "$GITLAB_HOST"; then

    # Extract refspecs / branch names after "push"
    push_args="$(printf '%s' "$cmd" | sed -E 's/.*git\s+((-[Cc]\s+\S+\s+)*)push\s*//')"

    # Allow if pushing to devops-064/* or feat/devops-064-*
    if printf '%s' "$push_args" | grep -qE '(^|\s|:)(devops-064/|feat/devops-064-)'; then
        exit 0
    fi

    # Allow if "origin devops-064/" or "origin feat/devops-064-" pattern
    if printf '%s' "$push_args" | grep -qE 'origin\s+(devops-064/|feat/devops-064-)'; then
        exit 0
    fi

    deny "Push blocked — only devops-064/* or feat/devops-064-* branches allowed on $GITLAB_HOST."
fi

# --- curl to GitLab API ---
if printf '%s' "$cmd" | grep -qiF "$GITLAB_HOST" &&
   printf '%s' "$cmd" | grep -qi 'curl\b'; then

    # GET requests always pass
    if printf '%s' "$cmd" | grep -qiE '\bcurl\b' &&
       ! printf '%s' "$cmd" | grep -qiE -- '-X\s*(POST|PUT|PATCH|DELETE)|--request\s*(POST|PUT|PATCH|DELETE)|-d\s|--data\b|--data-raw\b|--data-binary\b|--data-urlencode\b|-F\s|--form\b'; then
        exit 0
    fi

    # MR notes/comments: always allowed (low risk)
    if printf '%s' "$cmd" | grep -qiE '/merge_requests/[0-9]+/notes'; then
        exit 0
    fi

    # MR creation: only in core/dcm-catapult (project path encoded or ID)
    if printf '%s' "$cmd" | grep -qiE '/merge_requests(\s|$|[?"])'; then
        if printf '%s' "$cmd" | grep -qiE '(core(%2F|/)dcm-catapult|projects/core%2Fdcm-catapult)'; then
            exit 0
        fi
        deny "MR creation blocked — only allowed in core/dcm-catapult project."
    fi

    # Issue/board writes: POST (create) allowed, PUT/DELETE blocked
    if printf '%s' "$cmd" | grep -qiE '/(issues|boards|board_lists)'; then
        if printf '%s' "$cmd" | grep -qiE -- '-X\s*(PUT|PATCH|DELETE)|--request\s*(PUT|PATCH|DELETE)'; then
            deny "Issue/board modification blocked — only POST (create) allowed."
        fi
        exit 0
    fi

    # Wiki writes: only vulns-docs namespace
    if printf '%s' "$cmd" | grep -qiE '/wikis'; then
        if printf '%s' "$cmd" | grep -qiE '(vulns-docs|vulns_docs)'; then
            exit 0
        fi
        deny "Wiki write blocked — only vulns-docs namespace allowed."
    fi

    # Any other write method to GitLab API
    if printf '%s' "$cmd" | grep -qiE -- '-X\s*(POST|PUT|PATCH|DELETE)|--request\s*(POST|PUT|PATCH|DELETE)|-d\s|--data\b|--data-raw\b|--data-binary\b|--data-urlencode\b|-F\s|--form\b'; then
        deny "Unrecognized GitLab API write blocked. Allowed: MR in core/dcm-catapult, MR comments, issue creation, vulns-docs wiki."
    fi
fi

exit 0
