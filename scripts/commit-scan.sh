#!/usr/bin/env bash
# commit-scan.sh — warn-only PII/secret scan of STAGED content.
#
# Wired in as a git pre-commit hook by scripts/install-commit-guard.sh. It NEVER
# blocks: it prints a warning for any finding and always exits 0, so an
# intentional commit is never aborted (owner decision — for both PII and
# secrets). The mitigation for a secret is therefore fast reaction (rotate/clean
# per SECURITY.md), not prevention.
#
# It records rule + file + line to a user-scope review log — never the matched
# value, because a log full of real secrets would just relocate the leak.
#
# Scope: gitleaks (secrets AND the pii-* rules) is the primary scanner; semgrep
# runs best-effort only if present (its PII rules are source-code specific). The
# config travels with the install, so the scan also covers the range checkout
# without anything being written into that pushed tree.
#
# Usage:  scripts/commit-scan.sh            # scans staged changes in CWD's repo
# Exit:   always 0 (warn-only).
set -uo pipefail

note() { echo "  --  commit-guard: $*"; }
warn() { echo "  !!  commit-guard: $*" >&2; }

# Not a git repo, or nothing staged → nothing to do.
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
if git diff --cached --quiet 2>/dev/null; then exit 0; fi

# Locate the carried config: explicit env > installed lib next to this script >
# the repo's own .gitleaks.toml > gitleaks default (no -c).
_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG=""
for c in "${COMMIT_GUARD_GITLEAKS_CONFIG:-}" "$_HERE/.gitleaks.toml" "$_HERE/../.gitleaks.toml"; do
    [[ -n "$c" && -f "$c" ]] && { CFG="$c"; break; }
done

STATE_DIR="${COMMIT_GUARD_STATE:-$HOME/.local/state/commit-guard}"
LOG="$STATE_DIR/findings.jsonl"
mkdir -p "$STATE_DIR" 2>/dev/null || true

if ! command -v gitleaks >/dev/null 2>&1; then
    warn "gitleaks not installed — staged content was NOT scanned for secrets/PII. Commit proceeds (see /day0-check)."
    exit 0
fi

# gitleaks v8: scan staged diff, JSON report to stdout. Non-zero exit = findings;
# we capture it and never propagate it (warn-only).
_cfg_args=(); [[ -n "$CFG" ]] && _cfg_args=(-c "$CFG")
report="$(gitleaks git --staged --no-banner "${_cfg_args[@]}" -f json -r - 2>/dev/null)"
count=0
if [[ -n "$report" && "$report" != "null" && "$report" != "[]" ]]; then
    count="$(jq 'length' <<<"$report" 2>/dev/null || echo 0)"
fi

_ts="$(date -Is 2>/dev/null || echo unknown)"
if (( count > 0 )); then
    warn "$count finding(s) in staged content — commit is NOT blocked; review before pushing:"
    # Emit rule/file/line ONLY. Never echo .Match/.Secret. Classify pii-* as PII.
    while IFS=$'\t' read -r rule file line desc; do
        if [[ "$rule" == pii-* || "$rule" == *email* || "$rule" == *pii* ]]; then
            warn "  PII    [$rule] $file:$line — $desc"
        else
            warn "  SECRET [$rule] $file:$line — $desc  ➜ rotate/clean per SECURITY.md (warn-only: the push is not stopped)"
        fi
        # durable review log: rule/file/line/class only, no value
        cls="secret"; [[ "$rule" == pii-* || "$rule" == *pii* || "$rule" == *email* ]] && cls="pii"
        jq -cn --arg ts "$_ts" --arg r "$rule" --arg f "$file" \
               --argjson l "${line:-0}" --arg c "$cls" \
               '{ts:$ts,rule:$r,file:$f,line:$l,class:$c}' >> "$LOG" 2>/dev/null || true
    done < <(jq -r '.[] | [(.RuleID//"unknown"),(.File//"?"),(.StartLine//0),(.Description//"")] | @tsv' <<<"$report" 2>/dev/null)
    note "logged to $LOG (rule/file/line only — never the value)"
fi

# Best-effort semgrep PII pass on staged source files (skipped silently if absent).
if command -v semgrep >/dev/null 2>&1; then
    _semcfg=""; for c in "${COMMIT_GUARD_SEMGREP_CONFIG:-}" "$_HERE/.semgrep.yml" "$_HERE/../.semgrep.yml"; do
        [[ -n "$c" && -f "$c" ]] && { _semcfg="$c"; break; }
    done
    if [[ -n "$_semcfg" ]]; then
        mapfile -t staged < <(git diff --cached --name-only --diff-filter=ACM 2>/dev/null)
        if (( ${#staged[@]} > 0 )); then
            sem="$(semgrep scan --config "$_semcfg" --error --json --quiet "${staged[@]}" 2>/dev/null || true)"
            scount="$(jq '.results | length' <<<"$sem" 2>/dev/null || echo 0)"
            if (( scount > 0 )); then
                warn "$scount semgrep finding(s) in staged source — commit NOT blocked:"
                while IFS=$'\t' read -r rid file line; do
                    warn "  CODE   [$rid] $file:$line"
                    jq -cn --arg ts "$_ts" --arg r "$rid" --arg f "$file" \
                           --argjson l "${line:-0}" \
                           '{ts:$ts,rule:$r,file:$f,line:$l,class:"code"}' >> "$LOG" 2>/dev/null || true
                done < <(jq -r '.results[] | [(.check_id//"?"),(.path//"?"),(.start.line//0)] | @tsv' <<<"$sem" 2>/dev/null)
            fi
        fi
    fi
fi

exit 0
