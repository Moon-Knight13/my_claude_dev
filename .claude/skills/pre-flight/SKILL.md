---
name: pre-flight
description: "Pre-engagement flight plan — full briefing before offensive execution. Checks connectivity, builds target inventory, maps attack vectors, previews command queue, assesses risk, and gates on operator approval. Nothing offensive fires until approved. Use when operator says 'pre-flight', 'flight plan', 'briefing', 'ready check', or at engagement start before Phase 1."
modes: [red-team, purple, ctf, pentest]
disable-model-invocation: true
---

# Pre-Engagement Flight Plan

Full briefing before offensive execution. Like a pilot's flight plan — every
target, vector, command, and risk reviewed before anything fires.

**Nothing offensive executes until the operator signs off.**

## When to invoke

- Engagement start (Phase 0 of engagement-orchestration)
- Operator says: pre-flight, flight plan, briefing, ready check
- Before any thread dispatch in an engagement

## Prerequisites

- Active engagement YAML (from engagement-state skill) OR operator intent to start one
- Mode set to red-team, purple, ctf, or pentest

## Flight Plan Components

Execute sequentially. Each component produces structured output. Aggregate
into a single briefing for operator review.

---

### Component 1: Connectivity Check

Run `scripts/lib/pre-flight.sh` with the active mode.

```bash
bash "$CLAUDE_PROJECT_DIR/scripts/lib/pre-flight.sh" "<mode>"
```

Parses JSON output. If `ready: false`, report failures prominently but
continue building the plan — operator may override connectivity gaps.

**Store result as:** `connectivity` section of the briefing.

**Fail-fast rule:** If gateway is unreachable AND mode requires range access,
warn operator that the entire plan depends on range connectivity. Do not
skip remaining components — build the plan anyway so operator sees full scope.

---

### Component 2: Target Inventory

Query authoritative sources for scoped targets.

**Sources (in priority order):**

1. **Providentia** (range-intel MCP): `providentia_hosts` for host inventory,
   `providentia_vulns` for deployed vulnerabilities
2. **GitLab READMEs** (range-intel MCP): `gitlab_readme` per target for
   deploy config, known defaults, service details
3. **Engagement YAML** (`engagement-state` skill): pre-scoped targets if
   engagement already has a target list
4. **Obsidian** (pre-engagement-cache output): cached intel from prior cache run

**If `type: black-box`:** Skip all authoritative sources. Target inventory
comes from operator's provided scope only. Mark as `intel_source: operator_provided`.

**Output per target:**

```
- hostname: <name>
  ip: <address>
  os: <platform>
  services: [<port>/<proto> <service> <version>, ...]
  deployed_vulns: [<vuln-name>, ...]
  intel_source: providentia | gitlab | cache | operator_provided
```

**Store result as:** `targets` section of the briefing.

---

### Component 3: Attack Vectors per Target

For each target from Component 2, map attack vectors. Every vector must
cite its source — no assumptions.

**Sources:**

1. Providentia vuln names → map to technique
2. GitLab README sections → known credentials, misconfigs, service details
3. `technique-scoring` skill → ranked by empirical success rate + OPSEC cost
4. `note-search` skill → operator's prior experience with this target/service
5. Reference MCPs (hacktricks, mitre, lolbins) → technique detail

**Output per target:**

```
- target: <hostname>
  vectors:
    - technique: <name>
      source: <providentia vuln | gitlab readme section | technique-score | operator note>
      confidence: high | medium | low
      opsec_cost: CRITICAL | HIGH | MEDIUM | LOW
      priority: <1-N>
      notes: <why this vector, what makes it viable>
```

**Priority ordering:** High confidence + low OPSEC cost first. CRITICAL
OPSEC cost vectors last (or flagged for skip).

**Store result as:** `vectors` section of the briefing.

---

### Component 4: Justification

Summarize why each target and vector was selected. Tie to engagement objectives.

For each target:
- Why this target? (network position, value, known vuln, objective alignment)
- Recommended attack order and reasoning
- Dependencies between targets (pivot paths, credential reuse potential)

**Store result as:** `justification` section of the briefing.

---

### Component 5: Command Queue Preview

Build the concrete command list that will execute. Each command tagged with
OPSEC rating.

**Subsumes #352 (command queue preview).**

For each planned action:

```
- step: <N>
  target: <hostname>
  tool: <tuoni | kali-tool | mcp-tool>
  command: <exact command or description>
  opsec_rating: CRITICAL | HIGH | MEDIUM | LOW
  detection_signature: <what defenders would see>
  reversible: true | false
```

**Aggregate noise estimate:**
- Count commands by OPSEC rating
- Estimate total network signatures generated
- Flag any CRITICAL commands for individual review

**Store result as:** `command_queue` section of the briefing.

---

### Component 6: Risk Assessment

Aggregate OPSEC posture for the full engagement plan.

**Include:**
- Overall noise level (LOW/MEDIUM/HIGH/CRITICAL) based on command queue
- Detection likelihood per defensive layer (network IDS, host EDR, log monitoring)
- Scope exclusions: GT/admin accounts, infrastructure hosts, out-of-scope subnets
- Defensive awareness: known Wazuh agents, logging config, blue team coverage
- Engagement constraints: time window, allowed hours, rate limits

**Store result as:** `risk` section of the briefing.

---

### Component 7: Operator Approval Gate

Present the complete briefing to the operator. Structured for fast review.

**Briefing format:**

```
═══════════════════════════════════════════════════
  PRE-FLIGHT BRIEFING — <engagement-id>
═══════════════════════════════════════════════════

CONNECTIVITY: <N>/<M> checks passed
  [list any failures]

TARGETS: <N> hosts in scope
  [table: hostname | IP | OS | vuln count | priority]

ATTACK VECTORS: <N> vectors across <M> targets
  [table: target | technique | confidence | OPSEC cost]

COMMAND QUEUE: <N> commands planned
  CRITICAL: <n>  HIGH: <n>  MEDIUM: <n>  LOW: <n>

RISK LEVEL: <overall rating>
  [1-line summary of detection risk]

SCOPE EXCLUSIONS:
  [list]

═══════════════════════════════════════════════════
```

**Approval options:**

1. **EXECUTE ALL** — proceed with full plan, harness-driven
2. **REVIEW EACH** — step-by-step approval per command
3. **SKIP CRITICAL** — execute all except CRITICAL-rated commands
4. **MODIFY** — operator edits targets/vectors before proceeding
5. **ABORT** — cancel engagement start

**Wait for explicit operator response.** Do not proceed on silence or timeout.

**Store result as:** `approval` field — the operator's choice.

---

## Integration with engagement-orchestration

This skill replaces the current Phase 0 sequence. engagement-orchestration
should call pre-flight as the single Phase 0 entry point:

```
Phase 0 (master, inline):
  1. pre-flight skill (this skill)
     - runs connectivity check
     - builds target inventory
     - maps vectors
     - previews commands
     - assesses risk
     - gates on operator approval
  2. Only after approval: proceed to Phase 1 (reachability + enum)
```

The current Phase 0 steps (spoke-health, engagement-state,
pre-engagement-cache, kali-bootstrap) become sub-steps within this skill's
connectivity check and target inventory components.

## Structured Output

The complete briefing is a JSON object:

```json
{
  "engagement_id": "<id>",
  "mode": "<active mode>",
  "timestamp": "<ISO8601>",
  "connectivity": { "ready": true, "checks": [...] },
  "targets": [ { "hostname": "...", "ip": "...", ... } ],
  "vectors": [ { "target": "...", "technique": "...", ... } ],
  "justification": { "summary": "...", "target_rationale": [...] },
  "command_queue": { "commands": [...], "noise_estimate": "..." },
  "risk": { "overall": "MEDIUM", "details": "..." },
  "approval": "execute_all | review_each | skip_critical | modify | abort"
}
```

This JSON is written to Obsidian engagement page as the flight plan record.
Downstream phases reference it for target ordering and vector priority.

## Error Handling

- MCP unreachable: degrade that component, note in briefing, continue
- Providentia empty: fall through to GitLab/cache/operator-provided
- No engagement YAML: prompt operator to create one (engagement-state skill)
- Connectivity all-fail: still build the plan from cached data, flag prominently
