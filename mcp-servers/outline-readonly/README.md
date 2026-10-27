# outline-readonly MCP

Read-only MCP server for [Outline](https://www.getoutline.com/) wiki.
Strict guard rails — no create, update, delete, move or archive operations.

## Tools

| Tool | Purpose |
|------|---------|
| `outline_list_collections` | List accessible collections |
| `outline_collection_structure` | Document tree of a collection |
| `outline_list_documents` | List docs in a collection/folder |
| `outline_read_document` | Read full document content |
| `outline_search` | Full-text search across docs |

## Setup

Zero dependencies — requires only Node.js 18+ (uses built-in `fetch` and `readline`).
No `npm install` needed.

### Register with Claude Code

```bash
claude mcp add outline-readonly -s user -t stdio \
  -e OUTLINE_API_URL=https://your-outline-instance.com \
  -e OUTLINE_API_KEY=ol_api_xxx \
  -- node /path/to/mcp-servers/outline-readonly/src/server.js
```

### Collection scoping

Restrict access to specific collections by name or UUID:

```bash
claude mcp add outline-readonly -s user -t stdio \
  -e OUTLINE_API_URL=https://your-outline-instance.com \
  -e OUTLINE_API_KEY=ol_api_xxx \
  -e OUTLINE_COLLECTIONS="Docs,Engineering" \
  -- node /path/to/mcp-servers/outline-readonly/src/server.js
```

## Environment variables

| Variable | Required | Description |
|----------|----------|-------------|
| `OUTLINE_API_URL` | yes | Outline instance URL |
| `OUTLINE_API_KEY` | yes | API key |
| `OUTLINE_COLLECTIONS` | no | Comma-separated allowlist of collection names or UUIDs |
