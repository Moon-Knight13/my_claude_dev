---
name: 3d-print
description: "Orchestrates the full 3D printing pipeline: NL description to OpenSCAD code, PNG preview, design iteration, STL export, Bambu Studio slicing, and print preparation. Use when operator says 'print', 'design', 'model', '3d', 'openscad', 'scad', 'stl', 'slice', or describes a physical object to fabricate."
modes: [3d-print]
---

# 3D Print Orchestration

Full pipeline from natural language description to print-ready file.
Operator controls every gate. Claude never sends to printer.

## Pipeline Overview

```
1. Understand request (NL + optional reference images)
2. Write OpenSCAD .scad code
3. Render PNG preview (multi-angle)
4. Vision-inspect + operator feedback loop
5. Export STL
6. Slice with Bambu Studio
7. Operator reviews slice preview
8. Operator sends to printer
```

## Output Directory

All generated files go in `output/` relative to working directory.
Create it if missing. Name files descriptively: `bracket-v1.scad`,
`bracket-v1-front.png`, `bracket-v1.stl`.

## Step 1: Understand the Request

Gather from operator:
- **What** the object is and its purpose
- **Dimensions** (critical measurements, tolerances)
- **Material** constraints (PLA default; PETG for heat/strength; TPU for flex)
- **Reference images** if provided (Claude vision-inspects these)
- **Mounting/mating** requirements (screw holes, snap fits, clearances)

If operator provides reference images, vision-inspect them and describe
the geometry you observe before writing any code. Call out:
- Overall shape and proportions
- Key features (holes, slots, curves, chamfers)
- Estimated dimensions if scale reference visible

## Step 2: Write OpenSCAD Code

Write parametric .scad code with named variables at top for all
key dimensions. This makes iteration fast — operator says "make it wider",
you change one variable.

Design principles for printability:
- Minimum wall thickness: 1.2 mm (3 perimeters at 0.4 mm nozzle)
- Minimum hole diameter: 2 mm
- Overhang angle: max 45° without supports
- Bridge span: max 10 mm without supports
- Chamfer/fillet bottom edges touching build plate (elephant foot)
- Orient for strength: layer lines perpendicular to load direction

Save to `output/<name>.scad`.

## Step 3: Render PNG Preview

Render from multiple angles for visual verification:

```bash
# Front view (default camera)
openscad -o output/<name>-front.png --camera=0,0,0,55,0,25,200 --imgsize=800,600 output/<name>.scad

# Top view
openscad -o output/<name>-top.png --camera=0,0,0,0,0,0,200 --imgsize=800,600 output/<name>.scad

# Isometric view
openscad -o output/<name>-iso.png --camera=0,0,0,55,0,315,200 --imgsize=800,600 output/<name>.scad
```

Camera format: `--camera=tx,ty,tz,rx,ry,rz,dist`
- tx,ty,tz: translation (center of view)
- rx,ry,rz: rotation in degrees
- dist: distance from center

Adjust `dist` based on object size. Larger objects need larger distance.

Set a 60-second timeout on each render. If render hangs, geometry may
have infinite recursion — simplify and retry.

## Step 4: Vision-Inspect and Iterate

After rendering, vision-inspect the PNG previews. Check:
- Does geometry match the request?
- Are proportions correct?
- Are there obvious printability issues (thin walls, unsupported overhangs)?
- Do features align with reference images (if provided)?

Present previews to operator with observations. Ask for feedback.
Common iteration patterns:
- "Make X wider/taller/thicker" → adjust parameter variable
- "Add chamfer/fillet" → add `minkowski()` or manual chamfer
- "Round this edge" → add `fillet()` or sphere-based minkowski
- "Add screw hole at position" → `translate([x,y,z]) cylinder(d=d, h=h)`

Re-render after each change. Repeat until operator approves.

If operator provides a reference image alongside the render, compare
them side-by-side in vision and describe discrepancies.

## Step 5: Export STL

Once operator approves the design:

```bash
openscad -o output/<name>.stl output/<name>.scad
```

Verify export succeeded (file exists, non-zero size).
Report file size — unusually large STL (>50 MB) may indicate
excessive `$fn` values. Reduce `$fn` if needed.

## Step 6: Slice with Bambu Studio

Open STL in Bambu Studio for operator review and slicing:

```bash
flatpak run com.bambulab.BambuStudio output/<name>.stl &
```

If CLI slicing is available (3MF project file exists):

```bash
flatpak run com.bambulab.BambuStudio --slice output/<name>.3mf
```

Inform operator:
- Recommended material based on requirements gathered in Step 1
- Suggested layer height (0.2 mm standard, 0.12 mm detail, 0.28 mm draft)
- Whether supports are likely needed (based on geometry analysis)
- Estimated print orientation for strength

## Step 7: Operator Reviews and Prints

**SAFETY GATE: Claude NEVER sends files to the printer or starts prints.**

Operator responsibilities at this stage:
1. Review model in Bambu Studio 3D view
2. Check plate fit (256 × 256 mm build area)
3. Configure supports, infill, layer height
4. Slice and review layer simulation
5. Send to printer when satisfied

If operator reports issues after review, return to Step 4 for iteration.

## When bambu-mcp Is Available

If bambu-mcp MCP server is configured, Claude can:
- Query printer status (`printer_status`)
- Check AMS filament inventory (`ams_status`)
- Take camera snapshots during print (`camera_snapshot`)
- Report print progress

Claude CANNOT (without explicit operator command):
- Start, pause, or resume prints
- Upload files to printer
- Change printer settings

Exception: `stop_print` is allowed without confirmation (emergency stop).

## OpenSCAD Tips for Claude

Common patterns that produce good prints:

```openscad
// Rounded box
module rounded_box(size, radius) {
    minkowski() {
        cube([size.x - 2*radius, size.y - 2*radius, size.z - radius]);
        cylinder(r=radius, h=radius, $fn=32);
    }
}

// Screw hole with countersink
module screw_hole(d=3.2, head_d=6, depth=10) {
    cylinder(d=d, h=depth, $fn=24);
    translate([0, 0, depth - head_d/2])
        cylinder(d1=d, d2=head_d, h=head_d/2, $fn=24);
}

// Chamfered bottom edge (anti-elephant-foot)
module chamfer_base(size, chamfer=0.4) {
    hull() {
        translate([chamfer, chamfer, 0])
            cube([size.x - 2*chamfer, size.y - 2*chamfer, chamfer]);
        translate([0, 0, chamfer])
            cube([size.x, size.y, size.z - chamfer]);
    }
}
```

Use `$fn` judiciously:
- Screw holes: `$fn=24`
- Decorative curves: `$fn=48`
- Large smooth surfaces: `$fn=64`
- Never use `$fn` > 128 (slow render, huge STL, no visible improvement)

## Error Recovery

| Error | Fix |
|-------|-----|
| OpenSCAD syntax error | Read error message, fix .scad code, re-render |
| Render timeout (>60s) | Reduce `$fn`, simplify geometry, split into modules |
| STL export 0 bytes | Check for unclosed geometry, manifold errors |
| Bambu Studio won't open | Check flatpak install, try `flatpak run com.bambulab.BambuStudio` with no args first |
| STL too large (>50 MB) | Reduce `$fn`, simplify curves, check for redundant geometry |
