"""MCP server entry point for outline-write."""

from __future__ import annotations

import json
import logging
import os
import sys
from typing import Any

try:
    from mcp.server.mcpserver import MCPServer as FastMCP
except ImportError:
    from mcp.server import FastMCP

from outline_write.client import OutlineClient
from outline_write.guards import CollectionGuard, audit_log, check_authorship

logger = logging.getLogger("outline_write")

_client: OutlineClient | Any | None = None
_guard: CollectionGuard | None = None
_user_id: str = ""

mcp = FastMCP(
    "outline-write-mcp",
    instructions=(
        "Collection-scoped write server for Outline wiki. "
        "Creates and updates documents only in allowed collections. "
        "Authorship guard prevents modifying others' documents. "
        "dry_run=True (default) previews without writing. "
        "Set dry_run=False to execute writes."
    ),
)


def _load_env(path: str) -> dict[str, str]:
    env: dict[str, str] = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, val = line.partition("=")
                key = key.strip()
                val = val.strip().strip("\"'")
                if val:
                    env[key] = val
    except FileNotFoundError:
        pass
    return env


async def _init_clients() -> None:
    global _client, _guard, _user_id

    env_path = os.path.join(os.path.dirname(__file__), "..", "..", ".env")
    env_path = os.path.normpath(env_path)
    file_env = _load_env(env_path)

    alt_path = os.environ.get("OUTLINE_WRITE_ENV")
    if alt_path:
        file_env.update(_load_env(alt_path))

    for key, val in file_env.items():
        if key not in os.environ:
            os.environ[key] = val

    api_url = os.environ.get("OUTLINE_API_URL", "")
    api_key = os.environ.get("OUTLINE_API_KEY", "")
    collections_raw = os.environ.get("OUTLINE_WRITE_COLLECTIONS", "")

    if not api_url or not api_key:
        logger.error("Required: OUTLINE_API_URL and OUTLINE_API_KEY")
        sys.exit(1)

    if not collections_raw:
        logger.error("Required: OUTLINE_WRITE_COLLECTIONS (comma-separated collection names)")
        sys.exit(1)

    allowed_names = [s.strip() for s in collections_raw.split(",") if s.strip()]

    _client = OutlineClient(api_url, api_key)
    _guard = CollectionGuard(allowed_names, _client)
    await _guard.resolve()

    user = await _client.get_current_user()
    _user_id = user["id"]
    logger.info(
        "outline-write-mcp: user=%s, collections=%s",
        _user_id,
        list(_guard.allowed_names_map.values()),
    )


def _error_response(message: str) -> str:
    return json.dumps({"error": True, "message": message})


async def _handle_list_collections() -> str:
    assert _guard is not None
    collections = [
        {"id": cid, "name": name}
        for cid, name in _guard.allowed_names_map.items()
    ]
    return json.dumps({"collections": collections}, indent=2)


async def _handle_create_document(
    collection_id: str,
    title: str,
    text: str,
    parent_document_id: str = "",
    publish: bool = True,
    dry_run: bool = True,
) -> str:
    assert _guard is not None and _client is not None
    try:
        _guard.enforce(collection_id)
    except ValueError as exc:
        return _error_response(str(exc))

    if dry_run:
        audit_log("create_document_dry_run", collection_id=collection_id, title=title)
        return json.dumps({
            "dry_run": True,
            "operation": "create_document",
            "collection_id": collection_id,
            "title": title,
            "text_preview": text[:200],
            "publish": publish,
        }, indent=2)

    try:
        doc = await _client.create_document(
            collection_id=collection_id,
            title=title,
            text=text,
            parent_document_id=parent_document_id or None,
            publish=publish,
        )
    except Exception as exc:
        return _error_response(str(exc))

    audit_log(
        "create_document",
        document_id=doc["id"],
        collection_id=collection_id,
        title=title,
    )
    return json.dumps(doc, indent=2)


async def _handle_update_document(
    document_id: str,
    title: str = "",
    text: str = "",
    dry_run: bool = True,
) -> str:
    assert _client is not None and _guard is not None
    try:
        is_mine = await check_authorship(_client, document_id, _user_id)
    except Exception as exc:
        return _error_response(str(exc))

    if not is_mine:
        return _error_response(
            f"Document {document_id} not authored by you. "
            "Only documents you created can be updated."
        )

    if dry_run:
        audit_log("update_document_dry_run", document_id=document_id)
        return json.dumps({
            "dry_run": True,
            "operation": "update_document",
            "document_id": document_id,
            "title": title or "(unchanged)",
            "text_preview": (text[:200] if text else "(unchanged)"),
        }, indent=2)

    try:
        doc = await _client.update_document(
            id=document_id,
            title=title or None,
            text=text or None,
        )
    except Exception as exc:
        return _error_response(str(exc))

    audit_log("update_document", document_id=document_id)
    return json.dumps(doc, indent=2)


async def _handle_append_to_document(
    document_id: str,
    content: str,
    dry_run: bool = True,
) -> str:
    assert _client is not None
    try:
        is_mine = await check_authorship(_client, document_id, _user_id)
    except Exception as exc:
        return _error_response(str(exc))

    if not is_mine:
        return _error_response(
            f"Document {document_id} not authored by you. "
            "Only documents you created can be appended to."
        )

    if dry_run:
        audit_log("append_to_document_dry_run", document_id=document_id)
        return json.dumps({
            "dry_run": True,
            "operation": "append_to_document",
            "document_id": document_id,
            "content_preview": content[:200],
        }, indent=2)

    try:
        doc = await _client.update_document(
            id=document_id,
            text=content,
            append=True,
        )
    except Exception as exc:
        return _error_response(str(exc))

    audit_log("append_to_document", document_id=document_id)
    return json.dumps(doc, indent=2)


async def _handle_document_info(document_id: str) -> str:
    assert _client is not None
    try:
        doc = await _client.get_document(document_id)
    except Exception as exc:
        return _error_response(str(exc))

    return json.dumps({
        "id": doc["id"],
        "title": doc["title"],
        "collection_id": doc["collectionId"],
        "created_by": doc["createdBy"]["id"],
        "created_by_name": doc["createdBy"].get("name", ""),
        "created_at": doc.get("createdAt", ""),
        "updated_at": doc.get("updatedAt", ""),
        "owned_by_me": doc["createdBy"]["id"] == _user_id,
    }, indent=2)


@mcp.tool()
async def outline_write_list_collections() -> str:
    """List collections this server is allowed to write to."""
    return await _handle_list_collections()


@mcp.tool()
async def outline_write_create_document(
    collection_id: str,
    title: str,
    text: str,
    parent_document_id: str = "",
    publish: bool = True,
    dry_run: bool = True,
) -> str:
    """Create a new document in an allowed collection.

    Args:
        collection_id: Target collection UUID (must be in allowlist)
        title: Document title
        text: Document body (Markdown)
        parent_document_id: Optional parent document UUID for nesting
        publish: Publish immediately (default True)
        dry_run: Preview without writing (default True). Set to False to execute.
    """
    return await _handle_create_document(
        collection_id=collection_id,
        title=title,
        text=text,
        parent_document_id=parent_document_id,
        publish=publish,
        dry_run=dry_run,
    )


@mcp.tool()
async def outline_write_update_document(
    document_id: str,
    title: str = "",
    text: str = "",
    dry_run: bool = True,
) -> str:
    """Update a document you authored (full content replace).

    Args:
        document_id: Document UUID to update
        title: New title (empty string = keep current)
        text: New body text (empty string = keep current)
        dry_run: Preview without writing (default True). Set to False to execute.
    """
    return await _handle_update_document(
        document_id=document_id,
        title=title,
        text=text,
        dry_run=dry_run,
    )


@mcp.tool()
async def outline_write_append_to_document(
    document_id: str,
    content: str,
    dry_run: bool = True,
) -> str:
    """Append content to a document you authored (preserves existing text).

    Args:
        document_id: Document UUID to append to
        content: Markdown content to append at the end
        dry_run: Preview without writing (default True). Set to False to execute.
    """
    return await _handle_append_to_document(
        document_id=document_id,
        content=content,
        dry_run=dry_run,
    )


@mcp.tool()
async def outline_write_document_info(document_id: str) -> str:
    """Get document metadata for pre-flight checks (authorship, collection, timestamps).

    Args:
        document_id: Document UUID to inspect
    """
    return await _handle_document_info(document_id=document_id)


def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(name)s %(levelname)s %(message)s",
        stream=sys.stderr,
    )

    import asyncio
    asyncio.run(_init_clients())
    mcp.run(transport="stdio")


if __name__ == "__main__":
    main()
