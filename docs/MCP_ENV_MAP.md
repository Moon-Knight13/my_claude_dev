# MCP Server Environment Variable Map

How `.env` vars reach each MCP server. All servers launch through
`scripts/mcp-wrapper.sh`, which sources `scripts/lib/load-env.sh` before
exec. Derivations happen in `load-env.sh` — edit there to change mappings.

## Flow

```
.env  ──→  load-env.sh (parse + derive)  ──→  mcp-wrapper.sh  ──→  server process
                                                     ↑
                                          .mcp.json env block
                                          (static overrides, merged)
```

## Variable Map

### Range Services → outline-readonly, range-intel

| You set in `.env`    | load-env.sh derives     | MCP server reads       |
|----------------------|-------------------------|------------------------|
| `OUTLINE_HOST`       | `OUTLINE_URL`           |                        |
|                      | `OUTLINE_API_URL`       | outline-readonly       |
| `OUTLINE_TOKEN`      | `OUTLINE_API_KEY`       | outline-readonly       |
| `PROVIDENTIA_HOST`   | `PROVIDENTIA_URL`       | range-intel            |
| `PROVIDENTIA_TOKEN`  | *(passed through)*      | range-intel            |
| `RANGE_GIT_HOST`     | `GITLAB_URL`            | range-intel            |
| `GITLAB_TOKEN`       | *(passed through)*      | range-intel            |
| `GITLAB_PROJECT`     | *(passed through)*      | range-intel            |

### Tuoni C2 → tuoni-mcp

| You set in `.env`         | load-env.sh derives | MCP server reads |
|---------------------------|---------------------|------------------|
| `SPOKE_KALI_HOST`         | `TUONI_URL`         | tuoni-mcp        |
| `SPOKE_KALI_C2_WEB_PORT`  | *(used in derive)*  |                  |
| `TUONI_USERNAME`           | *(passed through)*  | tuoni-mcp        |
| `TUONI_PASSWORD`           | *(passed through)*  | tuoni-mcp        |

Static overrides in `.mcp.json`: `TUONI_VERIFY_TLS=false`,
`TUONI_MCP_PROFILES=agent-ops,access,discovery,authoring,administration`

### Ghidra / REA → rea-mcp

| You set in `.env`      | load-env.sh default                                      | MCP server reads |
|------------------------|----------------------------------------------------------|------------------|
| `GHIDRA_INSTALL_DIR`   | `/home/node/.local/share/ghidra/ghidra_12.1.4_PUBLIC`    | rea-mcp          |
| `JAVA_HOME`            | `/home/node/.local/share/ghidra/jdk-21.0.7+6`           | rea-mcp          |

### Local Model → local-ollama

| You set in `.env`        | load-env.sh derives | MCP server reads |
|--------------------------|---------------------|------------------|
| `LOCAL_MODEL_ENDPOINT`   | `OLLAMA_HOST`       | local-ollama     |
| `LOCAL_MODEL_MODEL`      | `OLLAMA_MODEL`      | local-ollama     |

### No env vars needed

These servers work standalone: **obsidian-mcp**, **hacktricks-mcp**,
**mitre-mcp**, **lolbins-mcp**.

## Debugging

Run `bash scripts/mcp-doctor.sh` to see resolved values and test connectivity.

### Common issues

| Symptom | Cause | Fix |
|---------|-------|-----|
| MCP server can't connect after `.env` edit | Docker env is stale | Restart Claude Code (wrapper re-reads `.env`) |
| `rea doctor` says registration missing | Checks wrong file (`.claude.json`) | Ignore — false positive. REA registered in `.mcp.json` |
| Server gets old var value | `.mcp.json` was generated before `.env` change | Re-run `bash scripts/setup-mcp-servers.sh` + restart Claude |
| All range MCP servers fail | `*_HOST` vars empty in `.env` | Set hostnames in `.env`, restart Claude |
