## Active Mode: 3d-print

AI-assisted 3D model generation, preview, slicing, and print preparation.
No engagement active. No offensive tools loaded. No OPSEC rules apply.

### What this mode is for
- Natural language to 3D model generation (OpenSCAD parametric code)
- Multi-angle PNG preview rendering and visual iteration
- Reference image interpretation for geometry extraction
- STL export and mesh validation
- Slicing with Bambu Studio (operator-driven review checkpoint)
- Print preparation and filament/material selection
- Printer status monitoring (when bambu-mcp available)

### What this mode is NOT for
- Any offensive operation (use red-team)
- Network infrastructure management (use homelab)
- Framework/harness development (use platform-ops)
- Range infrastructure deployment (use green-dev)

### Safety gates
- **NEVER auto-send to printer.** All print commands require explicit operator confirmation.
- OpenSCAD code generation is non-destructive (declarative geometry, no I/O).
- Bambu Studio is the operator's review tool — Claude opens files in it, operator controls slicing and print dispatch.
- Temperature and movement commands (when bambu-mcp available) require operator approval.
- Emergency stop (`stop_print`) is the only command allowed without confirmation.

### Available tools
- OpenSCAD CLI (`openscad`) for rendering and STL export
- Bambu Studio CLI (`flatpak run com.bambulab.BambuStudio`) for slicing and review
- All standard development tools (git, bash, file system)
- bambu-mcp (when configured) for printer MQTT control
- openscad-mcp (when configured) for programmatic render/export

### Design iteration pipeline
```
Operator describes object + optional reference images
  → Claude writes parametric .scad code
  → OpenSCAD renders PNG preview (multi-angle)
  → Claude vision-inspects render
  → Operator feedback ("wider base", "add chamfer")
  → Loop until satisfied
  → Export STL → Open in Bambu Studio → Operator slices and prints
```

### Printer specs (Bambu Lab A1)
- Build volume: 256 × 256 × 256 mm
- Nozzle: 0.4 mm default
- Materials: PLA, PETG, TPU, PLA-CF (AMS dependent)
- Network: LAN mode preferred (MQTT on port 8883)

### Readiness check
On session start, verify:
1. `openscad --version` responds
2. `flatpak run com.bambulab.BambuStudio --help` responds (or note if unavailable)
3. Working directory has write access for .scad/.stl/.png output
