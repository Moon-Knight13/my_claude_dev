#!/usr/bin/env bash
# `cond && ok … || bad …` is safe in this file: ok and bad always return 0.
# shellcheck disable=SC2015
# test-floor-normalise.sh — the floor catches disguised terms (SP1a story 2.7,
# #110; FR-4, addendum floor normalisation).
# tier: ci — synthetic terms only (zzalpha, acme-corp, zzbravo).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATE="$ROOT/scripts/lib/gate.sh"
PASS=0; FAIL=0
ok()   { echo "  OK  $1"; ((PASS++)) || true; }
bad()  { echo " FAIL $1"; ((FAIL++)) || true; }
check(){ if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }
hasnt(){ case "$2" in *"$3"*) bad "$1 ('$3' found)" ;; *) ok "$1" ;; esac; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
P="$TMP/pol"; mkdir -p "$P/t"; ln -s t "$P/current"
printf '# synthetic\nzzalpha\nacme-corp\nzq\n' > "$P/t/term-list.txt"; printf 'Classify.\n' > "$P/t/classifier-prompt.md"
ME="$(id -un)"
# fl <text> — rc of the strict floor (0 hit, 1 clear, 4 fault)
fl() {
    printf '%s' "$1" > "$TMP/in"
    bash -c 'source "$1"; gate_policy_load "$2" "$3" || exit 9; gate_floor_match "$(cat "$4")"' _ "$GATE" "$P" "$ME" "$TMP/in" 2>&1
    echo "$?"
}
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
hex() { printf '%s' "$1" | od -An -tx1 | tr -d ' \n'; }

echo "== case, whitespace, separators =="
check "plain" "$(fl 'about zzalpha')" 0
check "upper case" "$(fl 'about ZZALPHA')" 0
check "mixed case" "$(fl 'about zZaLpHa')" 0
check "spaced letters" "$(fl 'about z z a l p h a')" 0
check "tabs and newlines between letters" "$(fl $'about z\tz\na l p h a')" 0
check "hyphens" "$(fl 'about z-z-a-l-p-h-a')" 0
check "dots and underscores" "$(fl 'about zz.al_pha')" 0
check "mixed separators" "$(fl 'about Z*z/A|l:p h-a')" 0
check "the term's own separator is optional" "$(fl 'an acme corp invoice')" 0
check "or replaced" "$(fl 'an ACME_CORP invoice')" 0
check "or removed" "$(fl 'an acmecorp invoice')" 0

echo "== encodings =="
check "base64" "$(fl "token $(b64 'zzalpha') end")" 0
check "base64 of a sentence with the term" "$(fl "$(b64 'the zzalpha project plan')")" 0
check "URL-safe base64" "$(fl "$(b64 'see acme-corp now?' | tr '+/' '-_')")" 0
check "URL percent-encoding" "$(fl 'q=%7a%7a%61%6c%70%68%61&x=1')" 0
check "URL encoding with + for space" "$(fl 'q=the+zzalpha+plan')" 0
check "hex" "$(fl "id $(hex zzalpha)")" 0
check "0x hex" "$(fl "id 0x$(hex zzalpha)")" 0
check "\\x hex" "$(fl "id $(hex zzalpha | sed 's/../\\x&/g')")" 0
check "upper-case hex" "$(fl "id $(hex zzalpha | tr 'a-f' 'A-F')")" 0

echo "== mixed encodings =="
check "base64 of URL-encoded" "$(fl "$(b64 '%7a%7aalpha')")" 0
check "base64 of hex" "$(fl "$(b64 "$(hex zzalpha)")")" 0
check "two encodings side by side" "$(fl "$(b64 nothing-here) and $(hex zzalpha)")" 0
check "spaced inside base64" "$(fl "$(b64 'z z a l p h a')")" 0

echo "== decode failure is not an allow =="
check "broken base64 next to the plain term" "$(fl 'zzalpha and @@@notbase64===')" 0
check "invalid percent escape, term still seen" "$(fl '%zz %g1 zzalpha')" 0
check "truncated base64 decodes to nothing: undecoded text still checked" "$(fl 'enphbHBo z z a l p h a')" 0
check "garbage only: clear" "$(fl '%%% @@@ ==== ////')" 1

echo "== word boundary =="
check "a longer word is not a hit" "$(fl 'the zzalphabet song')" 1
check "a prefix is not a hit" "$(fl 'prezzalpha')" 1
# Spaced letters hide word boundaries: "z z a l p h a b e t" cannot be told
# from "zzalpha" followed by "b e t". The floor blocks it (fail closed: a false
# block, never a leak); documented in the gate doc.
check "spaced letters running on: blocked (fail closed)" "$(fl 'z z a l p h a b e t')" 0
check "line breaks inside a term across lines" "$(fl $'zz\nal\npha')" 0
check "base64 of a longer word: no hit" "$(fl "$(b64 zzalphabet)")" 1
check "short entries are still rejected" "$(fl 'zq')" 1
check "plain prose stays clear" "$(fl 'please refactor the parser and add tests')" 1

echo "== no term echo =="
OUT="$(fl "$(b64 'the zzalpha plan') z-z-a-l-p-h-a")"
hasnt "nothing printed but the verdict" "$OUT" "zzalpha"
hasnt "no pattern printed" "$OUT" "["

echo "== a fault is not a clear =="
rm "$P/t/term-list.txt"
check "term list gone: fault (4)" "$(fl 'zzalpha')" 9
printf 'zzalpha\n' > "$P/t/term-list.txt"

echo
echo "floor-normalise: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
