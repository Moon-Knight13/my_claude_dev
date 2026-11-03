---
name: reverse-engineering
description: "Binary analysis and reverse engineering workflow using rea-mcp. Use when operator says 'reverse engineer', 'RE', 'analyze binary', 'decompile', 'disassemble', or 'patch diff'."
---

# Reverse Engineering — Binary Analysis Workflow

## When to use

Binary analysis, vulnerability research, exploit development, patch diffing.
Wraps rea-mcp tools into an operator workflow.

Active in: **red-dev** mode.

## Entry criteria

- [ ] rea-mcp server running (check MCP server list)
- [ ] Target binary accessible (local path or pulled from target)
- [ ] Operator has stated analysis goal (vuln hunt, patch diff, protocol RE, etc.)

## Procedure

### Step 1: Open and Survey

Open the binary and get a high-level overview:

1. `open_binary` — load the target file. Note the returned session handle.
2. `binary_overview` — architecture, format (ELF/PE/Mach-O), sections, entry point, compiler info.
3. `list_segments` — memory layout, permissions (RWX), section sizes.

Record: architecture, format, compiler, interesting segments.

### Step 2: Orient — Strings and Exports

Find attack surface and interesting functionality:

1. `list_strings` — filter for URLs, paths, passwords, error messages, format strings, crypto constants.
2. `inspect_native_exports` — public API surface, named entry points.
3. `list_procedures` — function count, named vs unnamed ratio.
4. `search_procedures` — search by name pattern for functions of interest (e.g. "auth", "parse", "decrypt", "login").

Prioritize functions that handle: user input, authentication, crypto, network parsing, file I/O.

### Step 3: Decompile Target Functions

For each function of interest:

1. `procedure_info` — size, calling convention, local vars.
2. `procedure_pseudo_code` — decompiled C-like output. Read for logic, not syntax.
3. `procedure_callees` — what does it call? Follow the data flow.
4. `procedure_callers` — who calls it? Understand reachability from entry points.
5. `procedure_assembly` — raw disassembly when decompilation misses detail (switch tables, inline asm, SIMD).

### Step 4: Trace Data Flow

Follow interesting values through the binary:

1. `xrefs` — cross-references to/from an address.
2. `find_xrefs_to_name` — all references to a named symbol (function, global, import).
3. `trace_call_path` — find call chain from entry point to target function.
4. `get_call_graph` — visualize call relationships around a function.

For vulnerability research: trace user-controlled input from entry point through parsing to sink (memcpy, sprintf, SQL, command exec).

### Step 5: Search for Patterns

When looking for specific vulnerability classes:

1. `search_bytes` — find byte patterns (magic numbers, opcodes, hardcoded keys).
2. `search_strings` — regex search across all string references.
3. `search_procedures` — find functions matching name or signature patterns.
4. `inspect_native_instruction` — examine specific instruction encoding.

Common patterns:
- Unsafe functions: `strcpy`, `sprintf`, `gets`, `system`, `exec`
- Format strings: `%s`, `%n` near user input paths
- Integer handling: `malloc` calls near arithmetic on user-controlled sizes
- Crypto: hardcoded keys, weak algorithm constants (DES, RC4, MD5)

### Step 6: Patch Diffing (when comparing versions)

Compare two versions of a binary to find patched vulnerabilities:

1. Open both binaries (two `open_binary` calls).
2. `compare_functions` — find functions that changed between versions.
3. For each changed function: decompile both versions, diff the pseudocode.
4. `compare_artifacts` — broader structural comparison.

Focus on: new bounds checks, added validation, changed branch conditions,
removed functionality. These are where the vulnerability was.

### Step 7: Annotate and Document

As analysis progresses, annotate the binary:

1. `set_address_name` — rename discovered functions and globals.
2. `set_comment` / `set_inline_comment` — add analysis notes at key addresses.
3. `set_bookmark` — mark important locations for quick navigation.

### Step 8: Close and Export

When analysis is complete:

1. `export_evidence_bundle` — save analysis state for later reference.
2. `close_binary` — release the session. Always close when done.

## Output

Every completed analysis produces (in Obsidian or engagement docs):
- **Analysis summary** — binary ID, architecture, purpose, attack surface
- **Findings** — vulnerabilities or interesting behaviors discovered
- **Call chains** — path from entry to vulnerability
- **IoC indicators** — strings, byte patterns, behavioral signatures
- **Remediation** (if applicable) — what the fix should look like

## Tips

- Start broad (overview, strings, exports), narrow to specific functions.
- Decompilation is approximation. When logic is unclear, read assembly.
- Name everything as you go. Unnamed functions multiply confusion.
- For large binaries: use `search_procedures` and string xrefs to skip to interesting code instead of reading linearly.
- Close binaries when switching targets. Open sessions consume resources.
