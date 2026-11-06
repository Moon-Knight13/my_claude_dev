# Red Stack Review — Portable Red Team Stack

> **Date:** 2026-11-06 | **Status:** Architecture review (read-only analysis)
> **Reviewer:** Claude Opus 4.6 | **Mode:** platform-ops

## Proposed plan

Three-layer portable red team provisioning:

1. Ansible playbook (`kali-provision.yml`) in homelab_planning — provisions
   Debian/Kali with tools (hashcat, nuclei, bloodhound-python, impacket, Docker)
2. Docker Compose stack (`red-stack.yml`) in homelab_planning — Neo4j +
   BloodHound CE, optional Tuoni, configurable ports
3. Future OCI image pre-built from playbook

Catapult becomes one deployment channel among several. `kali-bootstrap` skill in
my_claude_dev wraps whichever provisioning path matches the environment.

## 1. Alignment

**Strong alignment with v3 vision.** ARCHITECTURE_VISION.md explicitly plans
multi-environment expansion where the range-specific parts are "configuration,
not code." Portable provisioning is a prerequisite for CTF, pentest, and bounty
modes — all of which need offensive tooling on non-range boxes. The PRD names
Kali as the primary weapons spoke and acknowledges it must work beyond the
current DCM range.

The `kali-bootstrap` skill wrapper aligns with the existing pattern: skills
abstract environment differences, mode rules select capabilities.

## 2. Drift

**Minor drift: homelab_planning scope.** That repo's SPEC is an on-prem
IaC platform pattern (Proxmox + pfSense, CIS hardening, compliance evidence).
A red team provisioning playbook is not a homelab service — it provisions an
operator workstation. It does not fit CAP-1 through CAP-28 or any existing
epic.

The playbook is closer to my_claude_dev's `scripts/host/` provisioning surface
(which already provisions remote boxes) than to homelab_planning's L0–L5
layered IaC.

**No drift from my_claude_dev scope.** The PRD and v3 vision both describe
spoke provisioning as in-scope.

## 3. Overengineering

| Layer | Verdict | Notes |
|-------|---------|-------|
| L1 Ansible playbook | **Build now** | Direct value. Eliminates manual kali setup. Idempotent re-run after reroll |
| L2 Docker Compose | **Build now** | Neo4j + BloodHound CE are heavy to set up manually. Compose is minimal |
| L3 OCI image | **Defer** | Only valuable at scale or for CI. One operator does not need a pre-baked image yet |

Minimum viable version: L1 + L2. Tuoni in Compose is optional (it has its own
deploy path via catapult already — adding a second deploy method creates
ambiguity about which is canonical).

## 4. Repo fit

**homelab_planning is the wrong home.** Its SPEC governs a homelab IaC pattern.
Red team provisioning is operator toolchain, not infrastructure service.

Options:
- **my_claude_dev `scripts/provision/`** — natural extension of existing
  `scripts/host/provision-remote-box.sh`. Keeps provisioning near the skill
  that wraps it. Single repo for the operator stack.
- **Standalone repo** (e.g. `red-team-toolkit`) — if portability to non-my_claude_dev
  users matters. Premature unless sharing is planned.

Recommendation: **my_claude_dev**. Playbook + compose in `scripts/provision/`,
skill in `config/claude/skills/`. One PR, one test surface.

## 5. Conflicts

- **catapult/ctp-bridge:** No conflict if Tuoni stays out of Compose (catapult
  remains canonical Tuoni deploy path). Conflict if Compose introduces a second
  Tuoni deployment — operator must know which instance agents call home to.
- **green-dev mode:** No conflict. Green-dev deploys range infra via catapult.
  This provisions the operator's own box.
- **kali-bootstrap skill:** Currently wraps SSH-based checks. Extending it to
  call Ansible or Compose is additive, not conflicting.
- **homelab mode:** No conflict if playbook lives in my_claude_dev. Conflict if
  it lives in homelab_planning and homelab mode assumes everything there is IaC
  platform work.

## 6. Recommendation

**Build now:**
- Ansible playbook (L1) + Docker Compose (L2, without Tuoni) in
  `my_claude_dev/scripts/provision/`
- Update `kali-bootstrap` skill to detect and use Ansible when available,
  fall back to current SSH checks otherwise

**Defer:**
- OCI image (L3) — no need yet
- Tuoni in Compose — catapult is canonical, avoid two deploy paths
- Placement in homelab_planning — wrong repo scope

**Open question:** Does the playbook target only Kali, or any Debian box with
offensive tooling? If the latter, name it `operator-provision.yml` not
`kali-provision.yml` — matches v3's multi-environment intent.
