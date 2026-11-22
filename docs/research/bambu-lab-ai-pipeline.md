# Natural Language to 3D Print: Bambu Lab AI Pipeline Research

**Date:** 2026-11-22
**Updated:** 2026-11-22 — added design iteration projects, Bambu Studio in-loop architecture, security + implementation review
**Status:** Architecture finalized — ready for story decomposition

---

## 1. Existing Projects Assessed

### 1.1 yuvalcohenrappaport/claude-bambu-printer

- **URL:** https://github.com/yuvalcohenrappaport/claude-bambu-printer
- **What it does:** Claude Code skill generating 3D-printable models from natural language. Integrates OpenSCAD, Blender, MakerWorld search, and Bambu printer dispatch (3MF upload).
- **Architecture:** Claude Code skill (`.claude/skills/print/`), FastAPI backend, Pydantic models, Claude Agent SDK. Poetry for dependency management.
- **Maturity:** Early-stage. One fork exists (drauchtest). Star count not confirmed but low. Skill-based, not MCP.
- **Requirements:** BambuStudio installed, OpenSCAD, Python env, `.env` with printer credentials.
- **Gaps:** Skill-only (no MCP tools), unclear error handling on print failures, no camera/monitoring feedback loop, no AMS filament awareness in generation.

### 1.2 Bambu Lab 3D Print Automation (mcpmarket / dvcrn)

- **URL:** https://mcpmarket.com/tools/skills/bambu-lab-3d-print-automation
- **What it does:** Claude Code skill wrapping BambuStudio CLI. Downloads STL/3MF from Printables/MakerWorld/Thingiverse, slices via BambuStudio CLI, transmits to printer.
- **Architecture:** Skill installed via `npx skillfish add dvcrn/openclaw-skills-marketplace bambu-print`. Wrapper around BambuStudio CLI binary.
- **Maturity:** Published on mcpmarket marketplace. Community skill, not MCP server.
- **Requirements:** BambuStudio CLI in PATH, network access to printer.
- **Gaps:** No model generation (search/download only), depends on BambuStudio CLI availability on Linux (limited), no programmatic slice parameter control.

### 1.3 heyixuan2/bambu-studio-ai

- **URL:** https://github.com/heyixuan2/bambu-studio-ai
- **What it does:** Most complete skill found. Full pipeline: model search (MakerWorld, Printables), AI model generation via CAD, printability analysis with auto-repair, orientation optimization, preview rendering, Bambu Studio handoff, printer/AMS status reading.
- **Architecture:** Universal Agent Skill (SKILL.md spec) — works in Claude Code, Codex, Cursor, Gemini CLI, and others. v2.0.0 dropped OpenClaw coupling. Python scripts for printer communication.
- **Maturity:** Best in class. Featured in Bambu Lab's official 我的拓竹 Skill 大赏 (2026). ~100-250 GitHub stars (varies by aggregator snapshot). Active development with v2.0.0 release. Grade A on skillsdirectory.
- **Requirements:** macOS for full integration (Bambu Studio hooks + notifications). Linux/Windows can run Python scripts but lose Bambu Studio GUI hooks. Printer IP, serial, LAN access code needed. AI generation needs provider API key.
- **Gaps:** macOS-centric full experience, Linux gets degraded integration. Opinionated pipeline forces manual slicing step in Bambu Studio GUI. No headless slicing path.

### 1.4 Design Iteration Specialists (discovered in follow-up research)

#### nneves/openscad-part-design
- **URL:** https://github.com/nneves/openscad-part-design
- **What it does:** Claude Code skill for designing 3D-printable parts from description or sketch. Full validation before printing: renders, collision sweeps, measured walls, holes and fits.
- **Design cycle:** Description → parametric OpenSCAD → validation suite → iterate until passing. Saves printer specs in `printer.json` for constraint-aware generation.
- **Strength:** Closest to "engineering design iteration" — validates geometry against print constraints, not just visual appearance.

#### andreahaku/openscad_claude_skill
- **URL:** https://github.com/andreahaku/openscad_claude_skill
- **What it does:** OpenSCAD skill with explicit AI vision feedback loop. Renders multi-angle PNG previews, Claude analyzes rendered images, iteratively refines design.
- **Design cycle:** Generate .scad → render PNG from multiple angles → Claude vision inspects → identifies issues → modifies code → re-render → repeat.
- **Strength:** Closed-loop visual iteration without human in the loop for each refinement pass.

#### kalmehdar/claude-3d-printing
- **URL:** https://github.com/kalmehdar/claude-3d-printing
- **What it does:** Per-colour OpenSCAD export, mesh checks, Print Bench preview page, example designs. Skills and agents included.
- **Strength:** Multi-colour support, mesh validation, visual preview page.

#### jirihelmich/3dprint-starter
- **URL:** https://github.com/jirihelmich/3dprint-starter
- **What it does:** Starter project for Claude Code + OpenSCAD + Bambu Lab X1 Carbon.
- **Strength:** Minimal, opinionated starter — good reference for our own setup.

---

## 2. MCP Servers for Printer Control

### 2.1 schwarztim/bambu-mcp (Best for LAN control)

- **URL:** https://github.com/schwarztim/bambu-mcp
- **Architecture:** MCP server over local MQTT (TLS on port 8883). FTPS file upload. X.509 certificate signing to bypass firmware auth restrictions.
- **Tools:** ~25 tools including mqtt_connect, mqtt_disconnect, ftp_upload_file, stop-print, AMS status, camera access.
- **Printers:** P1P, P1S, X1C, A1, A1 Mini.
- **Requirements:** Developer Mode on printer. Env vars: printer IP, serial, LAN access code. Uses certificate extracted from Bambu Connect app (legal gray area).
- **Maturity:** MIT licensed, documented MQTT protocol reference. Community project.
- **Risk:** X.509 cert extraction from Bambu Connect — may break on firmware updates, not endorsed by Bambu Lab.

### 2.2 griches/bambu-mcp (Fleet management)

- **URL:** https://github.com/griches/bambu-mcp
- **Architecture:** MCP server via npx. Multi-printer fleet management.
- **Tools:** Start, pause, resume, stop prints. Skip objects mid-print. FTP file management. AMS support.
- **Best for:** Multi-printer setups.

### 2.3 DMontgomery40/bambu-printer-mcp (Slicing + control)

- **URL:** https://github.com/DMontgomery40/bambu-printer-mcp
- **Architecture:** MCP server. Bambu-focused fork of broader mcp-3D-printer-server (which covers OctoPrint, Klipper, Duet, Repetier, Prusa, Creality too).
- **Tools:** STL manipulation, auto-slicing (BambuStudio or FULU/Orca), FTPS upload, MQTT print control.
- **Unique:** Parent project has Blender MCP discovery and STL edit forwarding (v1.2.9+).
- **Best for:** Full slicing pipeline if headless slicing works.

### 2.4 Other notable servers

| Project | Focus |
|---------|-------|
| artemnovichkov/claude-code-bambu-lab | Claude Code pane: live status, AMS, plate thumbnail (cloud API) |
| tyty-the-eyety/bambu-printer-skill | A1 LAN monitor: status, camera, thermal watchdog, spaghetti pause |
| Shockedrope/bambu-mcp-server | Monitor-only from Claude Desktop |
| bambu-local (aimcp.info) | MQTT local control, no cloud dependency |

---

## 3. Bambu Lab Protocol Details

**No official public API.** All control is community-reverse-engineered.

### LAN Mode (preferred for our setup)
- MQTT broker on printer, port 8883 (TLS)
- Auth: username `bblp`, password = LAN access code
- Topics: `device/{serial}/request` (commands), `device/{serial}/report` (state)
- File transfer: FTPS on ports 990 + 50000-50100
- Video: ports 322 and 6000
- Enable via: Settings → Network → LAN Only Mode
- Developer Mode required for most MCP servers

### Cloud Mode
- Regional brokers: us.mqtt.bambulab.com, cn.mqtt.bambulab.com
- Auth via Bambu account credentials
- Higher latency, Bambu can change/restrict at will

### Firmware Auth
- Recent firmware requires X.509 certificate signing for some commands (print, movement)
- Community extracted cert from Bambu Connect desktop app
- **Risk:** Bambu may revoke or rotate certificates in firmware updates

### Recommendation: LAN mode
Printer on home network = LAN mode is natural fit. No cloud dependency, lower latency, works offline. Developer Mode is a one-time toggle.

---

## 4. Model Generation Pipeline

### 4.1 Code-based CAD (Claude generates code → compile → STL)

**OpenSCAD MCP servers (multiple options):**

| Server | Focus | Notes |
|--------|-------|-------|
| quellant/openscad-mcp | Render, export, analyze | FastMCP Python, Claude Code install documented |
| jkoets/OpenSCAD-MCP | Create/update .scad source | Small, 3 tools |
| petrijr/openscad-mcp | Validate, render, export | Parametric model focus |
| fboldo/openscad-mcp-server | Preview + STL export | Iterative refinement skill included |
| jhacksman/OpenSCAD-MCP-Server | Text→image→mesh→parametric | Most ambitious, uses Gemini + CUDA MVS |

**CadQuery / build123d:**
- `claude-cad` on PyPI: text prompt → 3D model → STEP/STL export
- Community `cadquery-mcp-server` exists but generation tool reported as stub
- build123d MCP recommended for parts needing later CAD editing (exports STEP, not just mesh)

**Assessment:** OpenSCAD is best path for Claude-generated printable parts. Claude writes parametric .scad code well. Compile to STL is deterministic. Multiple MCP servers available. CadQuery for engineering-grade STEP output.

### 4.2 AI mesh generation (text/image → mesh)

**Meshy (official MCP server):**
- Official: `@meshy-ai/meshy-mcp-server` on npm, 24 tools
- Text-to-3D: untextured preview mesh from text, then refine for texture
- Also: image-to-3D, remesh, rig, animate
- Install: `claude mcp add -s user meshy --env MESHY_API_KEY=... -- npx -y @meshy-ai/meshy-mcp-server`
- **Limitation:** Requires API key, credit-based pricing, mesh quality varies

**Other text-to-3D services:**
- **Zoo (formerly KittyCAD):** Exports clean STL, more engineering-focused
- **Tripo:** Writes STL and 3MF directly, auto-repair before export
- **3D AI Studio:** Web-based generation
- **Roblox Cube 3D:** Open-source mesh generator (2025)

**Assessment:** For functional/mechanical parts, code-based CAD (OpenSCAD) is superior — Claude controls geometry precisely. For organic/artistic shapes (figurines, decorative items), Meshy or similar text-to-3D services fill the gap. Almost all mesh generators need a cleanup pass before printing.

### 4.3 Model search (existing models)

Already covered by bambu-studio-ai skill: MakerWorld, Printables, Thingiverse search. The dvcrn skill also searches these. No MCP server needed for this — HTTP APIs are straightforward.

---

## 5. Full Pipeline Analysis: What Exists vs What's Missing

### Natural Language → 3D Print Pipeline

```
[User describes object] → [1. Interpret] → [2. Generate/Find model] → [3. Validate] → [4. Slice] → [5. Upload] → [6. Print] → [7. Monitor]
```

| Stage | Status | Best option today |
|-------|--------|-------------------|
| 1. NL interpretation | **EXISTS** | Claude native capability |
| 2a. Find existing model | **EXISTS** | bambu-studio-ai skill (MakerWorld/Printables search) |
| 2b. Generate parametric model | **EXISTS** | OpenSCAD MCP + Claude code generation |
| 2c. Generate organic mesh | **EXISTS** | Meshy MCP server (API key needed) |
| 3. Validate printability | **PARTIAL** | bambu-studio-ai has analysis/repair; no headless validator MCP |
| 4. Slice | **GAP** | BambuStudio CLI (macOS only full support) or OrcaSlicer CLI. No robust headless MCP slicer for Linux |
| 5. Upload to printer | **EXISTS** | schwarztim/bambu-mcp (FTPS), DMontgomery40 (FTPS) |
| 6. Start print | **EXISTS** | schwarztim/bambu-mcp (MQTT commands) |
| 7. Monitor | **EXISTS** | Multiple options: camera, status, thermal watchdog, spaghetti detect |

### Critical gaps
1. **~~Headless slicing on Linux~~** — RESOLVED: Bambu Studio already installed on operator machine (MediCat golden image). Operator uses Bambu Studio GUI as review checkpoint + slicer. No headless path needed.
2. **Print profile intelligence** — No MCP server maps material + printer + part geometry to optimal slice settings. Claude would need embedded knowledge or a profile database. Bambu Studio's built-in profiles partially cover this.
3. **Closed-loop feedback** — No existing project feeds print monitoring back into generation (e.g., "print failed at overhang, regenerate with supports in mind").
4. **Reference image to model** — Operator wants to use prototype reference images. Claude can see images and reason about geometry, but cannot trace directly to 3D. Best path: image → Claude interprets as geometric primitives → writes OpenSCAD code → iterate.

---

## 6. Architecture Recommendation (Revised)

### Selected: Bambu Studio In-Loop Architecture

Operator has Bambu Studio installed (MediCat golden image). This eliminates the headless slicing gap and adds a visual review checkpoint. Two-stage design iteration: fast cycles with Claude (OpenSCAD PNG renders), final validation in Bambu Studio 3D view.

```
┌───────────────────────────────────────────────────────────────┐
│  DESIGN ITERATION (fast, Claude-driven)                       │
│                                                               │
│  User: NL description + reference images + measurements       │
│    ↓                                                          │
│  Claude: writes OpenSCAD .scad code                           │
│    ↓                                                          │
│  OpenSCAD MCP: renders PNG preview (multi-angle)              │
│    ↓                                                          │
│  Claude: vision-inspects render, identifies issues            │
│    ↓                                                          │
│  User: feedback ("wider base", "add chamfer")                 │
│    ↓                                                          │
│  [loop until satisfied]                                       │
│    ↓                                                          │
│  OpenSCAD MCP: exports STL                                    │
└──────────────────────┬────────────────────────────────────────┘
                       ↓
┌──────────────────────┴────────────────────────────────────────┐
│  PRINT VALIDATION (Bambu Studio GUI — operator review)        │
│                                                               │
│  Claude opens STL in Bambu Studio: `bambu-studio model.stl`   │
│    ↓                                                          │
│  Operator reviews: 3D rotate, supports, layer sim, plate fit  │
│    ↓                                                          │
│  If issues → feedback to Claude → back to design iteration    │
│    ↓                                                          │
│  Operator slices in Bambu Studio (profile, supports, infill)  │
│    ↓                                                          │
│  Send to printer from Bambu Studio OR via bambu-mcp           │
└──────────────────────┬────────────────────────────────────────┘
                       ↓
┌──────────────────────┴────────────────────────────────────────┐
│  PRINT MONITORING (optional, bambu-mcp)                       │
│                                                               │
│  MQTT status polling, camera snapshots, failure detection     │
│  Thermal watchdog, spaghetti pause                            │
└───────────────────────────────────────────────────────────────┘
```

### MCP + Skill composition

| Component | Source | Role |
|-----------|--------|------|
| OpenSCAD MCP | quellant/openscad-mcp or fboldo/openscad-mcp-server | Render, export, validate .scad |
| bambu-mcp | schwarztim/bambu-mcp | MQTT printer control, status, camera |
| Bambu Studio | Already installed (MediCat) | Visual review, slicing, print profiles |
| Orchestration skill | Our build | Chains design → review → print workflow |
| Meshy MCP | meshy-dev/meshy-mcp-server (optional) | Organic shapes, image-to-3D |

### Tool surface (MCP tools available to Claude)

**From OpenSCAD MCP:**
- `render_scad` — Compile .scad to PNG preview
- `export_stl` — Compile .scad to STL mesh
- `validate_scad` — Syntax and geometry validation

**From bambu-mcp:**
- `printer_status` — Live state, temps, progress
- `ams_status` — Filament inventory
- `start_print` / `pause_print` / `stop_print`
- `ftp_upload_file` — Upload .3mf/.gcode to printer SD
- `camera_snapshot` — Visual print inspection

**From orchestration skill:**
- `open_in_bambu_studio` — Launch Bambu Studio with STL
- `design_iterate` — Full NL → .scad → render → inspect loop
- `search_models` — MakerWorld/Printables/Thingiverse query

---

## 7. Mode Design: 3d-print mode

**Verdict: Yes, warrants a mode (mode 13).**

Rationale: Distinct tool surface (printer MQTT, CAD generation, slicer), distinct safety concerns (physical actuator control), no overlap with existing modes. Homelab mode is infrastructure management; 3D printing is fabrication.

### Proposed mode: `3d-print`

**What it's for:**
- Natural language to 3D model generation
- Slicing with material-aware profiles
- Printer control (start, pause, stop, monitor)
- Print queue management
- Filament/AMS inventory

**What it's NOT for:**
- Network infrastructure (homelab)
- General development (platform-ops)

**Skills needed:**
- `model-generate` — OpenSCAD code gen + compile, Meshy fallback for organic shapes
- `model-search` — MakerWorld/Printables/Thingiverse search and download
- `slice-and-print` — OrcaSlicer CLI profile selection, slice, upload, start
- `print-monitor` — Status polling, camera snapshots, failure detection
- `filament-manager` — AMS slot inventory, material-to-profile mapping

**MCP servers:**
- `bambu-mcp` (schwarztim or custom) — printer control
- `openscad-mcp` — parametric CAD
- `meshy-mcp` (optional) — organic mesh generation

**Safety gates:**
- Print confirmation required before `start_print` (physical actuator)
- Temperature limit guard (thermal runaway awareness)
- Filament compatibility check (material vs profile vs printer)

---

## 8. Homelab Connection

**Keep separate from homelab mode.** Shared network, different concerns.

- Homelab = infrastructure (UniFi, Docker, NAS, services)
- 3d-print = fabrication (CAD, slicing, printer control)
- Connection point: both on home network, both need LAN access
- Possible shared infra: Obsidian vault for print logs, same network segment config
- If needed, 3d-print mode can reference homelab's network config for printer discovery

---

## 9. Implementation Roadmap (Revised)

### Phase 1: Prove the loop (days)
1. Install OpenSCAD on machine (`sudo apt install openscad`)
2. Install OpenSCAD MCP (quellant/openscad-mcp or fboldo)
3. Enable Developer Mode + LAN Only on A1
4. Test: NL description → Claude writes .scad → render PNG → iterate → export STL → open in Bambu Studio → slice → print
5. Verify Bambu Studio CLI launch: `bambu-studio /path/to/model.stl`

### Phase 2: Printer control + monitoring (1 week)
1. Install schwarztim/bambu-mcp, configure printer IP/serial/access code
2. Test: MQTT connect, printer status, AMS inventory, camera snapshot
3. Test: FTP upload of .3mf sliced in Bambu Studio
4. Test: start/pause/stop print commands

### Phase 3: Orchestration skill + mode (1-2 weeks)
1. Write `3d-print` orchestration skill chaining OpenSCAD MCP → Bambu Studio → bambu-mcp
2. Define `3d-print` mode in mode system (mode 13)
3. Add vision feedback loop (andreahaku pattern): multi-angle render → Claude inspects → auto-refine
4. Add printer.json with A1 specs (build volume, nozzle, material profiles)

### Phase 4: Reference image pipeline (stretch)
1. Test: operator provides reference photo → Claude interprets geometry → writes OpenSCAD
2. If organic shapes needed: evaluate Meshy MCP for image-to-3D
3. Prototype with operator's test project

---

## 10. Key Decisions Needed

1. **LAN-only vs cloud?** Recommend LAN-only. No cloud dependency, lower latency, works offline.
2. **BambuStudio vs OrcaSlicer?** DECIDED: Bambu Studio (already installed, operator reviews in GUI). OrcaSlicer not needed.
3. **Build custom MCP vs compose existing?** Start with existing (Phase 1-2), write orchestration skill (Phase 3).
4. **Meshy API key cost?** Defer until operator encounters organic shape need. Parametric OpenSCAD covers most functional parts.
5. **X.509 cert risk tolerance?** Community-extracted cert from Bambu Connect. Works now, may break on firmware update. See Security Review §11.2.

---

## 11. Security Review

### 11.1 Threat Model

**Physical safety:** This pipeline controls a device with a 300°C hotend and moving actuators. Malicious or buggy commands can cause fire, equipment damage, or injury.

**Attack surface:**
- MQTT commands to printer (LAN, TLS on port 8883)
- FTPS file upload (ports 990, 50000-50100)
- OpenSCAD code execution (Claude-generated .scad compiled locally)
- Community MCP servers (npm packages, Python packages)

### 11.2 Risk: X.509 Certificate Extraction

**What:** schwarztim/bambu-mcp and other projects use an X.509 certificate + private key extracted from the Bambu Connect desktop app to sign MQTT commands. Without this, newer firmware rejects print and movement commands.

**Risks:**
- **Legal:** Extracting keys from proprietary software may violate DMCA/EULA. Personal use on own printer is gray area. No commercial exploitation.
- **Stability:** Bambu Lab can revoke/rotate certificate in firmware update. Would break all community MCP servers simultaneously.
- **Security:** The extracted cert is published in open-source repos. Any attacker on the LAN with this cert can control any Bambu printer in Developer Mode.

**Mitigation:**
- Use LAN-only mode (no cloud exposure)
- Printer on isolated VLAN or at minimum behind home router NAT
- Accept cert breakage risk — fall back to Bambu Studio direct send if cert revoked
- Do NOT expose MQTT port to internet
- Monitor Bambu Lab firmware release notes for auth changes

### 11.3 Risk: Community MCP Server Supply Chain

**What:** All Bambu MCP servers are community npm/PyPI packages. Supply chain attack via compromised dependency could execute arbitrary code with printer access.

**Risks:**
- Malicious update to openscad-mcp or bambu-mcp npm package
- Typosquatting (multiple similar package names already exist in ecosystem)
- Abandoned package taken over

**Mitigation:**
- **Pin exact versions** in MCP config (no `latest` or `^` ranges)
- **Audit before install:** Read source, check contributors, review recent commits
- **Lock to known commit hash** for GitHub-sourced MCPs (npx with git URL + hash)
- **Sandbox:** MCP servers run as separate processes — cannot access Claude session state, but CAN access LAN network
- **Network segmentation:** If MCP server is compromised, limit blast radius to printer VLAN

### 11.4 Risk: OpenSCAD Code Execution

**What:** Claude generates .scad code, OpenSCAD compiles it. OpenSCAD is a declarative geometry language, not a general scripting language.

**Risk level: LOW.**
- OpenSCAD cannot execute shell commands, read arbitrary files, or access network
- Worst case: infinite loop or memory exhaustion from bad geometry (DoS, not RCE)
- Compile runs locally, not on printer

**Mitigation:**
- Set timeout on OpenSCAD compile (kill after 60s)
- Review .scad source before export if paranoid (Claude shows it in conversation)

### 11.5 Risk: MQTT Command Injection

**What:** If Claude is tricked into sending malicious MQTT payloads, could issue dangerous printer commands.

**Risks:**
- Heat bed/nozzle to unsafe temperature
- Move print head into bed at full speed
- Start print with no filament (nozzle clog risk)

**Mitigation:**
- **Operator confirmation gate:** ALL print/movement commands require explicit operator approval (skill-level, not just MCP permission prompt)
- **Temperature bounds:** Skill enforces max temp limits (A1: nozzle 300°C, bed 100°C) — reject commands exceeding
- **No unattended first prints:** Operator physically present for first prints with new setup
- bambu-mcp `stop_print` should be allowed without confirmation (emergency stop)

### 11.6 Risk: Credential Storage

**What:** Printer LAN access code, serial number, and optional Bambu Cloud credentials needed.

**Mitigation:**
- Store in `.env` file, NOT in repo
- `.env` in `.gitignore` (verify)
- LAN access code is low-sensitivity (attacker needs LAN access first)
- Never commit printer credentials to any repo
- If Bambu Cloud creds used: treat as high-sensitivity, consider secrets manager

### 11.7 Security Verdict

**Overall risk: MODERATE — acceptable with mitigations.**

Physical actuator control is the primary concern, addressed by operator confirmation gates. Supply chain risk is real but standard for npm/PyPI ecosystem — pin versions and audit. X.509 cert is a stability risk more than a security risk (LAN-only). OpenSCAD execution is inherently safe (declarative, no I/O).

**Required before deployment:**
1. Printer on isolated network segment or behind NAT (already true for home network)
2. Developer Mode + LAN Only enabled
3. Exact version pins for all MCP packages
4. Operator confirmation gate in orchestration skill for `start_print`
5. Temperature limit enforcement in skill
6. `.env` for credentials, `.gitignore` verified

---

## 12. Implementation Review

### 12.1 Dependency Assessment

| Dependency | Available? | Install method | Risk |
|------------|-----------|----------------|------|
| OpenSCAD | apt package | `sudo apt install openscad` | None — stable, in Ubuntu repos |
| Bambu Studio | Already installed | MediCat golden image | None — already on machine |
| OpenSCAD MCP | npm/pip | Pin to specific version | Low — declarative geometry only |
| bambu-mcp | npm | Pin to specific commit | Medium — network access to printer |
| Node.js | Likely installed | Check version | None |
| Python 3.10+ | Likely installed | Check version | None |

### 12.2 Integration Points

**OpenSCAD MCP ↔ Claude:** Clean interface. Claude writes .scad text, MCP compiles/renders/exports. No shared state beyond filesystem (STL output files).

**Bambu Studio ↔ Claude:** Loose coupling via CLI launch (`bambu-studio model.stl`). No programmatic API — Bambu Studio is operator's review tool, not Claude's. This is intentional: human-in-the-loop for print validation.

**bambu-mcp ↔ Printer:** MQTT over TLS. Connection state managed by MCP server. If connection drops, MCP server reconnects. Printer state cached from MQTT reports.

**Orchestration skill ↔ MCP servers:** Skill chains tool calls. No custom server code needed — skill is a `.md` file with workflow instructions.

### 12.3 Failure Modes

| Failure | Impact | Recovery |
|---------|--------|----------|
| OpenSCAD compile error | No STL output | Claude reads error, fixes .scad code |
| OpenSCAD timeout | Stuck render | Kill process, simplify geometry |
| Bambu Studio won't open STL | No review | Manual file open, check STL validity |
| MQTT disconnect | No printer control | bambu-mcp reconnects, or Bambu Studio direct |
| Print failure mid-job | Wasted filament | Camera detection → pause → operator decision |
| Firmware update breaks cert | No MQTT control | Fall back to Bambu Studio direct send |
| MCP server crash | Tool unavailable | Restart MCP, Claude retries |

### 12.4 What We Build vs What We Install

**Install (no code):**
- OpenSCAD (apt)
- OpenSCAD MCP (npm/pip, pinned)
- bambu-mcp (npm, pinned to commit)

**Configure (config files):**
- MCP server entries in Claude settings
- `.env` with printer credentials
- `printer.json` with A1 specs (build volume: 256×256×256mm, nozzle: 0.4mm)

**Build (our code):**
- Orchestration skill (`.claude/skills/3d-print/SKILL.md`) — workflow instructions
- Mode definition (`3d-print` mode) — tool scoping, safety gates
- Print profiles reference (material → temperature → speed mappings)

**Estimated effort:**
- Phase 1 (prove loop): 2-4 hours hands-on
- Phase 2 (printer MCP): 2-3 hours
- Phase 3 (skill + mode): 1-2 days
- Phase 4 (reference images): exploratory, unbounded

### 12.5 Implementation Verdict

**Feasibility: HIGH.** All critical components exist. No novel engineering required. Biggest unknowns:
1. Does `bambu-studio` CLI launch work on operator's Linux install? (Test in Phase 1)
2. Does schwarztim/bambu-mcp work with A1 specifically? (Listed as supported, verify in Phase 2)
3. How well does Claude generate OpenSCAD for complex geometries? (Iterate in Phase 1)

**Recommendation: Proceed with Phase 1.** Low cost, high signal. Prove the loop works end-to-end before investing in mode/skill infrastructure.

---

## Sources

- [nneves/openscad-part-design](https://github.com/nneves/openscad-part-design) — Design iteration skill with validation suite
- [andreahaku/openscad_claude_skill](https://github.com/andreahaku/openscad_claude_skill) — Vision feedback loop for iterative design
- [kalmehdar/claude-3d-printing](https://github.com/kalmehdar/claude-3d-printing) — Multi-colour OpenSCAD, mesh checks, Print Bench
- [jirihelmich/3dprint-starter](https://github.com/jirihelmich/3dprint-starter) — Starter project, Bambu X1C + OpenSCAD + Claude
- [yuvalcohenrappaport/claude-bambu-printer](https://github.com/yuvalcohenrappaport/claude-bambu-printer) — Claude Code skill, OpenSCAD + BambuStudio
- [heyixuan2/bambu-studio-ai](https://github.com/heyixuan2/bambu-studio-ai) — Universal agent skill, most complete pipeline
- [schwarztim/bambu-mcp](https://github.com/schwarztim/bambu-mcp) — MCP server, MQTT/FTPS/X.509, 25 tools
- [griches/bambu-mcp](https://github.com/griches/bambu-mcp) — MCP server, fleet management
- [DMontgomery40/bambu-printer-mcp](https://github.com/DMontgomery40/bambu-printer-mcp) — MCP server, STL + slicing + Blender
- [artemnovichkov/claude-code-bambu-lab](https://github.com/artemnovichkov/claude-code-bambu-lab) — Claude Code pane, live status
- [tyty-the-eyety/bambu-printer-skill](https://github.com/tyty-the-eyety/bambu-printer-skill) — A1 LAN monitor + watchdog
- [Bambu Lab 3D Print Automation (mcpmarket)](https://mcpmarket.com/tools/skills/bambu-lab-3d-print-automation) — dvcrn skill, BambuStudio CLI wrapper
- [Bambu Studio AI (claudemarketplaces)](https://claudemarketplaces.com/skills/heyixuan2/bambu-studio-ai/bambu-studio-ai) — Marketplace listing
- [Meshy MCP Server](https://github.com/meshy-dev/meshy-mcp-server) — Official text-to-3D MCP, 24 tools
- [Meshy AI Docs](https://docs.meshy.ai/api/ai) — API and MCP integration docs
- [quellant/openscad-mcp](https://github.com/quellant/openscad-mcp) — OpenSCAD MCP, FastMCP Python
- [jkoets/OpenSCAD-MCP](https://github.com/jkoets/OpenSCAD-MCP) — Minimal OpenSCAD MCP
- [claude-cad (PyPI)](https://pypi.org/project/claude-cad/) — CadQuery text-to-STEP/STL
- [CAD MCP Servers Compared (buildcad.ai)](https://buildcad.ai/guides/cad-mcp-servers) — FreeCAD, Fusion, Onshape, OpenSCAD, build123d
- [Can Claude Make 3D Models? (3daistudio)](https://www.3daistudio.com/3d-generator-ai-comparison-alternatives-guide/can-claude-make-3d-models) — Methods comparison
- [Create 3D with Claude (awesomeclaude)](https://awesomeclaude.ai/how-to/create-3d-with-claude) — Blender MCP, SketchUp, Fusion
- [Bambu Lab Wiki - Printer Network Ports](https://wiki.bambulab.com/en/general/printer-network-ports) — Official port documentation
- [schwarztim/bambu-mcp MQTT Protocol Docs](https://github.com/schwarztim/bambu-mcp/blob/main/docs/mqtt-protocol.md) — Reverse-engineered protocol reference
- [bambu-lab-cloud-api (PyPI)](https://pypi.org/project/bambu-lab-cloud-api/) — Python cloud API library
- [3D Printing AI Model Generators (3dprinting.com)](https://3dprinting.com/software-guides/ai-3d-model-generators/) — 2026 comparison
