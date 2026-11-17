#!/usr/bin/env bash
# test-gitlab-write-guard.sh — tests for the GitLab write guard hook.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$ROOT/scripts/hooks/pretooluse-gitlab-write-guard.sh"
PASS=0; FAIL=0

ok()   { echo "  OK  $1"; ((PASS++)) || true; }
bad()  { echo " FAIL $1"; ((FAIL++)) || true; }

# Feed a command through the hook and return allow/deny
run_hook() {
    local cmd="$1"
    local json_input
    json_input="$(printf '{"tool_input":{"command":"%s"}}' "$cmd")"
    local output
    output="$(printf '%s' "$json_input" | bash "$HOOK" 2>/dev/null)"
    if printf '%s' "$output" | grep -q '"deny"'; then
        echo "deny"
    else
        echo "allow"
    fi
}

check() {
    local label="$1" expected="$2" cmd="$3"
    local got
    got="$(run_hook "$cmd")"
    if [[ "$got" == "$expected" ]]; then
        ok "$label"
    else
        bad "$label (got '$got', want '$expected')"
    fi
}

echo "== git push rules =="
check "push allowed branch devops-064/"         allow "git push origin devops-064/my-feature"
check "push allowed branch feat/devops-064-"     allow "git push git@git.crp.cr14.net:core/dcm-catapult.git feat/devops-064-fix"
check "push allowed via remote url"              allow "git push ssh://git@git.crp.cr14.net:10022/core/dcm-catapult.git devops-064/test"
check "push blocked wrong branch"                deny  "git push git@git.crp.cr14.net:core/dcm-catapult.git main"
check "push blocked no branch match"             deny  "git push git@git.crp.cr14.net:core/dcm-catapult.git feature/other"
check "push to github (not gitlab) passes"       allow "git push origin main"
check "push with refspec colon"                  allow "git push git@git.crp.cr14.net:core/repo.git HEAD:devops-064/branch"

echo "== curl GET (always pass) =="
check "curl GET explicit"     allow "curl -X GET https://git.crp.cr14.net/api/v4/projects"
check "curl GET implicit"     allow "curl https://git.crp.cr14.net/api/v4/projects/123"
check "curl GET with token"   allow "curl -H 'PRIVATE-TOKEN: xxx' https://git.crp.cr14.net/api/v4/projects"

echo "== MR creation =="
check "MR create in dcm-catapult"     allow "curl -X POST https://git.crp.cr14.net/api/v4/projects/core%2Fdcm-catapult/merge_requests -d 'title=test'"
check "MR create wrong project"       deny  "curl -X POST https://git.crp.cr14.net/api/v4/projects/other%2Frepo/merge_requests -d 'title=test'"
check "MR create wrong project slash" deny  "curl -X POST https://git.crp.cr14.net/api/v4/projects/123/merge_requests -d 'title=test'"

echo "== MR comments =="
check "MR note POST allowed"          allow "curl -X POST https://git.crp.cr14.net/api/v4/projects/999/merge_requests/42/notes -d 'body=lgtm'"
check "MR note on any project"        allow "curl -X POST https://git.crp.cr14.net/api/v4/projects/other%2Frepo/merge_requests/1/notes -d 'body=test'"

echo "== issue/board writes =="
check "issue create POST allowed"     allow "curl -X POST https://git.crp.cr14.net/api/v4/projects/123/issues -d 'title=bug'"
check "issue PUT blocked"             deny  "curl -X PUT https://git.crp.cr14.net/api/v4/projects/123/issues/5 -d 'state=closed'"
check "issue DELETE blocked"          deny  "curl -X DELETE https://git.crp.cr14.net/api/v4/projects/123/issues/5"
check "board list create allowed"     allow "curl -X POST https://git.crp.cr14.net/api/v4/projects/123/board_lists -d 'label_id=1'"

echo "== wiki writes =="
check "wiki vulns-docs allowed"       allow "curl -X POST https://git.crp.cr14.net/api/v4/projects/vulns-docs%2Fmain/wikis -d 'title=test'"
check "wiki other namespace blocked"  deny  "curl -X POST https://git.crp.cr14.net/api/v4/projects/other%2Frepo/wikis -d 'title=test'"
check "wiki GET always passes"        allow "curl https://git.crp.cr14.net/api/v4/projects/other%2Frepo/wikis"

echo "== catch-all write block =="
check "random POST blocked"           deny  "curl -X POST https://git.crp.cr14.net/api/v4/projects/123/labels -d 'name=test'"
check "random DELETE blocked"         deny  "curl -X DELETE https://git.crp.cr14.net/api/v4/projects/123/labels/5"

echo "== heredoc false-positive prevention =="
check "gh pr with gitlab URLs in body" allow "$(printf 'gh pr create --title \"test\" --body \"$(cat <<'"'"'EOF'"'"'\ncurl -X POST https://git.crp.cr14.net/api/v4/projects/123/labels\nEOF\n)\"')"

echo "== non-gitlab commands (pass through) =="
check "local git commit"              allow "git commit -m 'test'"
check "curl to other host"            allow "curl -X POST https://example.com/api -d 'data=1'"
check "random bash"                   allow "ls -la /tmp"

echo
echo "gitlab-write-guard: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
