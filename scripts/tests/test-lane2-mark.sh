#!/usr/bin/env bash
# `cond && ok … || bad …` is safe in this file: ok and bad always return 0.
# shellcheck disable=SC2015
# test-lane2-mark.sh — workspace marks: unmarked means sensitive, work repos
# and nested sensitive paths refused (SP1a story 3.2, #112; AD-7, FR-1, FR-32).
# tier: ci — no gate needed; synthetic hosts under example.invalid.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LANE2="$ROOT/scripts/hub/lane2"
PASS=0; FAIL=0
ok()   { echo "  OK  $1"; ((PASS++)) || true; }
bad()  { echo " FAIL $1"; ((FAIL++)) || true; }
check(){ if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (no '$3' in output)"; printf '%s\n' "$2" | sed 's/^/      | /' ;; esac; }
hasnt(){ case "$2" in *"$3"*) bad "$1 ('$3' found)" ;; *) ok "$1" ;; esac; }

TMP="$(mktemp -d)"; trap 'chmod -R u+rwX "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
CONF="$TMP/etc"; STATE="$TMP/state"; PREFIX="$TMP/opt"; W="$TMP/ws"
mkdir -p "$CONF" "$PREFIX" "$W" "$TMP/work-repos/client"
for s in workspaces events exclusions manifests gate-policy; do mkdir -p "$STATE/$s"; done
chmod 700 "$STATE/workspaces" "$STATE/events"
{ echo "LANE2_OPERATOR=$(id -un)"; echo "LANE2_PREFIX=$PREFIX"; echo "LANE2_STATE_ROOT=$STATE"
  echo "LANE2_WORK_GIT_HOSTS=git.work.example.invalid, scm.corp.example.invalid"
  echo "LANE2_WORK_REPO_ROOTS=$TMP/work-repos"; } > "$CONF/lane2.conf"
L() { bash -c 'source "$1"; shift; lane2_in_container() { return 1; }; lane2_is_operator() { return 0; }
               lane2_uid() { id -u; }; lane2_gid() { id -g; }; lane2_chown() { :; }; lane2_main "$@"' \
          _ "$LANE2" --config-dir "$CONF" "$@"; }
run() { OUT="$(L "$@" 2>&1)"; RC=$?; }
WSF() { bash -c 'source "$1"; source "$2"; STATE="$3"; PREFIX="$4"; lane2_load_config "$5/lane2.conf"; shift 5; "$@"' \
            _ "$ROOT/scripts/lib/lane2.sh" "$ROOT/scripts/lib/lane2-ws.sh" "$STATE" "$PREFIX" "$CONF" "$@"; }
G() { git -c user.name=t -c user.email=t@example.invalid -c init.defaultBranch=main "$@"; }

mkdir -p "$W/a" "$W/b/inner" "$W/c"
G init -q "$W/a"

# =============================================================================
echo "== marking =="
run mark "$W/a" mountable
check "mark mountable: exit 0" "$RC" 0
has "says scan first" "$OUT" "not yet scanned"
F="$STATE/workspaces/$(WSF lane2_ws_id "$(realpath "$W/a")").json"
check "recorded against the canonical real path" "$(jq -r .path "$F")" "$(realpath "$W/a")"
check "store entry 0600" "$(stat -c %a "$F")" 600
check "starts unscanned" "$(jq -r .scan.state "$F")" unscanned
WSF lane2_ws_mountable "$(realpath "$W/a")"; check "consumer: mountable" "$?" 0
L1="$(tail -1 "$STATE/events/lane2.jsonl")"
check "one metadata-only event line" "$(jq -c 'keys' <<<"$L1")" '["event","mark","time","workspace"]'
hasnt "the event has no path" "$L1" "$W"

echo "== refused paths (exit 2) =="
run mark "$W/missing" mountable;    check "missing path" "$RC" 2
touch "$W/file"; run mark "$W/file" mountable; check "not a directory" "$RC" 2
ln -s "$W/a" "$W/link"; run mark "$W/link" mountable; check "a symlink" "$RC" 2
run mark "$STATE/workspaces" mountable; check "inside the hub state root" "$RC" 2
run mark "$PREFIX" mountable;       check "the install prefix" "$RC" 2
run mark "$STATE/gate-policy" mountable; check "the policy checkout" "$RC" 2
run mark "$W/a" maybe;              check "unknown mark: usage" "$RC" 2
OUT="$(DEVCONTAINER=true bash "$LANE2" --config-dir "$CONF" mark "$W/a" sensitive 2>&1)"; RC=$?
check "inside a container: refused" "$RC" 4

echo "== unmarked, corrupt, unreadable: never mountable =="
WSF lane2_ws_mountable "$(realpath "$W/c")"; check "unmarked: no (3)" "$?" 3
FC="$STATE/workspaces/$(WSF lane2_ws_id "$(realpath "$W/c")").json"
printf 'garbage' > "$FC"
WSF lane2_ws_mountable "$(realpath "$W/c")"; check "corrupt entry: fault (4)" "$?" 4
jq -n --arg p "$(realpath "$W/c")" '{path: $p, mark: "maybe", scan: {state: "clean"}}' > "$FC"
WSF lane2_ws_mountable "$(realpath "$W/c")"; check "unknown mark value: fault (4)" "$?" 4
jq -n --arg p "/somewhere/else" '{path: $p, mark: "mountable", scan: {state: "clean"}}' > "$FC"
WSF lane2_ws_mountable "$(realpath "$W/c")"; check "an entry for another path: fault (4)" "$?" 4
rm -f "$FC"
chmod 000 "$STATE/workspaces"
WSF lane2_ws_mountable "$(realpath "$W/a")"; check "unreadable store: fault (4)" "$?" 4
chmod 700 "$STATE/workspaces"
run mark "$W/c" sensitive; check "marking sensitive always succeeds" "$RC" 0
WSF lane2_ws_mountable "$(realpath "$W/c")"; check "sensitive: no (3)" "$?" 3

echo "== work repositories =="
run mark "$TMP/work-repos/client" mountable
check "under a work repository root: refused" "$RC" 3
has "says why" "$OUT" "work repository root"
mkdir -p "$W/r1"; G init -q "$W/r1"; G -C "$W/r1" remote add origin git@git.work.example.invalid:team/app.git
run mark "$W/r1" mountable; check "scp-style remote on a work host: refused" "$RC" 3
has "never names the remote" "$OUT" "names a work git host"; hasnt "remote not printed" "$OUT" "git.work"
mkdir -p "$W/r2"; G init -q "$W/r2"; G -C "$W/r2" remote add origin https://user@SCM.corp.example.invalid:8443/x/y.git
run mark "$W/r2" mountable; check "https remote on a subdomain-matched work host: refused" "$RC" 3
mkdir -p "$W/r3/vendor/lib"; G init -q "$W/r3"; G init -q "$W/r3/vendor/lib"
G -C "$W/r3/vendor/lib" remote add origin ssh://git@git.work.example.invalid/lib.git
run mark "$W/r3" mountable; check "a nested repository on a work host: refused" "$RC" 3
mkdir -p "$W/r4"; G init -q "$W/r4"
printf '[submodule "m"]\n\tpath = m\n\turl = git@scm.corp.example.invalid:m.git\n' > "$W/r4/.gitmodules"
run mark "$W/r4" mountable; check "a submodule on a work host: refused" "$RC" 3
mkdir -p "$W/r5"; G init -q "$W/r5"; G -C "$W/r5" remote add origin https://example.invalid/me/public.git
run mark "$W/r5" mountable; check "a non-work remote: allowed" "$RC" 0
G -C "$W/r5" remote add up https://notgit.work.example.invalid.evil.invalid/x.git
run mark "$W/r5" mountable; check "a look-alike host that only contains the domain: allowed" "$RC" 0
printf '[url "git@git.work.example.invalid:"]\n\tinsteadOf = mine:\n' >> "$W/r5/.git/config"
run mark "$W/r5" mountable; check "a url-rewrite to a work host: refused" "$RC" 3

echo "== nested sensitive paths =="
run mark "$W/b" sensitive; check "parent sensitive" "$RC" 0
run mark "$W/b/inner" mountable; check "inside a sensitive path: refused" "$RC" 3
run mark "$W/b" mountable; check "the sensitive path itself: refused" "$RC" 3
run mark "$W/b/inner" sensitive; run mark "$W/b" sensitive
mkdir -p "$W/p/child"; run mark "$W/p/child" sensitive
run mark "$W/p" mountable; check "containing a sensitive path: refused" "$RC" 3
has "says why" "$OUT" "contains, or is contained by, a path marked sensitive"

echo "== git config is read as data, never run =="
CANARY="$TMP/ran"
printf '#!/bin/sh\ntouch %s\n' "$CANARY" > "$W/r5/.git/hooks/post-checkout"; chmod +x "$W/r5/.git/hooks/post-checkout"
printf '[core]\n\tfsmonitor = %s/.git/hooks/post-checkout\n' "$W/r5" >> "$W/r5/.git/config"
run mark "$W/r5" mountable
[[ ! -e "$CANARY" ]] && ok "no hook or fsmonitor ran" || bad "a workspace hook ran"

echo
echo "lane2-mark: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
