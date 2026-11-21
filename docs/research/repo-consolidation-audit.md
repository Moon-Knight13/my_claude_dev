# Moon-Knight13 Repository Consolidation Audit

**Date:** 2026-11-21
**Scope:** All 45 repos under github.com/Moon-Knight13
**Method:** `gh repo list` + per-repo CLAUDE.md, template-sync, README, last-commit checks

---

## Summary

| Classification       | Count | Action needed |
|----------------------|------:|---------------|
| HQ (this repo)       |     1 | —             |
| Template             |     1 | Maintain      |
| Satellite            |     6 | Orchestrate   |
| Project repo         |     2 | Deploy via HQ |
| Absorb candidate     |     3 | Evaluate      |
| Personal/hobby       |     6 | Leave alone   |
| Coursework           |    10 | Archive batch |
| AI experiments       |     4 | Consolidate   |
| Forks                |     8 | Prune         |
| Archived             |     1 | Already done  |
| Misc utility         |     3 | Case-by-case  |

---

## Tier 1 — HQ + Template

### my_claude_dev — **HQ**
- **Last commit:** 2026-11-21
- **CLAUDE.md:** Yes
- **Template-sync:** Detached 2026-10-16
- **Notes:** The hub. Everything orbits this.

### claude_template_repo — **Template**
- **Last commit:** 2026-11-21
- **CLAUDE.md:** Yes
- **Visibility:** Public
- **Notes:** Upstream pattern source. 1 open PR (#89 — harness hardening). All downstream repos with template-sync pull from here. Must stay independent — it serves external consumers too.

---

## Tier 2 — Satellites (HQ orchestrates, repos stay separate)

### tuoni-mcp — **Satellite**
- **Last commit:** 2026-11-21 | **Private** | **CLAUDE.md:** Yes
- **Template-sync:** No (not downstream of claude_template_repo)
- **HQ relationship:** Primary offensive MCP server. HQ connects via `.env` config.
- **Cross-contamination risk:** HIGH. Offensive tooling. Must never merge into public HQ repo.
- **HQ orchestration:** red-team mode, Tuoni MCP spoke config, `tuoni-mcp` skill.

### tuoni-plugins — **Satellite**
- **Last commit:** 2026-11-08 | **Private** | **CLAUDE.md:** Yes
- **Template-sync:** No
- **HQ relationship:** C2 command plugins deployed to Tuoni agents.
- **Cross-contamination risk:** HIGH. Offensive payloads, privesc tools.
- **HQ orchestration:** red-dev mode, ctp-bridge deploys, `persist-swarm` / `lateral-move` skills.

### homelab_infra — **Satellite**
- **Last commit:** 2026-11-21 | **Public** | **CLAUDE.md:** Yes
- **Template-sync:** Yes (active, merged)
- **HQ relationship:** IaC pattern repo for on-prem dev platform. HQ's planned homelab mode targets this.
- **Cross-contamination risk:** LOW. Public, clean separation. No secrets.
- **HQ orchestration:** homelab mode (planned, #388-#392), UniFi+Docker MCPs.

### homelab_planning — **Satellite**
- **Last commit:** 2026-11-08 | **Private** | **CLAUDE.md:** No
- **Template-sync:** No
- **HQ relationship:** BMAD planning artifacts + deployment-specific settings for homelab_infra. Lives as `_bmad-output/` inside homelab_infra workspace.
- **Cross-contamination risk:** MEDIUM. Contains identity-linking references and stale IPs per its own README. Must never be made public.
- **HQ orchestration:** Read-only via homelab mode. No MCP needed — git clone when planning.

### foundryvtt-docker — **Satellite**
- **Last commit:** 2026-11-20 | **Public** | **CLAUDE.md:** Yes
- **Template-sync:** Yes (active, merged)
- **HQ relationship:** Containerized FoundryVTT server. Deployed to homelab.
- **Cross-contamination risk:** LOW. Clean Docker project.
- **HQ orchestration:** homelab mode deploys, Docker MCP.

### medicat-usb — **Satellite**
- **Last commit:** 2026-11-21 | **Public** | **CLAUDE.md:** Yes
- **Template-sync:** Yes (action bumps only)
- **HQ relationship:** USB rescue stick builder. Standalone utility.
- **Cross-contamination risk:** NONE. Completely independent tool.
- **HQ orchestration:** None needed. Standalone build script. No mode affinity.

---

## Tier 3 — Project Repos (standalone, template-sync downstream)

### project_dungeon — **Project repo**
- **Last commit:** 2026-11-21 | **Public** | **CLAUDE.md:** Yes
- **Template-sync:** Yes (active, merged)
- **Purpose:** Upskill programme example page redesign. Learning/demonstration repo.
- **HQ relationship:** Demonstrates template patterns. No deployment dependency.

### foundry-gm-claude-plugin — **Project repo**
- **Last commit:** 2026-11-21 | **Public** | **CLAUDE.md:** Yes
- **Template-sync:** Yes (active, merged)
- **Purpose:** Claude Code plugin marketplace for FoundryVTT GM toolkit.
- **HQ relationship:** Independent plugin. Could reference HQ patterns but no operational dependency.

---

## Tier 4 — Absorb Candidates

### azure-dev-harness — **Absorb candidate**
- **Last commit:** 2026-11-21 | **Public** | **CLAUDE.md:** Yes
- **Template-sync:** Yes (action bumps)
- **Purpose:** Azure dev environment bootstrap (7-phase validator, Bicep IaC, 2 MCP servers).
- **Absorb case:** Pattern could become an HQ mode ("azure-dev" or "cloud-dev"). The 7 skills and 2 MCP servers mirror HQ's mode architecture.
- **Absorb risk:** Azure-specific Bicep modules and state tracking don't generalize. Better as satellite with an HQ mode that orchestrates it.
- **Recommendation:** Keep separate repo. Add HQ `azure-dev` mode that connects its MCPs. Same pattern as homelab mode.

### weaponised_ansible — **Absorb candidate**
- **Last commit:** 2026-01-25 | **Private** | **CLAUDE.md:** No
- **Purpose:** Ansible playbooks for offensive automation (firewall exploitation, roster management).
- **Absorb case:** HQ's red-team mode + tuoni-mcp + ctp-bridge have largely superseded this. Engagement profiles, roster exports, firewall targeting.
- **Absorb risk:** HIGH cross-contamination. Offensive content with specific network references.
- **Recommendation:** Extract any reusable patterns into HQ skills. Archive remainder. Do NOT merge into HQ — keep offensive content in private repos only.

### nosense_ip_updater — **Absorb candidate**
- **Last commit:** 2026-02-01 | **Private** | **CLAUDE.md:** No
- **Purpose:** Range IP management utility + Tuoni beacon seeding helper.
- **Absorb case:** Functions overlap with range-intel-mcp and engagement-state skill.
- **Absorb risk:** Contains range-specific IPs and paths.
- **Recommendation:** Migrate useful functions into tuoni-mcp or a range-ops skill. Archive repo.

---

## Tier 5 — AI Experiment Repos (consolidation opportunity)

### my_ai_package — **AI experiment**
- **Last commit:** 2026-01-16 | **Private** | **CLAUDE.md:** No
- **Purpose:** Docker Compose stack: Ollama + OpenWebUI + N8N + Postgres + PGAdmin.
- **Notes:** Original AI package attempt. Superseded by Ai_Suite.

### Ai_Suite — **AI experiment**
- **Last commit:** 2025-08-27 | **Private** | **CLAUDE.md:** No
- **Purpose:** Fork/variant of coleam00's self-hosted AI starter kit. Adds Supabase, Flowise, Neo4j, Langfuse.
- **Notes:** More complete than my_ai_package. Podman edition per description.

### local_ai_pack — **AI experiment**
- **Last commit:** 2025-07-31 | **Private** | **CLAUDE.md:** No
- **Purpose:** Identical README to Ai_Suite. Appears to be earlier iteration.
- **Notes:** Duplicate.

### supabase-project — **AI experiment**
- **Last commit:** 2025-08-21 | **Private** | **CLAUDE.md:** No
- **Purpose:** Unknown (no description). Likely Supabase experimentation.

**Recommendation:** Pick one winner (Ai_Suite most complete), archive the other three. If homelab mode needs a local AI stack, reference Ai_Suite from homelab_infra.

---

## Tier 6 — Personal / Hobby

| Repo | Private | Last commit | Purpose | Action |
|------|---------|-------------|---------|--------|
| dnd | Yes | 2026-05-26 | D&D campaign notes | Leave |
| DnDCharacterCreator | Yes | 2025-03-11 | D&D character tool | Archive candidate |
| obsidian | Yes | 2026-05-25 | Vault backup | Leave (critical) |
| event | Yes | 2025-03-18 | Unknown | Archive candidate |
| VMHBPi | Yes | 2025-06-06 | Web kiosk app | Archive candidate |
| continue-agent-config | Yes | 2026-06-14 | VS Code Continue config | Archive if Ollama failover moves to HQ |

---

## Tier 7 — Coursework (batch archive)

All repos below are course final projects or learning exercises. None have CLAUDE.md or template-sync. None relate to HQ.

| Repo | Visibility | Last commit | Course |
|------|-----------|-------------|--------|
| skills-introduction-to-github | Public | 2026-11-07 | GitHub learning lab |
| devops-capstone-project | Public | 2026-06-20 | DevOps capstone |
| ci-cd-final-project | Public | 2026-05-29 | CI/CD course |
| tdd-bdd-final-project | Public | 2026-03-20 | TDD/BDD course |
| github-final-project | Public | 2025-12-15 | GitHub course |
| agile-final-project | Public | 2025-11-22 | Agile/Scrum course |
| M5_Projects | Public | 2025-01-30 | M5 course tasks |
| todo_project | Public | 2025-01-25 | Tutorial project |
| haikus-for-codespaces | Private | 2025-01-25 | Codespaces tutorial |
| PCEP_Notes | Private | 2025-01-25 | PCEP cert notes |
| comptia_net_plus | Private | 2026-04-15 | CompTIA Net+ notes |

**Recommendation:** Archive all 11 in one batch. Coursework serves no ongoing purpose. CompTIA notes might still be useful — confirm before archiving.

---

## Tier 8 — Forks (prune candidates)

| Repo | Source | Last push | Purpose |
|------|--------|-----------|---------|
| tuoni-mcp-1 | shell-dot/tuoni-mcp | 2026-10-27 | Upstream contribution fork (PR #1) |
| foundryvtt-docker-upstream | felddy/foundryvtt-docker | 2026-09-20 | Upstream tracking |
| graphy_server | — | 2026-06-06 | Coursework fork |
| fgxgm-SecurityCheckSample | — | 2026-06-06 | Coursework fork |
| wtecc-CICD_PracticeCode | — | 2026-05-27 | Coursework fork |
| robot-shop | — | 2026-05-14 | Coursework fork |
| NLP-Emotion-Detection | — | 2026-01-22 | Coursework fork |
| mcino-Introduction-to-Git-and-GitHub | — | 2025-12-15 | Coursework fork |

**Recommendation:**
- **Keep:** tuoni-mcp-1 (active upstream contribution), foundryvtt-docker-upstream (tracking)
- **Delete:** remaining 6 coursework forks. No ongoing value.

---

## Tier 9 — Archived

| Repo | Notes |
|------|-------|
| homelab | Superseded by homelab_infra. Already archived. |

---

## CV / Career Repos

| Repo | Private | Last commit | Notes |
|------|---------|-------------|-------|
| my_cv | Yes | 2026-03-16 | CV workspace |
| my_cv_pub | Yes | 2026-03-16 | Public-facing CV |

**Leave as-is.** Career materials, no HQ relationship.

---

## Cross-Reference: Template-Sync Network

```
claude_template_repo (source)
  ├── my_claude_dev (DETACHED 2026-10-16)
  ├── foundry-gm-claude-plugin (active sync)
  ├── project_dungeon (active sync)
  ├── homelab_infra (active sync)
  ├── foundryvtt-docker (active sync)
  ├── medicat-usb (action bumps only)
  └── azure-dev-harness (action bumps only)
```

Repos without template-sync lack the security gates, CI pipeline, and CLAUDE.md patterns that the template provides.

---

## HQ Orchestration Map

What HQ needs to operate each satellite:

| Satellite | HQ Mode | Spoke/MCP needed | Status |
|-----------|---------|-------------------|--------|
| tuoni-mcp | red-team, purple | tuoni-mcp server (installed) | LIVE |
| tuoni-plugins | red-dev | ctp-bridge deploy | LIVE |
| homelab_infra | homelab (planned) | UniFi MCP, Docker MCP | PLANNED (#388-#392) |
| homelab_planning | homelab (planned) | git clone (read-only) | PLANNED |
| foundryvtt-docker | homelab (planned) | Docker MCP | PLANNED |
| azure-dev-harness | azure-dev (proposed) | @azure/mcp, azops-mcp | NOT STARTED |
| medicat-usb | — | None | Standalone |

---

## Recommended Actions

### Immediate (low effort, high cleanup)
1. **Archive 11 coursework repos** in one batch
2. **Delete 6 coursework forks** (keep tuoni-mcp-1, foundryvtt-docker-upstream)
3. **Archive 3 of 4 AI experiment repos** (keep Ai_Suite, archive my_ai_package, local_ai_pack, supabase-project)

### Near-term (supports active work)
4. **Archive weaponised_ansible** after extracting any patterns not already in HQ skills
5. **Archive nosense_ip_updater** after migrating useful functions to tuoni-mcp/range-intel
6. **Add CLAUDE.md to homelab_planning** (private, but would benefit from template patterns)

### Strategic (tied to HQ roadmap)
7. **homelab mode** (#388-#392) — orchestrates homelab_infra, homelab_planning, foundryvtt-docker
8. **azure-dev mode** — if Azure work resumes, model after homelab mode pattern
9. **Continue config** — if model failover lands in HQ, absorb continue-agent-config patterns

### Leave alone
- Personal repos (dnd, obsidian, CV repos)
- DnDCharacterCreator, event, VMHBPi — archive when convenient, no urgency

---

## Cross-Contamination Risk Matrix

| Repo | Public? | Offensive content? | Risk if brought closer to HQ |
|------|---------|-------------------|------------------------------|
| tuoni-mcp | No | Yes (C2 control) | CRITICAL — must stay separate repo, private |
| tuoni-plugins | No | Yes (payloads) | CRITICAL — must stay separate repo, private |
| weaponised_ansible | No | Yes (exploitation) | HIGH — extract, don't merge |
| nosense_ip_updater | No | Partial (beacon seeding) | MEDIUM — migrate functions only |
| homelab_planning | No | No, but has identity-linking refs | MEDIUM — never make public |
| All others | Mixed | No | LOW/NONE |
