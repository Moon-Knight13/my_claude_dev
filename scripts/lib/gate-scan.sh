#!/usr/bin/env bash
# Results are globals read by the gate handler.
# shellcheck disable=SC2034
# gate-scan.sh — the gate's mount_scan op: the floor over every item of a
# hub-produced workspace manifest (SP1a story 3.2; AD-2, AD-20, AD-24, FR-1,
# FR-47). Gate code: its digest is an input to policy_version.
#
# A scan manifest is a directory directly under <state>/manifests/ named
# scan-*, holding exactly:
#   items/000001 … items/NNNNNN   one item each (a file, an object, a reflog, …)
#   index.jsonl                   one line per item, in order: {"item": "<what>"}
#                                 e.g. "tree:src/a.py", "object:<sha>", "ref-names"
# The gate reads it under its own identity and never reads a workspace.
#
# The floor runs on every item exactly as on a request — plain, separators,
# decodings — with one perl pass and a few greps over the whole directory, so a
# large repository stays inside the bulk budget.
#
#   gate_scan_manifest_ok <dir> <state>   rc 0; sets GATE_SCAN_N
#   gate_scan <dir> <workspace id> <state> <scratch>
#       rc 0 clean, 3 hits (GATE_SCAN_HITS: JSON list of {item, term_sha256}),
#       4 fault (GATE_SCAN_FAULT)
#   gate_term_sha <term>                  the identity of a term for exclusions:
#                                         sha256 of the lowercased term

GATE_SCAN_MAX_ITEMS=200000
GATE_SCAN_MAX_BYTES=1073741824
GATE_SCAN_HITS="[]"
GATE_SCAN_FAULT=""

gate_scan_manifest_ok() {
    local dir="$1" root="$2" store n i
    store="$root/manifests"
    [[ "$dir" =~ ^/[A-Za-z0-9._/-]+$ && "$dir" != *..* ]] || return 4
    [[ "${dir%/*}" == "$store" && "${dir##*/}" =~ ^scan-[A-Za-z0-9._-]+$ ]] || return 4
    [[ -d "$store" && ! -L "$store" && -d "$dir" && ! -L "$dir" ]] || return 4
    [[ -d "$dir/items" && ! -L "$dir/items" && -f "$dir/index.jsonl" && ! -L "$dir/index.jsonl" ]] || return 4
    # Nothing else in the manifest; only regular files named 000001… in items/.
    [[ "$(find "$dir" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" == 2 ]] || return 4
    n="$(find "$dir/items" -mindepth 1 | wc -l | tr -d ' ')"
    (( n <= GATE_SCAN_MAX_ITEMS )) || return 4
    [[ -z "$(find "$dir/items" -mindepth 1 \( ! -type f -o ! -regex '.*/[0-9][0-9][0-9][0-9][0-9][0-9]' \) -print -quit)" ]] || return 4
    for (( i = 1; i <= n; i++ )); do [[ -f "$dir/items/$(printf '%06d' "$i")" ]] || return 4; done
    [[ "$(wc -l < "$dir/index.jsonl" | tr -d ' ')" == "$n" ]] || return 4
    jq -e -s 'all(.[]; type == "object" and (.item | type) == "string" and (.item | length) > 0)' \
        "$dir/index.jsonl" >/dev/null 2>&1 || return 4
    (( $(du -sb "$dir/items" | cut -f1) <= GATE_SCAN_MAX_BYTES )) || return 4
    GATE_SCAN_N="$n"
}

gate_term_sha() { printf '%s' "${1,,}" | sha256sum | cut -d' ' -f1; }


# Per-file variants for the directory scan: for each item, the text with line
# breaks as spaces, then every decoded variant (the same decoders as the floor).
# shellcheck disable=SC2016  # perl code
GATE_SCAN_VARIANTS='
my ($items, $out) = @ARGV; opendir(my $d, $items) or exit 4;
for my $f (sort grep { /^\d{6}$/ } readdir $d) {
    open(my $fh, "<:raw", "$items/$f") or exit 4; my $in = do { local $/; <$fh> }; close $fh;
    $in = "" unless defined $in;
    open(my $o, ">:raw", "$out/$f") or exit 4;
    (my $j = $in) =~ s/[\r\n]+/ /g; print $o $j, "\n";
    print $o $_, "\n" for decode_all($in);
    close $o;
}
'

gate_scan() {
    local dir="$1" ws="$2" root="$3" scratch="$4" pats terms excl hitlist n i item rel
    GATE_SCAN_HITS="[]"; GATE_SCAN_FAULT=""
    [[ "$GATE_POLICY_LOADED" == 1 ]] || { GATE_SCAN_FAULT=fault:policy; return 4; }
    pats="$scratch/patterns"; terms="$scratch/terms"
    gate_floor_patterns > "$pats" || { GATE_SCAN_FAULT=fault:policy; return 4; }
    gate_floor_terms > "$terms" || { GATE_SCAN_FAULT=fault:policy; return 4; }
    [[ -s "$pats" && -s "$terms" ]] || { GATE_SCAN_FAULT=fault:policy; return 4; }

    # Exclusions for this workspace: {ws, item, term_sha256}. Corrupt is a fault.
    excl="$root/exclusions/exclusions.jsonl"
    if [[ -e "$excl" ]]; then
        [[ -r "$excl" ]] || { GATE_SCAN_FAULT=fault:store; return 4; }
        if [[ -s "$excl" ]] && ! jq -e -s 'all(.[]; type == "object" and (.ws | type) == "string"
                and (.item | type) == "string" and (.term_sha256 | test("^[0-9a-f]{64}$")))' "$excl" >/dev/null 2>&1; then
            GATE_SCAN_FAULT=fault:store; return 4
        fi
    fi

    mkdir -p "$scratch/v" || { GATE_SCAN_FAULT=fault:internal; return 4; }
    perl -e "${GATE_FLOOR_DECODE_LIB}${GATE_SCAN_VARIANTS}" "$dir/items" "$scratch/v" 2>/dev/null \
        || { GATE_SCAN_FAULT=fault:internal; return 4; }

    # Candidate items: any item whose text or variants hit any term.
    hitlist="$scratch/candidates"
    { LC_ALL=C.UTF-8 grep -rlaiwF -f "$terms" "$dir/items" "$scratch/v" 2>/dev/null
      LC_ALL=C.UTF-8 grep -rlaiwE -f "$pats" "$dir/items" "$scratch/v" 2>/dev/null; } \
        | sed 's|.*/||' | sort -u > "$hitlist"
    [[ -s "$hitlist" ]] || return 0

    # For each candidate, which terms: one term at a time, on that item only.
    local -a T P; mapfile -t T < "$terms"; mapfile -t P < "$pats"
    : > "$scratch/hits.jsonl"
    while IFS= read -r n; do
        item="$(sed -n "$((10#$n))p" "$dir/index.jsonl" | jq -r .item)"
        for (( i = 0; i < ${#T[@]}; i++ )); do
            if cat -- "$dir/items/$n" "$scratch/v/$n" | LC_ALL=C.UTF-8 grep -qaiw -F -e "${T[i]}" 2>/dev/null \
               || cat -- "$dir/items/$n" "$scratch/v/$n" | LC_ALL=C.UTF-8 grep -qaiwE -e "${P[i]:-^$}" 2>/dev/null; then
                rel="$(gate_term_sha "${T[i]}")"
                if [[ -s "$excl" ]] && jq -e -s --arg ws "$ws" --arg it "$item" --arg t "$rel" \
                        'any(.[]; .ws == $ws and .item == $it and .term_sha256 == $t)' "$excl" >/dev/null 2>&1; then
                    continue
                fi
                jq -nc --arg it "$item" --arg t "$rel" '{item: $it, term_sha256: $t}' >> "$scratch/hits.jsonl"
            fi
        done
    done < "$hitlist"
    [[ -s "$scratch/hits.jsonl" ]] || return 0
    GATE_SCAN_HITS="$(jq -sc 'unique' "$scratch/hits.jsonl")"
    return 3
}
