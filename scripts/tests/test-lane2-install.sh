#!/usr/bin/env bash
# `cond && ok … || bad …` is safe in this file: ok and bad always return 0.
# shellcheck disable=SC2015
# test-lane2-install.sh — `lane2 install` deploys hub code only from a merged
# commit (SP1a story 2.1, #104; AD-7, AD-14, AD-18, AD-22, FR-22, FR-52).
# tier: ci — a local bare-repo fixture, a stub systemctl, no root.
#
# Root, the container check, the local-origin check, uid lookup, chown, and
# identity creation are replaced by sourcing the script and overriding those
# functions; each real one is tested on its own below. The hub-tier suite
# (test-lane2-install-hub.sh) runs the real thing as root on the hub.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LANE2="$ROOT/scripts/hub/lane2"
LIB="$ROOT/scripts/lib/lane2.sh"
PASS=0; FAIL=0
ok()   { echo "  OK  $1"; ((PASS++)) || true; }
bad()  { echo " FAIL $1"; ((FAIL++)) || true; }
check(){ if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (no '$3' in output)"; printf '%s\n' "$2" | sed 's/^/      | /' ;; esac; }
hasnt(){ case "$2" in *"$3"*) bad "$1 ('$3' found)" ;; *) ok "$1" ;; esac; }

TMP="$(mktemp -d)"; trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
G() { git -c user.name=t -c user.email=t@example.invalid -c init.defaultBranch=main "$@"; }

# --- fixture repository ------------------------------------------------------
W="$TMP/work"; mkdir -p "$W/scripts/hub/units" "$W/scripts/lib"
G init -q "$W"
unit_ok() { # unit_ok <user> [install]
    printf '[Unit]\nDescription=fixture\n[Service]\nUser=%s\nExecStart=@LANE2_CODE@/scripts/hub/serve @LANE2_CONFIG@ @LANE2_STATE@\n' "$1"
    printf 'NoNewPrivileges=yes\nProtectSystem=strict\nProtectHome=yes\nPrivateTmp=yes\nLimitCORE=0\nRestart=on-failure\n'
    [[ -n "${2:-}" ]] && printf '[Install]\nWantedBy=multi-user.target\n'
    return 0
}
echo "fixture" > "$W/README.md"
echo 'echo gate v1' > "$W/scripts/lib/gate.sh"
unit_ok lane2-fleet-classifier install > "$W/scripts/hub/units/fleet-classifier.service"
unit_ok fixture-operator > "$W/scripts/hub/units/lane2@.service"
G -C "$W" add -A; G -C "$W" commit -qm A; A="$(G -C "$W" rev-parse HEAD)"
echo 'echo gate v2' > "$W/scripts/lib/gate.sh"
G -C "$W" commit -qam B; B="$(G -C "$W" rev-parse HEAD)"
echo "fixture c" > "$W/README.md"
G -C "$W" commit -qam C; C="$(G -C "$W" rev-parse HEAD)"
# Bad units, each on main after C.
printf '[Service]\nUser=lane2-fleet-x\nExecStart=/bin/true\n' > "$W/scripts/hub/units/fleet-bad.service"
G -C "$W" add -A; G -C "$W" commit -qm X1; X1="$(G -C "$W" rev-parse HEAD)"
unit_ok lane2-fleet-x install | sed 's|@LANE2_CODE@|/home/op/checkout|' > "$W/scripts/hub/units/fleet-bad.service"
G -C "$W" commit -qam X2; X2="$(G -C "$W" rev-parse HEAD)"
G -C "$W" rm -q scripts/hub/units/fleet-bad.service
unit_ok fixture-operator install > "$W/scripts/hub/units/lane2-supervisor.service"
G -C "$W" add -A; G -C "$W" commit -qm X3; X3="$(G -C "$W" rev-parse HEAD)"
# An unmerged commit on another branch.
G -C "$W" checkout -qb feature "$C"
echo "unmerged" > "$W/README.md"; G -C "$W" commit -qam U; U="$(G -C "$W" rev-parse HEAD)"
G -C "$W" checkout -q main
G -C "$W" tag v1 "$A"
BARE="$TMP/origin.git"; G clone -q --bare "$W" "$BARE"

# The invoking checkout is dirty: a modified tracked file and an untracked one.
DIRTY="$TMP/dirty"; G clone -q "$W" "$DIRTY"
echo "ZZDIRTY local edit" >> "$DIRTY/README.md"; echo ZZDIRTY > "$DIRTY/untracked.txt"

# --- hub layout --------------------------------------------------------------
CONF="$TMP/etc"; STATE="$TMP/var/lane2"; PREFIX="$TMP/opt/lane2"; UNITS="$TMP/units"
mkdir -p "$CONF" "$UNITS" "$TMP/opt" "$STATE"; chmod 755 "$STATE"
writeconf() {
    { echo "LANE2_ORIGIN=file://$BARE"; echo "LANE2_OPERATOR=$(id -un)"
      echo "LANE2_PREFIX=$PREFIX"; echo "LANE2_STATE_ROOT=$STATE"; echo "LANE2_UNIT_DIR=$UNITS"
      printf '%s\n' "$@"; } > "$CONF/lane2.conf"
}
writeconf

STUB="$TMP/bin"; mkdir -p "$STUB"
SYSLOG="$TMP/systemctl.log"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\nexit 0\n' "$SYSLOG" > "$STUB/systemctl"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/socat"
chmod +x "$STUB/systemctl" "$STUB/socat"

L() {
    bash -c '
        source "$1"; shift
        lane2_in_container() { return 1; }
        if [[ -n "${T_NOTROOT:-}" ]]; then lane2_is_root() { return 1; }; else lane2_is_root() { return 0; }; fi
        lane2_uid() { if [[ -n "${T_BADUID:-}" && "$1" == "$T_BADUID" ]]; then echo 99999; else id -u; fi; }
        lane2_gid() { id -g; }
        lane2_chown() { :; }
        lane2_ensure_identity() { :; }
        lane2_check_identity() { return 0; }
        if [[ -z "${T_REAL_ORIGIN:-}" ]]; then lane2_check_origin() { [[ "$1" == file://* ]]; }; fi
        LANE2_GIT_FILE_PROTOCOL=always
        lane2_main "$@"' _ "$LANE2" --config-dir "$CONF" "$@"
}
run() { OUT="$(cd "$DIRTY" && PATH="$STUB:$PATH" L "$@" 2>&1)"; RC=$?; }
cur() { readlink "$PREFIX/current" 2>/dev/null || echo none; }
lsn() { find "$1" -mindepth 1 -maxdepth 1 -printf '%f ' 2>/dev/null | tr ' ' '\n' | sort | tr '\n' ' '; }
snap() { printf '%s|%s|%s' "$(cur)" "$(lsn "$PREFIX")" "$(lsn "$UNITS")"; }

# =============================================================================
echo "== refusals change nothing =="
BEFORE="$(snap)"
run install main;            check "branch name refused (exit 4)" "$RC" 4
run install v1;              check "tag refused (exit 4)" "$RC" 4
run install "${A:0:12}";     check "abbreviated commit refused (exit 4)" "$RC" 4
has "says why" "$OUT" "full 40-hex commit id"
run install "$U";            check "unmerged commit refused (exit 3)" "$RC" 3
run install "$(printf 'f%.0s' {1..40})"; check "unknown commit refused (exit 3)" "$RC" 3
OUT="$(cd "$DIRTY" && T_NOTROOT=1 PATH="$STUB:$PATH" L install "$A" 2>&1)"; RC=$?
check "non-root refused (exit 4)" "$RC" 4
has "says root" "$OUT" "must run as root"
writeconf; sed -i "s|^LANE2_ORIGIN=.*|LANE2_ORIGIN=$BARE|" "$CONF/lane2.conf"
OUT="$(cd "$DIRTY" && T_REAL_ORIGIN=1 PATH="$STUB:$PATH" L install "$A" 2>&1)"; RC=$?
check "local-path origin refused (exit 4)" "$RC" 4
has "says local paths are refused" "$OUT" "local paths are refused"
writeconf
OUT="$(DEVCONTAINER=true bash "$LANE2" --config-dir "$CONF" install "$A" 2>&1)"; RC=$?
check "inside a container refused (exit 4)" "$RC" 4
has "says run on the hub" "$OUT" " FAIL run on the hub"
check "nothing installed, current untouched" "$(snap)" "$BEFORE"

echo "== origin rule (real check) =="
origin() { bash -c 'source "$1"; lane2_check_origin "$2"' _ "$LIB" "$1"; }
for u in "https://example.invalid/org/repo.git" "ssh://git@example.invalid/org/repo.git"; do
    origin "$u" && ok "accepts $u" || bad "refused $u"
done
# A literal "~/repo" (unexpanded) is one of the local forms the rule must refuse.
# shellcheck disable=SC2088
for u in "/srv/repo.git" "./repo" "~/repo" "file:///srv/repo.git" "https://user:token@example.invalid/r.git" \
         "git@example.invalid:org/repo.git" "http://example.invalid/r.git" ""; do
    origin "$u" && bad "accepted '$u'" || ok "refuses '$u'"
done

echo "== required tools =="
TOOLS="$TMP/tools"; mkdir -p "$TOOLS"
for t in bash jq git tar sha256sum flock; do ln -s "$(command -v "$t")" "$TOOLS/$t"; done
ln -s "$STUB/systemctl" "$TOOLS/systemctl"
OUT="$(bash -c 'source "$1"; PATH="$2"; install_tools' _ "$LANE2" "$TOOLS" 2>&1)"; RC=$?
check "missing socat stops the install (exit 4)" "$RC" 4
has "names the missing tool" "$OUT" " FAIL required tool missing: socat"
rm "$TOOLS/systemctl"; ln -s "$STUB/socat" "$TOOLS/socat"
OUT="$(bash -c 'source "$1"; PATH="$2"; install_tools' _ "$LANE2" "$TOOLS" 2>&1)"; RC=$?
has "names systemd when systemctl is missing" "$OUT" "required tool missing: systemd"

# =============================================================================
echo "== first install, from a dirty checkout =="
run install "$A"
check "install exits 0" "$RC" 0
check "current -> A" "$(cur)" "$A"
EXP="$TMP/expect-a"; mkdir -p "$EXP"; G -C "$W" archive "$A" | tar -x -C "$EXP"
DIFF="$(diff -r --exclude=.lane2-install.json "$EXP" "$PREFIX/$A" 2>&1)"
check "installed tree equals the commit's tree" "$DIFF" ""
[[ ! -e "$PREFIX/$A/untracked.txt" ]] && ok "untracked checkout file not installed" || bad "untracked file leaked"
grep -q ZZDIRTY "$PREFIX/$A/README.md" && bad "dirty edit leaked" || ok "dirty edit not installed"
WR="$(find "$PREFIX/$A" \( -perm -g=w -o -perm -o=w \) ! -type l | head -1)"
check "nothing group- or world-writable" "$WR" ""
check "prefix is 0755" "$(stat -c %a "$PREFIX")" 755
check "no staging directory left" "$(find "$PREFIX" -mindepth 1 -maxdepth 1 -name '.staging.*' -print)" ""

echo "== stores (AD-7) =="
while read -r name _ _ mode; do
    check "store $name mode" "$(stat -c %a "$STATE/$name" 2>/dev/null)" "${mode#0}"
done < <(bash -c 'source "$1"; lane2_stores' _ "$LIB")
check "12 stores" "$(find "$STATE" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" 12
check "policy checkout readable by the gate's group, setgid (2750)" "$(stat -c %a "$STATE/gate-policy")" 2750
check "gate store private to the gate (0700)" "$(stat -c %a "$STATE/gate-store")" 700

echo "== units =="
[[ -f "$UNITS/fleet-classifier.service" && -f "$UNITS/lane2@.service" ]] && ok "units installed" || bad "units missing"
has "rendered with the installed prefix" "$(cat "$UNITS/fleet-classifier.service")" "ExecStart=$PREFIX/$A/scripts/hub/serve $CONF $STATE"
hasnt "no placeholder left" "$(cat "$UNITS"/*)" "@LANE2_"
hasnt "no checkout path in any unit" "$(cat "$UNITS"/*)" "$DIRTY"
LOG="$(cat "$SYSLOG")"
has "daemon-reload" "$LOG" "daemon-reload"
has "fleet unit enabled at boot" "$LOG" "enable fleet-classifier.service"
hasnt "supervisor template never enabled" "$LOG" "enable lane2@.service"
for u in gate-session.socket gate-hub.socket fleet-classifier.service lane2-notify.service; do
    bash -c 'source "$1"; lane2_boot_allowed "$2"' _ "$LIB" "$u" && ok "boot allowlist: $u" || bad "not allowed: $u"
done
for u in lane2@.service lane2-supervisor.service lane2-proxy@.socket squid-lane2.service gate-handler@.service; do
    bash -c 'source "$1"; lane2_boot_allowed "$2"' _ "$LIB" "$u" && bad "allowed at boot: $u" || ok "never at boot: $u"
done

echo "== digests and --verify =="
REC="$STATE/install/manifest.json"
check "record names the commit" "$(jq -r .commit "$REC")" "$A"
check "record holds the installed-code digest" "$(jq -r .installed_code_digest "$REC")" \
    "$(bash -c 'source "$1"; lane2_tree_digest "$2"' _ "$LIB" "$PREFIX/$A")"
GATE_A="$(jq -r .gate_code_digest "$REC")"
check "record holds the gate-code digest" "$GATE_A" \
    "$(bash -c 'source "$1"; lane2_tree_digest "$2" scripts/lib/gate scripts/hub/gate' _ "$LIB" "$PREFIX/$A")"
check "record is 0600" "$(stat -c %a "$REC")" 600
run install --verify; check "--verify passes on a clean install" "$RC" 0

# =============================================================================
echo "== upgrade, rollback, keep count =="
: > "$SYSLOG"
run install "$B"
check "upgrade exits 0" "$RC" 0
check "current -> B" "$(cur)" "$B"
[[ -d "$PREFIX/$A" ]] && ok "previous install kept beside the new one" || bad "previous install removed"
has "hub services restarted" "$(cat "$SYSLOG")" "try-restart fleet-classifier.service"
GATE_B="$(jq -r .gate_code_digest "$REC")"
[[ "$GATE_B" != "$GATE_A" ]] && ok "gate-code digest changes when gate code changes" || bad "gate digest unchanged"
run install "$A"
check "rollback = installing the earlier commit" "$(cur)" "$A"
has "rollback reuses the installed tree" "$OUT" "already installed"
run install "$C"; GATE_C="$(jq -r .gate_code_digest "$REC")"
check "gate-code digest unchanged when gate code is unchanged" "$GATE_C" "$GATE_B"
writeconf "LANE2_KEEP_INSTALLS=2"
run install "$B"
check "keep-count install exits 0" "$RC" 0
check "only LANE2_KEEP_INSTALLS commit dirs kept" "$(find "$PREFIX" -mindepth 1 -maxdepth 1 -type d -name '[0-9a-f]*' | wc -l | tr -d ' ')" 2
[[ -d "$PREFIX/$B" && -d "$PREFIX/$C" && ! -d "$PREFIX/$A" ]] && ok "oldest install pruned, current kept" || bad "wrong installs pruned: $(ls "$PREFIX")"
writeconf

echo "== failures before the swap leave current unchanged =="
BEFORE="$(snap)"
run install "$X1"
check "unit missing hardening: exit 4" "$RC" 4
has "names the problem" "$OUT" "unit lint: fleet-bad.service lacks NoNewPrivileges=yes"
has "boot-enabled service needs Restart=on-failure" "$OUT" "lacks Restart=on-failure"
run install "$X2"
check "unit with a home path: exit 4" "$RC" 4
has "names the path problem" "$OUT" "references a workspace or home path"
run install "$X3"
check "non-allowlisted unit with [Install]: exit 4" "$RC" 4
has "names the boot problem" "$OUT" "not on the boot allowlist"
check "current, installs, and units unchanged" "$(snap)" "$BEFORE"
[[ ! -d "$PREFIX/$X1" && ! -d "$PREFIX/$X2" && ! -d "$PREFIX/$X3" ]] && ok "no tree left for a failed install" || bad "failed install left a tree"

chmod 755 "$STATE/eval"
run install "$C"
check "loose store mode fails the install (exit 4)" "$RC" 4
has "names the store" "$OUT" "store eval"
check "loose mode not silently fixed" "$(stat -c %a "$STATE/eval")" 755
chmod 700 "$STATE/eval"
OUT="$(cd "$DIRTY" && T_BADUID=operator PATH="$STUB:$PATH" L install "$C" 2>&1)"; RC=$?
check "wrong store owner fails the install (exit 4)" "$RC" 4
has "names the store" "$OUT" "store gate-policy"
check "current unchanged after store failures" "$(snap)" "$BEFORE"

echo "== --verify catches tampering =="
F="$PREFIX/$(cur)/README.md"
chmod u+w "$F"; echo tamper >> "$F"; chmod 644 "$F"
run install --verify
check "--verify fails on a changed file (exit 4)" "$RC" 4
has "names the mismatch" "$OUT" " FAIL installed-code digest mismatch"
G -C "$W" show "$(cur):README.md" > "$F"
run install --verify; check "--verify passes again once restored" "$RC" 0
chmod g+w "$F"
run install --verify
check "--verify fails on a group-writable file" "$RC" 4
has "names the writable path" "$OUT" "group- or world-writable path in the install: README.md"
chmod g-w "$F"

# =============================================================================
echo "== service identities (real check) =="
idc() { bash -c 'source "$1"; LANE2_CONF[LANE2_OPERATOR]="$2"; lane2_check_identity "$3"' _ "$LIB" "$(id -un)" "$1"; }
idc root && bad "root accepted as a service identity" || ok "root is never a service identity"
idc nobody && ok "a non-root nologin account is accepted" || bad "nobody refused"
idc "$(id -un)" && bad "operator accepted as a service identity" || ok "the operator is never a service identity"
idc no-such-account-zz && bad "missing account accepted" || ok "a missing account is refused"
IDS="$(bash -c 'source "$1"; printf "%s\n" "${LANE2_SERVICE_IDENTITIES[@]}"' _ "$LIB" | sort | uniq -d)"
check "gate and each fleet member have distinct identities" "$IDS" ""

echo "== layout (AD-14) =="
for p in scripts/hub/lane2 scripts/hub/units scripts/hub/integration scripts/hub/container scripts/lib/lane2.sh; do
    [[ -e "$ROOT/$p" ]] && ok "$p exists" || bad "$p missing"
done
HOSTHITS="$(grep -rlE '(^|[^A-Za-z0-9_-])(lane2|gate_[a-z]|fleet_[a-z]|hw_[a-z])|(gate|fleet)-[A-Za-z@-]*\.(service|socket)' "$ROOT/scripts/host" 2>/dev/null || true)"
check "no hub service, unit, or lane2 command under scripts/host" "$HOSTHITS" ""
HOSTFILES="$(find "$ROOT/scripts/host" \( -name 'lane2*' -o -name 'gate*' -o -name 'fleet*' -o -name '*.socket' \) -print)"
check "no hub files under scripts/host" "$HOSTFILES" ""

echo "== public-repo hygiene =="
HITS="$(grep -lE 'https?://[A-Za-z0-9.-]+\.(com|net|org|io)/' "$LANE2" "$LIB" "$ROOT"/scripts/hub/units/README.md 2>/dev/null || true)"
check "no real origin URL in the install code" "$HITS" ""

echo
echo "lane2-install: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
