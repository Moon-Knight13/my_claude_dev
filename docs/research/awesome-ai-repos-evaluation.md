# External Repo Evaluation for Harness Improvement

**Date:** 2026-11-06
**Mode:** platform-ops
**Scope:** 20 repos from awesome-database-top AI list, evaluated against my_claude_dev hub-spoke harness

---

## Top 5 Recommendations

| Rank | Repo | Relevance | Action |
|------|------|-----------|--------|
| 1 | **NVIDIA/SkillSpector** | HIGH | Add as pre-install security gate for skills and MCP servers |
| 2 | **bethington/ghidra-mcp** | HIGH | Add as red-dev spoke alongside rea-mcp |
| 3 | **akitaonrails/ai-memory** | MEDIUM-HIGH | Evaluate as memory upgrade (git-backed, MCP-native, cross-agent) |
| 4 | **lightpanda-io/browser** | MEDIUM-HIGH | Evaluate as lightweight MCP headless browser (verify AGPL license first) |
| 5 | **NVIDIA/OpenShell** | MEDIUM | Monitor for red-team mode sandboxing |

### Detailed Recommendations

**1. NVIDIA/SkillSpector (~24.6k stars, Nov 2026)**
Security scanner for AI agent skills. 71 vulnerability patterns across 17 categories. Static analysis + optional LLM review. SARIF output.
- **Why:** Direct fit for security-first priority. Scan third-party skills and MCPs before installation. Run against our 60+ existing skills as audit.
- **Integration path:** Add `skill-inspector` skill to platform-ops. Wire SARIF output into CI. Gate new skill/MCP adoption on clean scan.
- **License:** Apache-2.0. **Risk:** Low.

**2. bethington/ghidra-mcp (~6.1k stars, active 2026)**
Ghidra MCP server with 200-270+ tools, headless Docker mode, batch operations, cross-binary doc propagation.
- **Why:** Complements rea-mcp. rea-mcp handles runtime + multi-format; ghidra-mcp provides deep Ghidra-native static analysis and batch ops.
- **Integration path:** Add as red-dev mode MCP spoke. Headless Docker fits container architecture. Coexists with rea-mcp.
- **License:** Apache-2.0. **Risk:** Moderate — single maintainer, review plugin code before deployment.

**3. akitaonrails/ai-memory (~15k stars, active 2026)**
Rust-based long-term memory. Git-backed markdown. MCP server with 23 tools. Cross-agent handoff (Claude Code, Codex, Cursor, Gemini CLI).
- **Why:** Git-backed markdown aligns with our approach. Cross-agent handoff relevant for model failover strategy. MCP interface = no hook chain changes. Rust = fast, no Python/Node dependency.
- **Integration path:** Evaluate as optional MCP spoke. Test alongside current auto-memory. May enable cross-model context persistence.
- **License:** MIT. **Risk:** Low. Recommends disabling Claude Code auto-memory — evaluate if augment-only mode possible.

**4. lightpanda-io/browser (~30k stars, active 2026)**
Headless browser in Zig. Native MCP + CDP support. Built-in agent mode. ~9x faster, 16x less memory than Chrome. Markdown output.
- **Why:** MCP-native drop-in spoke. Agent mode for autonomous web recon. Lightweight for container/spoke environments.
- **Integration path:** Add as recon/research spoke. Test MCP mode compatibility. No screenshot support (no renderer).
- **License:** AGPL-3.0 (VERIFY — conflicting reports). **Risk:** Medium — AGPL copyleft obligations require legal review before integration.

**5. NVIDIA/OpenShell (~21k stars, Oct 2026)**
Sandboxed agent runtime. Container isolation per agent. Network policy enforcement. Credential isolation.
- **Why:** Could sandbox red-team/purple mode operations. Defense-in-depth beyond hook chain.
- **Integration path:** Monitor maturity (v0.1.x). Evaluate wrapping Claude Code execution for operational modes.
- **License:** Open source, NVIDIA-backed. **Risk:** Low. Anonymous telemetry on by default (can disable). Still early.

---

## Full Evaluation by Category

### MCP Servers / Tools

| Repo | Stars | Last Active | Relevance | Summary |
|------|-------|-------------|-----------|---------|
| punkpeye/awesome-mcp-servers | ~97k | Nov 2026 | Medium | Curated MCP catalog (~55 categories). Discovery tool, not software. Periodic scan for security/RE MCPs we lack. |
| bethington/ghidra-mcp | ~6.1k | 2026 | **High** | 200-270+ Ghidra tools, headless Docker, batch ops. Complements rea-mcp for red-dev. |
| modelcontextprotocol/servers | ~92k | Nov 2026 | Low | Official Anthropic reference servers. Most archived. Sequential Thinking server worth noting. |
| ChromeDevTools/chrome-devtools-mcp | ~54.8k | Nov 2026 | Medium | Official Chrome DevTools MCP. Heap analysis, CSS inspection. Potential for purple mode web testing. Overlap with T3 preview tools needs evaluation. |
| docker/docker-agent | ~4.7k | Nov 2026 | Low | Declarative agent builder. MCP-as-tool feature interesting but adds orchestration complexity we don't need. |

### Agent Memory / State

| Repo | Stars | Last Active | Relevance | Summary |
|------|-------|-------------|-----------|---------|
| rohitg00/agentmemory | ~22k | 2026 | Medium | Local memory server on `iii` engine. 51 MCP tools, hybrid retrieval (BM25 + vector + graph). Heavy dependency. Watch for large memory corpus scaling. |
| akitaonrails/ai-memory | ~15k | 2026 | **Medium-High** | Git-backed markdown, Rust, MCP native, cross-agent handoff. Best memory candidate. |
| TencentCloud/TencentDB-Agent-Memory | ~20k | 2026 | Low | Layered memory (L0-L3) concept interesting. No MCP. Tencent Cloud tie-in. Borrow design pattern only. |

### Skills / Harness Patterns

| Repo | Stars | Last Active | Relevance | Summary |
|------|-------|-------------|-----------|---------|
| anthropics/skills | ~188k | Oct 2026 | High | Official Anthropic skills upstream. Track for new skills. Already consumed as built-in. |
| obra/superpowers | ~310k | Nov 2026 | High | Already integrated. Verify on v7.0.x. Check superpowers-lab for experimental skills. |
| NVIDIA/SkillSpector | ~24.6k | Nov 2026 | **High** | Security scanner for skills. 71 vuln patterns. Direct fit for security gate. |
| NVIDIA/OpenShell | ~21k | Oct 2026 | Medium | Sandboxed agent runtime. Monitor for red-team mode isolation. |
| HKUDS/OpenHarness | ~16.2k | Aug 2026 | Low | Similar architecture to ours. Study hook/permission patterns. No integration path. |
| deepseek-ai/deepseek-harness | ~274k | Nov 2026 | None | DeepSeek-specific. Different ecosystem. |
| xingkongliang/skills-manager | ~7.3k | Jun 2026 | Low | Desktop GUI for skill management. We're CLI-first. |

### Agent Orchestration

| Repo | Stars | Last Active | Relevance | Summary |
|------|-------|-------------|-----------|---------|
| langchain-ai/deepagents | ~24k | Jun 2026 | Medium | LangGraph agent harness. Middleware layering pattern worth studying. We already do most of what it offers. |
| microsoft/autogen | ~50k+ | Mar 2026 | Low | Multi-agent conversation framework. **Maintenance mode.** Split 3 ways. Conversation-centric model doesn't fit our operator-controlled architecture. |
| NirDiamant/agents-towards-production | ~17.5k | 2026 | Medium | Tutorial collection (25-33 patterns). Dual-memory + semantic search tutorial relevant. Security/observability patterns worth reading. |

### Security / RE

| Repo | Stars | Last Active | Relevance | Summary |
|------|-------|-------------|-----------|---------|
| unclecode/crawl4ai | ~68k+ | 2026 | Medium | Async web crawler, MCP native, structured extraction. Potential recon spoke for bulk web intelligence. |
| lightpanda-io/browser | ~30k+ | 2026 | **Medium-High** | Zig headless browser, MCP + CDP native, agent mode. Lightweight. AGPL license needs verification. |

---

## Patterns Worth Borrowing (No Integration)

These aren't repos to install, but design patterns worth studying:

1. **Layered memory abstraction (L0-L3)** from TencentDB-Agent-Memory — raw conversations to atomic facts to scenario blocks to profiles. Useful if our memory corpus grows.
2. **Middleware composition** from langchain-ai/deepagents — PlanningMiddleware, FilesystemMiddleware, SubAgentMiddleware. Could inform composable hook stages.
3. **Dual-memory + semantic search** from agents-towards-production tutorials — Redis-backed semantic retrieval pattern for memory scaling.

---

## Supply Chain Risk Summary

| Risk Level | Repos |
|------------|-------|
| **Low** | anthropics/skills, obra/superpowers, NVIDIA/SkillSpector, modelcontextprotocol/servers, crawl4ai, ai-memory |
| **Medium** | bethington/ghidra-mcp (single maintainer), lightpanda-io/browser (AGPL), TencentDB-Agent-Memory (vendor tie-in) |
| **High** | None evaluated |

---

## Next Steps

1. **Immediate:** Run SkillSpector against our 60+ skills as security audit
2. **Short-term:** Evaluate ghidra-mcp in red-dev mode alongside rea-mcp
3. **Short-term:** Test ai-memory MCP alongside current auto-memory
4. **Medium-term:** Verify lightpanda license; if acceptable, test as recon spoke
5. **Monitor:** OpenShell maturity for red-team sandboxing
6. **Periodic:** Scan awesome-mcp-servers catalog for new security/RE MCPs
7. **Upstream:** Ensure superpowers is on v7.0.x; track anthropics/skills for new additions
