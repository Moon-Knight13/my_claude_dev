---
name: technique-scoring
description: "Query cross-engagement technique scores for orchestrator grounding. Ranks techniques by empirical success rate, EPSS, and stealth. Triggers: 'rank techniques', 'technique scores', 'what works on', 'prioritize attack', 'score techniques', 'technique ranking'."
modes: [red-team, purple, red-dev]
---

# Technique Scoring — Orchestrator Grounding

Query and interpret cross-engagement technique scores. Provides empirical
grounding for attack vector selection by ranking techniques based on what
actually worked across prior engagements on this range.

## When to Use

- **Before initial-access planning**: rank techniques by success rate for target platform
- **During lateral-move planning**: check which movement techniques worked before
- **After engagement archive**: review technique performance across completed engagements
- **When Providentia suggests vulnerabilities**: cross-check against empirical success data

## Scoring Model

Composite score (0.0-1.0):

```
score = 0.60 * empirical_rate + 0.25 * epss_score + 0.15 * stealth_rating + penalties
```

- **Empirical rate**: weighted success count / weighted total attempts (recency-decayed)
- **Partial results**: count as 0.5 success
- **Recency decay**: exponential half-life of 90 days (recent outcomes matter more)
- **EPSS**: exploitation probability from cve-mcp (0 when not CVE-linked)
- **Stealth**: from OPSEC assessment (0 when not assessed)

### Flags

| Flag | Meaning |
|------|---------|
| `auto_deprioritized` | 0% success across 3+ engagements. Score penalized by -0.50. |
| `low_confidence` | Fewer than 3 total attempts. Score may not be reliable. |
| `providentia_gap` | Providentia says exploitable but 0% empirical success rate. |

## Operations

### Get Ranked Technique List

```bash
python3 scripts/technique-scoring.py --format json
python3 scripts/technique-scoring.py --top 10 --format table
```

### Query Single Technique

```bash
python3 scripts/technique-scoring.py --query T1003.001 --format json
```

### Run with Providentia Gap Detection

```bash
python3 scripts/technique-scoring.py --gaps --providentia-cache llm-wiki/raw/providentia/vulns.yaml
```

### Enrich with EPSS at Query Time

After getting base scores, the orchestrator enriches CVE-linked techniques:

1. Run `scripts/technique-scoring.py --format json` to get base scores
2. For each technique with a linked CVE, call `epss_score` via cve-mcp
3. For each technique, call `analyze_opsec_risk` via lolbins-mcp for stealth rating
4. Recompute composite: `0.60 * empirical + 0.25 * epss + 0.15 * stealth`

This two-phase approach avoids MCP calls for techniques with no CVE linkage.

## Integration with Orchestrator Decision Loop

When the orchestrator selects attack vectors for a target:

1. **Get Providentia vuln data** for target via `range_vuln_lookup`
2. **Get technique scores** via this skill
3. **Filter** techniques by target platform and available services
4. **Rank by composite score** (empirical > EPSS > stealth)
5. **Skip auto-deprioritized** techniques unless operator overrides
6. **Flag providentia_gap** techniques and warn operator before using
7. **Prefer low_confidence techniques** that match Providentia vulns (need data)

### Decision Priority

```
empirical success rate > EPSS probability > stealth rating
```

Empirical data from this range always outweighs theoretical vulnerability scores.
A technique that worked here before is preferred over one that "should" work.

## Configuration

Scoring weights, decay, and thresholds in `config/technique-scoring.yaml`.
Engagement data read from `engagements/` (active) and `engagements/archive/` (historical).

## Data Flow

```
engagements/*.yaml --------+
                            |---> technique-scoring.py ---> ranked scores
engagements/archive/*.yaml -+                                    |
                                                                 v
                                                     orchestrator decision
                                                                 |
                                         +-----------------------+
                                         v                       v
                                    cve-mcp (EPSS)      lolbins-mcp (stealth)
                                         |                       |
                                         +-----> enriched composite score
```
