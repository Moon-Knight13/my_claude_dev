---
name: pre-flight
description: "Pre-engagement flight plan — full briefing before offensive execution. Checks connectivity, builds target inventory, maps attack vectors, previews command queue, assesses risk, and gates on operator approval. Nothing offensive fires until approved. Use when operator says 'pre-flight', 'flight plan', 'briefing', 'ready check', or at engagement start before Phase 1."
modes: [red-team, purple, ctf, pentest]
disable-model-invocation: true
---

# Pre-Engagement Flight Plan (mini)

Full briefing before offensive execution. Nothing fires until operator approves.

## 7 Components (sequential)

1. **Connectivity** — `bash scripts/lib/pre-flight.sh <mode>` → JSON. Continue even if failures.
2. **Target inventory** — Providentia hosts+vulns, GitLab READMEs, engagement YAML, cached intel. Per target: hostname, IP, OS, services, deployed vulns, intel source.
3. **Attack vectors** — per target from live intel, not assumptions. Each cites source (Providentia vuln, GitLab section, technique-score, operator note). Priority: high confidence + low OPSEC first.
4. **Justification** — why each target/vector selected. Priority ordering by impact. Dependencies between targets.
5. **Command queue** — exact commands, each tagged CRITICAL/HIGH/MEDIUM/LOW OPSEC. Aggregate noise estimate. Subsumes #352.
6. **Risk assessment** — overall noise, detection likelihood, scope exclusions, defensive awareness.
7. **Approval gate** — present briefing, wait for: EXECUTE ALL | REVIEW EACH | SKIP CRITICAL | MODIFY | ABORT.

## Integration

Replaces engagement-orchestration Phase 0. Current Phase 0 steps (spoke-health, engagement-state, pre-engagement-cache, kali-bootstrap) become sub-steps within connectivity + target inventory.

## Output

JSON briefing written to Obsidian engagement page. Fields: connectivity, targets, vectors, justification, command_queue, risk, approval.

## Error handling

MCP down: degrade that component, note in briefing, continue. Providentia empty: fall through. No engagement YAML: prompt creation. All-fail connectivity: build plan from cache, flag prominently.
