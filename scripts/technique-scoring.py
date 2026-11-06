#!/usr/bin/env python3
"""Cross-engagement technique scoring engine.

Aggregates technique outcomes from engagement YAML files (active + archived)
and computes composite scores for orchestrator grounding.

Usage:
    technique-scoring.py [--config CONFIG] [--engagements DIR] [--format json|yaml|table]
    technique-scoring.py --query TECHNIQUE_ID [--target HOST]
    technique-scoring.py --gaps [--providentia-cache FILE]

Output: ranked technique list with composite scores, flags, and metadata.
"""

import argparse
import json
import math
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("FATAL: PyYAML required. Install: pip install pyyaml")

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent
DEFAULT_CONFIG = REPO_ROOT / "config" / "technique-scoring.yaml"
DEFAULT_ENGAGEMENTS = REPO_ROOT / "engagements"


def load_config(path):
    with open(path) as f:
        return yaml.safe_load(f)


def find_engagement_files(engagements_dir):
    """Find all engagement YAMLs: active + archived."""
    files = []
    eng_path = Path(engagements_dir)
    if not eng_path.exists():
        return files
    for p in eng_path.glob("*.yaml"):
        files.append(p)
    archive = eng_path / "archive"
    if archive.exists():
        for p in archive.glob("*.yaml"):
            files.append(p)
    return files


def parse_engagement(path):
    """Parse engagement YAML, return techniques_tried list + metadata."""
    with open(path) as f:
        data = yaml.safe_load(f)
    if not data or not isinstance(data, dict):
        return None
    return {
        "id": data.get("engagement_id", path.stem),
        "start_date": data.get("start_date"),
        "status": data.get("status", "unknown"),
        "techniques_tried": data.get("techniques_tried", []),
        "findings": data.get("findings", []),
        "targets": data.get("targets", []),
    }


def recency_weight(timestamp_str, half_life_days, now=None):
    """Exponential decay weight based on age. Returns 0.0-1.0."""
    if not timestamp_str or not half_life_days:
        return 1.0
    now = now or datetime.now(timezone.utc)
    try:
        if isinstance(timestamp_str, str):
            ts = datetime.fromisoformat(timestamp_str.replace("Z", "+00:00"))
        elif isinstance(timestamp_str, datetime):
            ts = timestamp_str
        else:
            return 1.0
        if ts.tzinfo is None:
            ts = ts.replace(tzinfo=timezone.utc)
    except (ValueError, TypeError):
        return 1.0
    age_days = max(0, (now - ts).total_seconds() / 86400)
    return math.pow(0.5, age_days / half_life_days)


def aggregate_techniques(engagements, config):
    """Aggregate technique outcomes across all engagements.

    Returns dict keyed by technique_id with aggregated stats.
    """
    techniques = {}
    recency_cfg = config.get("recency", {})
    use_recency = recency_cfg.get("enabled", True)
    half_life = recency_cfg.get("half_life_days", 90)
    partial_w = config.get("partial_weight", 0.5)
    now = datetime.now(timezone.utc)

    for eng in engagements:
        if eng is None:
            continue
        eng_id = eng["id"]
        for t in eng.get("techniques_tried", []):
            tid = t.get("technique_id")
            if not tid:
                continue
            name = t.get("technique_name", tid)
            result = t.get("result", "").lower()
            target = t.get("target", "unknown")
            phase = t.get("phase", "unknown")
            timestamp = t.get("timestamp")

            if tid not in techniques:
                techniques[tid] = {
                    "technique_id": tid,
                    "technique_name": name,
                    "attempts": [],
                    "engagements_seen": set(),
                    "targets_seen": set(),
                    "phases_seen": set(),
                }

            w = recency_weight(timestamp, half_life, now) if use_recency else 1.0

            techniques[tid]["attempts"].append({
                "engagement_id": eng_id,
                "target": target,
                "result": result,
                "phase": phase,
                "timestamp": timestamp,
                "recency_weight": w,
            })
            techniques[tid]["engagements_seen"].add(eng_id)
            techniques[tid]["targets_seen"].add(target)
            techniques[tid]["phases_seen"].add(phase)
            if name and name != tid:
                techniques[tid]["technique_name"] = name

    return techniques


def compute_scores(techniques, config):
    """Compute composite scores for each technique."""
    weights = config.get("weights", {})
    w_emp = weights.get("empirical", 0.6)
    w_epss = weights.get("epss", 0.25)
    w_stealth = weights.get("stealth", 0.15)
    partial_w = config.get("partial_weight", 0.5)
    deprioritize = config.get("deprioritize", {})
    dep_min = deprioritize.get("min_engagements", 3)
    dep_penalty = deprioritize.get("penalty", -0.5)
    confidence_threshold = config.get("confidence_threshold", 3)

    scored = []
    for tid, data in techniques.items():
        attempts = data["attempts"]
        total_attempts = len(attempts)
        if total_attempts == 0:
            continue

        weighted_successes = 0.0
        weighted_total = 0.0
        raw_successes = 0
        raw_partials = 0
        raw_failures = 0
        raw_blocked = 0

        for a in attempts:
            w = a["recency_weight"]
            result = a["result"]
            weighted_total += w
            if result == "success":
                weighted_successes += w
                raw_successes += 1
            elif result == "partial":
                weighted_successes += w * partial_w
                raw_partials += 1
            elif result == "blocked":
                raw_blocked += 1
            else:
                raw_failures += 1

        empirical_rate = weighted_successes / weighted_total if weighted_total > 0 else 0.0

        epss_score = 0.0
        stealth_rating = 0.0

        composite = (w_emp * empirical_rate
                     + w_epss * epss_score
                     + w_stealth * stealth_rating)

        flags = []
        engagement_count = len(data["engagements_seen"])

        if raw_successes == 0 and raw_partials == 0 and engagement_count >= dep_min:
            composite += dep_penalty
            flags.append("auto_deprioritized")

        if total_attempts < confidence_threshold:
            flags.append("low_confidence")

        composite = max(0.0, min(1.0, composite))

        timestamps = [a["timestamp"] for a in attempts if a["timestamp"]]
        last_used = max(timestamps) if timestamps else None

        scored.append({
            "technique_id": tid,
            "technique_name": data["technique_name"],
            "composite_score": round(composite, 4),
            "empirical_rate": round(empirical_rate, 4),
            "attempts": total_attempts,
            "successes": raw_successes,
            "partials": raw_partials,
            "failures": raw_failures,
            "blocked": raw_blocked,
            "engagements_used": engagement_count,
            "targets_used": len(data["targets_seen"]),
            "phases": sorted(data["phases_seen"]),
            "last_used": last_used,
            "epss_score": epss_score,
            "stealth_rating": stealth_rating,
            "flags": flags,
        })

    scored.sort(key=lambda x: x["composite_score"], reverse=True)
    return scored


def detect_accuracy_gaps(scored, providentia_vulns, config):
    """Flag techniques where Providentia says exploitable but empirical rate is 0%."""
    gap_cfg = config.get("accuracy_gap", {})
    if not gap_cfg.get("enabled", True):
        return scored
    min_attempts = gap_cfg.get("min_attempts", 2)

    prov_techniques = set()
    for v in (providentia_vulns or []):
        tid = v.get("technique_id") or v.get("mitre_id")
        if tid:
            prov_techniques.add(tid)

    for entry in scored:
        tid = entry["technique_id"]
        if tid in prov_techniques:
            if (entry["successes"] == 0
                    and entry["partials"] == 0
                    and entry["attempts"] >= min_attempts):
                if "providentia_gap" not in entry["flags"]:
                    entry["flags"].append("providentia_gap")

    return scored


def format_table(scored):
    """Format scored techniques as aligned text table."""
    if not scored:
        return "No technique data found."
    header = (f"{'Rank':<5} {'Score':<7} {'Rate':<7} {'S/P/F/B':<12} "
              f"{'Eng':<5} {'Technique':<40} {'Flags'}")
    lines = [header, "-" * len(header)]
    for i, s in enumerate(scored, 1):
        spfb = f"{s['successes']}/{s['partials']}/{s['failures']}/{s['blocked']}"
        flags = ",".join(s["flags"]) if s["flags"] else "-"
        name = s["technique_name"][:38]
        tid = s["technique_id"]
        label = f"{tid} {name}" if name != tid else tid
        label = label[:40]
        lines.append(
            f"{i:<5} {s['composite_score']:<7.4f} "
            f"{s['empirical_rate']:<7.4f} {spfb:<12} "
            f"{s['engagements_used']:<5} {label:<40} {flags}"
        )
    return "\n".join(lines)


def query_technique(scored, technique_id, target=None):
    """Return detail for a single technique, optionally filtered by target."""
    for s in scored:
        if s["technique_id"] == technique_id:
            return s
    return None


def main():
    parser = argparse.ArgumentParser(description="Cross-engagement technique scoring")
    parser.add_argument("--config", default=str(DEFAULT_CONFIG),
                        help="Scoring config YAML")
    parser.add_argument("--engagements", default=str(DEFAULT_ENGAGEMENTS),
                        help="Engagements directory")
    parser.add_argument("--format", choices=["json", "yaml", "table"],
                        default="table", help="Output format")
    parser.add_argument("--query", metavar="TECHNIQUE_ID",
                        help="Query single technique by MITRE ID")
    parser.add_argument("--target", help="Filter by target hostname")
    parser.add_argument("--gaps", action="store_true",
                        help="Run Providentia accuracy gap detection")
    parser.add_argument("--providentia-cache",
                        help="Path to cached Providentia vuln export (YAML/JSON)")
    parser.add_argument("--top", type=int, default=0,
                        help="Show only top N techniques")
    args = parser.parse_args()

    config = load_config(args.config)
    eng_files = find_engagement_files(args.engagements)

    if not eng_files:
        print("No engagement files found.", file=sys.stderr)
        sys.exit(0)

    engagements = []
    for f in eng_files:
        eng = parse_engagement(f)
        if eng:
            engagements.append(eng)

    techniques = aggregate_techniques(engagements, config)
    scored = compute_scores(techniques, config)

    if args.gaps:
        prov_vulns = []
        if args.providentia_cache:
            cache_path = Path(args.providentia_cache)
            if cache_path.exists():
                with open(cache_path) as f:
                    if cache_path.suffix == ".json":
                        prov_vulns = json.load(f)
                    else:
                        prov_vulns = yaml.safe_load(f) or []
        scored = detect_accuracy_gaps(scored, prov_vulns, config)

    if args.query:
        result = query_technique(scored, args.query, args.target)
        if result:
            if args.format == "json":
                print(json.dumps(result, indent=2, default=str))
            elif args.format == "yaml":
                print(yaml.dump(result, default_flow_style=False))
            else:
                print(json.dumps(result, indent=2, default=str))
        else:
            print(f"Technique {args.query} not found in engagement data.",
                  file=sys.stderr)
            sys.exit(1)
        return

    if args.top > 0:
        scored = scored[:args.top]

    if args.format == "json":
        print(json.dumps(scored, indent=2, default=str))
    elif args.format == "yaml":
        print(yaml.dump(scored, default_flow_style=False))
    else:
        print(format_table(scored))


if __name__ == "__main__":
    main()
