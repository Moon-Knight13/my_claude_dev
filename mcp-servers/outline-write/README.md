# outline-write-mcp

Collection-scoped write MCP server for the Outline wiki. Creates and updates
documents only in explicitly allowed collections, with authorship guards and
audit logging.

## Environment Variables

| Variable | Required | Description |
|---|---|---|
| `OUTLINE_API_URL` | Yes | Outline instance URL (e.g. `https://wiki.example.com`) |
| `OUTLINE_API_KEY` | Yes | Outline API token with read+write scope |
| `OUTLINE_WRITE_COLLECTIONS` | Yes | Comma-separated collection names or UUIDs to allow writes |
| `OUTLINE_WRITE_ENV` | No | Path to alternate `.env` file |

## Tools

| Tool | Description |
|---|---|
| `outline_write_list_collections` | List collections this server can write to |
| `outline_write_create_document` | Create a new document in an allowed collection |
| `outline_write_update_document` | Replace content of a document you authored |
| `outline_write_append_to_document` | Append content to a document you authored |
| `outline_write_document_info` | Get document metadata (authorship, collection, timestamps) |

All write tools accept `dry_run` (default: `True`). Set `dry_run=False` to
execute the write.

## Safety Model

- **Collection allowlist**: writes only reach collections named in
  `OUTLINE_WRITE_COLLECTIONS`. Server refuses to start if none resolve.
- **Authorship guard**: update and append operations verify the document was
  created by the API token's user. Modifying others' documents is rejected.
- **No destructive operations**: delete, move, and archive are not exposed.
- **Dry-run default**: all write tools default to `dry_run=True`, returning a
  preview without executing. Explicit `dry_run=False` required for real writes.
- **Audit log**: every mutation (and dry-run) emits a structured JSON line to
  stderr with timestamp, operation, document ID, and collection ID.

## Known Limitations

- **Last-writer-wins**: Outline's API does not provide optimistic locking. If
  another user edits a document between the authorship check and the update
  call, the update still succeeds. The authorship guard is a check on intent,
  not a lock.
- **API token scope**: Outline API tokens are instance-wide. The collection
  allowlist is enforced at the MCP server level, not by the Outline API itself.
- **No search tool**: use the companion `outline-readonly` MCP for search and
  read operations. This server is write-only by design.

## Running

```bash
cd mcp-servers/outline-write
python3 -m venv .venv
.venv/bin/pip install -e .
OUTLINE_API_URL=https://wiki.example.com \
OUTLINE_API_KEY=your-token \
OUTLINE_WRITE_COLLECTIONS="vulns-docs" \
.venv/bin/outline-write-mcp
```

## Testing

```bash
.venv/bin/pip install -e ".[dev]"
.venv/bin/pytest tests/ -v
```

All tests mock the Outline API. No live API calls are made during testing.
