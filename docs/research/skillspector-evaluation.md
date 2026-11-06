# NVIDIA SkillSpector — Evaluation for Our Skills

**Date:** 2026-11-06
**Status:** Research only — not installed

## What SkillSpector Is

Open-source security scanner (Apache-2.0) from NVIDIA for AI agent skills.
Part of their "Verified Skills" pipeline. Scans skill files for vulnerabilities
and malicious patterns before installation.

Repository: https://github.com/NVIDIA/skillspector

## How It Works

Two-stage analysis:

1. **Static analysis** (always runs): regex patterns, Python AST checks, YARA
   signatures, and OSV.dev dependency lookups. Deterministic, fast.
2. **LLM semantic review** (optional, `--no-llm` to skip): sends file contents
   to a configurable LLM provider for deeper analysis. Can confirm or add
   confidence to static findings but never removes them.

### Detection Coverage

71 patterns across 17 categories:

- Prompt injection, anti-refusal, system prompt leakage
- Data exfiltration, privilege escalation, credential access
- Supply chain: unpinned/vulnerable dependencies, typosquatting, obfuscation
- Excessive agency, memory poisoning, tool misuse, rogue agent behavior
- Trigger abuse, behavioral AST checks, taint tracking
- MCP least-privilege violations, MCP tool poisoning

### Risk Scoring

Points per finding: CRITICAL +50, HIGH +25, MEDIUM +10, LOW +5.
Executable scripts get 1.3x multiplier.

| Score   | Band     | Recommendation   |
|---------|----------|------------------|
| 0–20    | LOW      | SAFE             |
| 21–50   | MEDIUM   | CAUTION          |
| 51–80   | HIGH     | DO NOT INSTALL   |
| 81–100  | CRITICAL | DO NOT INSTALL   |

### Output Formats

Terminal (default), JSON, Markdown, SARIF 2.1.0.

### Installation

```bash
uv tool install git+https://github.com/NVIDIA/skillspector.git
# or from source
make install
```

Requires Python 3.12–3.15. Optional `[mcp]` extra for MCP server mode.

### Basic Usage

```bash
skillspector scan ./path/to/skills/
skillspector scan ./path/to/skills/ --no-llm        # static only
skillspector scan ./path/to/skills/ --format json    # JSON output
skillspector scan ./path/to/skills/ --format sarif   # SARIF for CI
```

## Compatibility With Our Skills Directory

### Our `.claude/skills/` structure

- **64 skill directories** (48 bmad-*, 16 custom operational)
- **244 total files**: 186 `.md`, ~30 `.toml` (customization), ~10 `.py` (helper scripts)
- Each skill = directory with `SKILL.md` (frontmatter + markdown instructions)
- Some skills have companion markdown files (templates, checklists, step guides)
- Python scripts exist in `bmad-*/scripts/` directories

### Will It Scan Our Skills?

**Yes.** SkillSpector accepts a directory path and recursively scans it. Our
`SKILL.md` format (YAML frontmatter + markdown body) matches what it expects.
Default limit is 32 skills per scan; we have 64 directories, so would need
`--max-skills 64` or two passes.

Expected scan command:
```bash
skillspector scan .claude/skills/ --max-skills 64 --no-llm
```

### What It Would Check

| Check Category | Applies to Us? | Notes |
|---|---|---|
| Prompt injection patterns | **Yes** — primary value | Our red-team skills (cred-harvest, initial-access, lateral-move, persist-swarm) contain offensive instruction text that may trigger false positives |
| Anti-refusal patterns | **Likely flags** | Skills that instruct Claude to bypass safety guardrails for authorized offensive ops would flag |
| Data exfiltration | **Yes** | Skills reference tuoni-mcp, SSH, network operations |
| Credential access | **Yes** | cred-harvest skill explicitly handles credentials |
| Excessive agency | **Possible** | Skills that auto-execute commands without confirmation |
| Supply chain (deps) | **Minimal** | Only ~10 Python scripts, no npm dependencies in skills dir |
| Python AST analysis | **Yes** | Would scan `scripts/*.py` files |
| MCP tool poisoning | **Possible** | Skills reference MCP servers by name |
| YARA signatures | **Yes** | Scans all file content |

### Expected Findings Profile

**High false-positive rate predicted.** Our operational skills are designed to
instruct an AI agent to perform offensive security operations (within authorized
scope). SkillSpector's detection patterns are designed to flag exactly this kind
of content — it cannot distinguish "authorized red-team instruction" from
"malicious skill trying to weaponize an agent."

Expected categories of false positives:
1. **Anti-refusal** — skills that tell Claude to proceed with offensive actions
2. **Credential access** — cred-harvest skill is literally about this
3. **Privilege escalation** — lateral-move, initial-access by design
4. **Excessive agency** — persist-swarm deploys beacons autonomously
5. **Data exfiltration** — discovery skill enumerates and reports back

The bmad-* planning/workflow skills should scan clean or low-risk.

### Practical Value Assessment

| Use Case | Value | Verdict |
|---|---|---|
| Scan bmad-* skills for supply chain / injection risks | **High** | Legitimate security check for third-party skill framework |
| Scan custom red-team skills | **Low** | Nearly all findings will be false positives by design |
| CI gate for new skill PRs | **Medium** | Useful for bmad-* updates; needs baseline/exclusion for red-team skills |
| Audit third-party skills before installing | **High** | Primary intended use case — good fit |
| MCP server mode for on-demand scanning | **Medium** | Could integrate with our spoke health checks |

### Baseline Strategy

SkillSpector supports baselines (`skillspector baseline`) to suppress known
findings. Recommended approach:

1. Run initial scan, review all findings
2. Triage: fix real issues, baseline expected operational content
3. Use baseline in CI so only *new* findings break the build
4. Separate scans: bmad-* skills (strict gate) vs red-team skills (baselined)

## Limitations

- Static analysis only — never executes skill code
- Cannot assess runtime behavior or actual MCP interactions
- LLM mode sends file contents to external provider (OPSEC concern for red-team skills)
- 1 MB per-file limit (our skills are well under this)
- May miss non-English content, encrypted/compiled code
- No authentication on MCP HTTP transport (loopback only)

## Recommendation

**Worth adopting for the bmad-* skill subset.** Run static-only (`--no-llm`) to
avoid sending skill content to external LLM providers. Baseline red-team skills
separately. Consider adding to CI for skill-touching PRs.

Do not run LLM mode against red-team skills — sending offensive operational
instructions to external LLM providers is an OPSEC violation.

### Next Steps (if approved)

1. Install in dev container: `uv tool install git+https://github.com/NVIDIA/skillspector.git`
2. Run static scan against bmad-* skills only
3. Review findings, create baseline
4. Evaluate CI integration for skill PRs
5. Separately: baselined scan of red-team skills for any real supply-chain issues
