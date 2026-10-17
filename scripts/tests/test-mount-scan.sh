#!/usr/bin/env bash
# `cond && ok … || bad …` is safe in this file: ok and bad always return 0.
# shellcheck disable=SC2015
# test-mount-scan.sh — the full-history floor scan before any mount (SP1a story
# 3.2, #112; AD-8, AD-20, AD-24, FR-1, FR-47, FR-52).
# tier: ci — the real gate behind a real unix socket; synthetic repos with the
# synthetic term "zzalpha" planted in one location at a time.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LANE2="$ROOT/scripts/hub/lane2"
PASS=0; FAIL=0
ok()   { echo "  OK  $1"; ((PASS++)) || true; }
bad()  { echo " FAIL $1"; ((FAIL++)) || true; }
check(){ if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (no '$3' in output)"; printf '%s\n' "$2" | sed 's/^/      | /' ;; esac; }
hasnt(){ case "$2" in *"$3"*) bad "$1 ('$3' found)" ;; *) ok "$1" ;; esac; }

# shellcheck source=/dev/null
source "$ROOT/scripts/tests/gate-fixture.sh"
gf_setup
[[ -S "$SOCK" ]] || { echo " FAIL gate socket did not come up"; exit 1; }
for s in workspaces exclusions manifests; do mkdir -p "$STATE/$s"; done
chmod 700 "$STATE/workspaces"; chmod 2750 "$STATE/manifests" "$STATE/exclusions"
conf() { gf_conf "GATE_HUB_SOCKET=$SOCK"
         { echo "LANE2_WORK_GIT_HOSTS=git.work.example.invalid"; printf '%s\n' "${LANE2_EXTRA[@]}"; } >> "$CONF/lane2.conf"; }
LANE2_EXTRA=(); conf
L() { bash -c 'source "$1"; shift; lane2_in_container() { return 1; }; lane2_is_operator() { return 0; }
               lane2_is_root() { return 0; }; lane2_uid() { id -u; }; lane2_gid() { id -g; }; lane2_chown() { :; }
               lane2_main "$@"' _ "$LANE2" --config-dir "$CONF" "$@"; }
run() { OUT="$(L "$@" 2>&1)"; RC=$?; }
G() { git -c user.name=t -c user.email=t@example.invalid -c init.defaultBranch=main -c commit.gpgsign=false "$@"; }
W="$TMP/ws"; mkdir -p "$W"
state() { bash -c 'source "$1"; source "$2"; STATE="$3"; lane2_ws_scan_state "$(realpath "$4")"' \
              _ "$ROOT/scripts/lib/lane2.sh" "$ROOT/scripts/lib/lane2-ws.sh" "$STATE" "$1"; }
# repo <name> — a fresh mountable repo with one clean commit
repo() {
    local r="$W/$1"; rm -rf "$r"; mkdir -p "$r"; G init -q "$r"
    printf 'hello\n' > "$r/README.md"; G -C "$r" add -A; G -C "$r" commit -qm init
    L mark "$r" mountable >/dev/null 2>&1
    R="$r"
}
blocked() { # blocked <label> — scan $R, expect a block with only the ref printed
    run scan "$R"
    check "$1: exit 3" "$RC" 3
    [[ "$OUT" =~ ^gr-[0-9a-f]{32}$ ]] && ok "$1: prints only the ref" || bad "$1: output '$OUT'"
    case "$(state "$R")" in "scan-blocked gr-"*) ok "$1: state scan-blocked <ref>" ;; *) bad "$1: state $(state "$R")" ;; esac
}
faulted() { # faulted <label> <reason text>
    run scan "$R"
    (( RC >= 4 )) && ok "$1: fault (exit $RC)" || bad "$1: exit $RC"
    has "$1: says why" "$OUT" "$2"
    check "$1: state unscanned" "$(state "$R")" unscanned
}

# =============================================================================
echo "== a clean workspace =="
repo clean
run scan "$R"
check "clean scan: exit 0" "$RC" 0
check "state clean" "$(state "$R")" clean
check "manifest and scratch removed" "$(find "$STATE/manifests" "$STATE/workspaces" -mindepth 1 -maxdepth 1 \( -name 'scan-*' -o -name '.scan-*' \) | wc -l | tr -d ' ')" 0
check "a clean scan is logged" "$(tail -1 "$STATE/events/lane2.jsonl" | jq -r .event)" scan_clean

echo "== a marker in each location blocks =="
repo tree;    printf 'about zzalpha\n' > "$R/notes.md"; G -C "$R" add -A; G -C "$R" commit -qm notes; blocked "tracked file"
repo untr;    printf 'zzalpha\n' > "$R/scratch.txt";                                               blocked "untracked file"
repo ign;     printf 'secret/\n' > "$R/.gitignore"; mkdir "$R/secret"; printf 'zzalpha\n' > "$R/secret/x"; blocked "ignored file"
repo hist;    printf 'zzalpha\n' > "$R/old.txt"; G -C "$R" add -A; G -C "$R" commit -qm add
              G -C "$R" rm -q old.txt; G -C "$R" commit -qm drop;                                  blocked "history only"
repo unreach; printf 'zzalpha\n' > "$R/u.txt"; G -C "$R" add -A; G -C "$R" commit -qm tmp
              G -C "$R" reset -q --hard HEAD~1; G -C "$R" reflog expire --expire=now --all;        blocked "unreachable object"
repo packed;  printf 'zzalpha\n' > "$R/p.txt"; G -C "$R" add -A; G -C "$R" commit -qm p
              G -C "$R" rm -q p.txt; G -C "$R" commit -qm rm; G -C "$R" gc -q --prune=now 2>/dev/null
              [[ -z "$(find "$R/.git/objects" -path '*/[0-9a-f][0-9a-f]/*' -type f)" ]] && ok "objects are packed" || ok "(some loose objects remain)"
              blocked "packed object"
repo branch;  G -C "$R" branch zzalpha;                                                           blocked "branch name"
repo tagmsg;  G -C "$R" tag -a v1 -m 'release for zzalpha';                                       blocked "tag message"
repo cmsg;    G -C "$R" commit -q --allow-empty -m 'work on zzalpha';                             blocked "commit message"
repo stash;   printf 'zzalpha\n' >> "$R/README.md"; G -C "$R" stash -q; [[ -z "$(G -C "$R" status --porcelain)" ]] && ok "stashed"
              blocked "stash"
repo reflog;  G -C "$R" update-ref -m 'moved for zzalpha' refs/heads/x HEAD;                     blocked "reflog message"
repo claude;  mkdir -p "$R/deep/dir"; printf 'Follow zzalpha rules\n' > "$R/deep/dir/CLAUDE.md";  blocked "nested CLAUDE.md"
repo dotcl;   mkdir -p "$R/.claude"; printf '{"note":"zzalpha"}\n' > "$R/.claude/settings.json";   blocked ".claude/"
repo lfs;     mkdir -p "$R/.git/lfs/objects/aa/bb"; printf 'zzalpha\n' > "$R/.git/lfs/objects/aa/bb/aabb00"; blocked "LFS object"
repo gcfg;    printf '[branch "zzalpha"]\n\tremote = origin\n' >> "$R/.git/config";              blocked "git config (data)"
repo hook;    printf '#!/bin/sh\n# zzalpha\n' > "$R/.git/hooks/pre-commit";                       blocked "hook file (data)"
repo enc;     printf '%s\n' "$(printf 'zzalpha' | base64)" > "$R/data.b64";                       blocked "base64 in a file (floor normalisation)"

echo "== the hit detail is retained, not printed =="
P="$STATE/gate-store/payloads/$OUT"
[[ -f "$P" ]] && ok "retained payload for the ref" || bad "no retained payload"
check "names the item" "$(jq -r '.hits[0].item' "$P")" "tree:data.b64"
jq -e '.hits[0].term_sha256 | test("^[0-9a-f]{64}$")' "$P" >/dev/null && ok "term identity as a hash" || bad "no term hash"
hasnt "never the term" "$(cat "$P")" "zzalpha"
check "operator log line" "$(tail -1 "$STATE/operator-log/gate.jsonl" | jq -r '"\(.op) \(.reason_category) \(.ref)"')" "mount_scan hit:floor $OUT"

echo "== no git command, hook, or config from the workspace runs =="
repo canary; CAN="$TMP/canary"
for h in post-checkout pre-commit post-index-change reference-transaction; do
    printf '#!/bin/sh\ntouch %s\n' "$CAN" > "$R/.git/hooks/$h"; chmod +x "$R/.git/hooks/$h"
done
printf '[core]\n\tfsmonitor = %s/.git/hooks/post-checkout\n\tpager = touch %s\n[alias]\n\tfor-each-ref = !touch %s\n' "$R" "$CAN" "$CAN" >> "$R/.git/config"
run scan "$R"
check "scan with hostile hooks and config: clean" "$RC" 0
[[ ! -e "$CAN" ]] && ok "no workspace hook, fsmonitor, pager, or alias ran" || bad "workspace code ran"

echo "== escapes are faults, never a partial scan =="
repo esc1; ln -s /etc/hostname "$R/host";                                        faulted "symlink escaping the workspace" "a symlink escapes"
repo esc2; mkdir -p "$R/sub"; printf 'gitdir: %s/elsewhere\n' "$TMP" > "$R/sub/.git"; faulted "gitfile outside" "a gitfile points outside"
repo esc3; mkdir -p "$TMP/foreign-objects"; printf '%s/foreign-objects\n' "$TMP" > "$R/.git/objects/info/alternates"
           faulted "alternates outside" "alternates points outside"
repo esc4; printf '%s\n' "$TMP" > "$R/.git/commondir";                            faulted "commondir outside" "commondir points outside"
repo esc5; ln -s /etc "$R/.git/escape";                                          faulted "symlink in .git escaping" "a symlink escapes"
repo esc6; printf 'See @~/notes.md\n' > "$R/CLAUDE.md";                           faulted "import from home" "imports from outside"
repo esc7; printf 'See @../../outside.md\n' > "$R/CLAUDE.md";                     faulted "import outside" "imports from outside"
repo inal; mkdir -p "$R/shared"; cp -r "$R/.git/objects/." "$R/shared/"; printf '%s/shared\n' "$R" > "$R/.git/objects/info/alternates"
           run scan "$R"; check "alternates inside the workspace: scanned (exit 0)" "$RC" 0
repo budg; LANE2_EXTRA=("LANE2_SCAN_MAX_FILES=3"); conf
           faulted "over the file budget" "over the scan budget"
LANE2_EXTRA=("LANE2_SCAN_MAX_BYTES=10"); conf
           faulted "over the byte budget" "over the scan budget"
LANE2_EXTRA=(); conf

echo "== refused before scanning =="
mkdir -p "$W/unmarked"; run scan "$W/unmarked"
check "unmarked: refused (3)" "$RC" 3; has "says mark first" "$OUT" "not marked mountable"
repo later; G -C "$R" remote add origin git@git.work.example.invalid:x.git
run scan "$R"; check "a work remote added after marking: refused (3)" "$RC" 3
check "  state unscanned" "$(state "$R")" unscanned
repo corrupt; CF="$STATE/workspaces/$(bash -c 'source "$1"; source "$2"; lane2_ws_id "$(realpath "$3")"' _ "$ROOT/scripts/lib/lane2.sh" "$ROOT/scripts/lib/lane2-ws.sh" "$R").json"
printf 'x' > "$CF"
run scan "$R"; check "corrupt workspace state: fault (4)" "$RC" 4
repo other; check "and while any entry is corrupt, nothing else can be marked mountable" "$(state "$R")" unscanned
L mark "$R" mountable >/dev/null 2>&1; check "  mark refused (fail closed)" "$?" 4
rm -f "$CF"

echo "== a gate fault leaves unscanned =="
repo gdown; gf_conf "GATE_HUB_SOCKET=$TMP/no-such.sock"; echo "LANE2_WORK_GIT_HOSTS=git.work.example.invalid" >> "$CONF/lane2.conf"
run scan "$R"; (( RC >= 4 )) && ok "gate down: fault" || bad "gate down: exit $RC"
check "  state unscanned" "$(state "$R")" unscanned
conf
repo pol; mv "$STATE/gate-policy/current/term-list.txt" "$TMP/tl"
run scan "$R"; (( RC >= 4 )) && ok "gate policy missing: fault" || bad "policy missing: exit $RC"
check "  state unscanned" "$(state "$R")" unscanned
mv "$TMP/tl" "$STATE/gate-policy/current/term-list.txt"
run scan "$R"; check "only a full clean scan writes clean" "$(state "$R")" clean

echo "== the gate never reads a workspace =="
OUT="$(printf '{"v":1,"op":"mount_scan","workspace":"%s","manifest":"%s"}\n' "$(printf 'a%.0s' {1..32})" "$R" | gf_raw raw)"
check "a manifest path outside the manifests store: block" "$(gf_reason_of "$OUT")" fault:protocol

# =============================================================================
echo "== exclusions =="
repo ex; printf 'about zzalpha\n' > "$R/notes.md"; printf 'also zzalpha\n' > "$R/other.md"; G -C "$R" add -A; G -C "$R" commit -qm n
run scan "$R"; REF="$OUT"
run review exclude "$REF" --path 'tree:*.md';        check "a glob: refused" "$RC" 2
run review exclude "$REF" --path 'tree:docs/';       check "a directory: refused" "$RC" 2
run review exclude "$REF" --path '';                 check "an empty path: refused" "$RC" 2
run review exclude "$REF" --path 'tree:nope.md';     check "an item that did not hit: refused" "$RC" 3
run review exclude "$REF" --path 'tree:notes.md'
check "one item, one term: recorded" "$RC" 0
EX="$STATE/exclusions/exclusions.jsonl"
check "stored hub-only, one line" "$(wc -l < "$EX" | tr -d ' ')" 1
run scan "$R"; check "the other path still blocks" "$RC" 3
P="$STATE/gate-store/payloads/$OUT"
# The excluded path is no longer reported; the same text as a git object is a
# different item, still reported (an exclusion covers exactly one path).
WANT="$(printf '%s\n' "tree:other.md" "object:.git:$(G -C "$R" rev-parse HEAD:other.md):blob" \
            "object:.git:$(G -C "$R" rev-parse HEAD:notes.md):blob" | sort | paste -sd, -)"
check "  tree:notes.md no longer reported; other items still are" "$(jq -r '[.hits[].item] | unique | join(",")' "$P")" "$WANT"
run review exclude "$OUT" --path 'tree:other.md'
for o in other.md notes.md; do
    run review exclude "$(cat "$STATE/operator-log/gate.jsonl" | tail -1 | jq -r .ref)" --path "object:.git:$(G -C "$R" rev-parse "HEAD:$o"):blob" >/dev/null 2>&1
done
run scan "$R"; check "every hit excluded: clean" "$RC" 0
check "  state clean" "$(state "$R")" clean
printf 'zzbravo too\n' >> "$R/notes.md"
run scan "$R"; check "another term on an excluded path still blocks" "$RC" 3
P="$STATE/gate-store/payloads/$OUT"
check "  reported once, for the new term" "$(jq -r '[.hits[] | select(.item == "tree:notes.md")] | length' "$P")" 1

echo "== health lists exclusions, never the term =="
H="$(bash -c 'source "$1"; source "$2"; STATE="$3"; lane2_health_ok() { echo "OK $1"; }
              lane2_health_warn() { echo "!! $1"; }; lane2_health_fail() { echo "FAIL $1 $2"; }; lane2_health_exclusions' \
         _ "$ROOT/scripts/lib/lane2.sh" "$ROOT/scripts/lib/lane2-health.sh" "$STATE")"
has "a count" "$H" "!! exclusions: $(wc -l < "$EX" | tr -d ' ')"
has "each id and item" "$H" "tree:notes.md"
hasnt "never a term hash" "$H" "$(jq -r '.term_sha256' "$EX" | head -1)"
hasnt "never the term" "$H" "zzalpha"
printf 'garbage\n' >> "$EX"
repo excorrupt; run scan "$R"; (( RC >= 4 )) && ok "a corrupt exclusion store: scan fault" || bad "corrupt exclusions: exit $RC"

echo
echo "mount-scan: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
