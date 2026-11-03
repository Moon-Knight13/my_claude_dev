---
name: lolbins
description: "Living-off-the-land technique lookup via lolbins-mcp. Use when operator needs LOLBin/LOLBas/LOLOL techniques, defense evasion, execution proxy, DLL hijack, or native binary abuse for red-team/purple ops."
---

# LOLBins Technique Lookup

Query the lolbins-mcp server for living-off-the-land techniques.
Use during red-team or purple operations when you need to execute
through native OS binaries to avoid detection.

## When to Use

- Need to execute code through a signed OS binary (defense evasion)
- Looking for DLL hijack opportunities on a target
- Finding native crypto/download/execution capabilities
- Building detection rules for purple scoring
- Mapping techniques to MITRE ATT&CK

## Core Workflow

### 1. Search by Intent

Start with what you need to accomplish:

- `search_techniques` — keyword search across all LOLBin databases
- `find_execution_proxy` — binaries that execute other code
- `find_defense_evasion` — techniques to bypass security controls
- `find_dll_hijack` — DLL sideloading opportunities
- `find_credential_access` — native credential dumping
- `find_persistence_paths` — persist via native mechanisms
- `find_lateral_movement` — move laterally with built-in tools
- `find_discovery` — enumerate without dropping tools

### 2. Analyze a Specific Binary

When you have a candidate binary:

- `lookup_binary` — full detail on a specific LOLBin
- `analyze_binary` — capabilities, detection, MITRE mapping
- `analyze_opsec_risk` — noise level, log artifacts, detection likelihood

### 3. Build Technique Chain

For multi-step operations:

- `discover_chains` — find sequences of LOLBins that achieve a goal
- `chain_obfuscation` — layer techniques to reduce detection signature
- `build_attack_plan` — structured plan using LOLBins for a target

### 4. Detection (Purple Mode)

When scoring detection:

- `generate_detection` — create detection rules for a technique
- `analyze_detection_effectiveness` — evaluate existing rules
- `find_detection_blind_spots` — gaps in current coverage
- `assess_detection_gaps` — systematic gap analysis

### 5. Map to ATT&CK

- `map_attck` — technique to ATT&CK mapping
- `identify_technique` — classify observed behavior

## OPSEC Integration

LOLBin techniques align with RT-TGT-002 (no offensive tools on target).
Native binaries are already present — no upload needed.

Always check:
1. `analyze_opsec_risk` before using a technique
2. What logs the technique generates
3. Whether the binary is monitored by EDR on the target
4. Alternative binaries that achieve the same goal with less noise

## Platform Awareness

- `compare_platforms` — same technique across Windows/Linux/macOS
- `compare_os_versions` — technique availability across OS versions
