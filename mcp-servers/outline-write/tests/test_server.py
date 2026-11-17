"""Tests for outline-write MCP server tool handlers."""

from __future__ import annotations

import json
from unittest.mock import patch

import pytest

from outline_write import server as srv
from tests.conftest import FAKE_COLLECTIONS, FAKE_DOC_OTHER, FAKE_DOC_OWN, FAKE_USER, FakeOutlineClient


@pytest.fixture(autouse=True)
async def _setup_server():
    """Wire server globals to fake client with vulns-docs allowed."""
    client = FakeOutlineClient()
    srv._client = client
    srv._user_id = FAKE_USER["id"]
    from outline_write.guards import CollectionGuard
    guard = CollectionGuard(["vulns-docs"], client)
    await guard.resolve()
    srv._guard = guard
    yield
    srv._client = None
    srv._guard = None
    srv._user_id = ""


async def test_create_document_in_allowed_collection():
    result = await srv._handle_create_document(
        collection_id="col-aaa-111",
        title="New Writeup",
        text="# Content",
        dry_run=False,
    )
    data = json.loads(result)
    assert data["id"] == "doc-new-999"
    assert data["title"] == "New Writeup"


async def test_create_document_blocked_collection():
    result = await srv._handle_create_document(
        collection_id="col-ccc-333",
        title="Bad Target",
        text="nope",
        dry_run=False,
    )
    data = json.loads(result)
    assert data["error"] is True
    assert "not in allowlist" in data["message"]


async def test_create_document_dry_run():
    client = srv._client
    result = await srv._handle_create_document(
        collection_id="col-aaa-111",
        title="Preview Doc",
        text="# Preview",
        dry_run=True,
    )
    data = json.loads(result)
    assert data["dry_run"] is True
    assert data["title"] == "Preview Doc"
    create_calls = [c for c in client.calls if c[0] == "create_document"]
    assert len(create_calls) == 0


async def test_update_own_document():
    result = await srv._handle_update_document(
        document_id="doc-own-001",
        text="# Updated content",
        dry_run=False,
    )
    data = json.loads(result)
    assert data["title"] == "My Writeup"


async def test_update_other_users_document_rejected():
    result = await srv._handle_update_document(
        document_id="doc-other-002",
        text="hijack",
        dry_run=False,
    )
    data = json.loads(result)
    assert data["error"] is True
    assert "not authored by you" in data["message"]


async def test_append_to_own_document():
    client = srv._client
    result = await srv._handle_append_to_document(
        document_id="doc-own-001",
        content="\n## New Section\n\nAppended text.",
        dry_run=False,
    )
    data = json.loads(result)
    assert "doc-own-001" in [c[1].get("id") for c in client.calls if c[0] == "update_document"]
    update_call = [c for c in client.calls if c[0] == "update_document"][0]
    assert update_call[1]["append"] is True


async def test_append_preserves_existing_content():
    client = srv._client
    await srv._handle_append_to_document(
        document_id="doc-own-001",
        content="\n## Appended",
        dry_run=False,
    )
    update_call = [c for c in client.calls if c[0] == "update_document"][0]
    assert update_call[1]["text"] == "\n## Appended"
    assert update_call[1]["append"] is True


async def test_reject_unlisted_collection_id():
    result = await srv._handle_create_document(
        collection_id="col-zzz-unknown",
        title="Nope",
        text="blocked",
        dry_run=False,
    )
    data = json.loads(result)
    assert data["error"] is True
    assert "not in allowlist" in data["message"]


async def test_api_permission_error_surfaces_cleanly():
    error_client = FakeOutlineClient(
        raise_on_request=RuntimeError("Outline API documents.create: 403 Forbidden")
    )
    srv._client = error_client
    from outline_write.guards import CollectionGuard
    guard = CollectionGuard(["vulns-docs"], FakeOutlineClient())
    await guard.resolve()
    srv._guard = guard

    result = await srv._handle_create_document(
        collection_id="col-aaa-111",
        title="Fail",
        text="nope",
        dry_run=False,
    )
    data = json.loads(result)
    assert data["error"] is True
    assert "403" in data["message"]


async def test_list_collections_shows_only_allowed():
    result = await srv._handle_list_collections()
    data = json.loads(result)
    assert len(data["collections"]) == 1
    assert data["collections"][0]["name"] == "vulns-docs"


async def test_update_document_in_blocked_collection_rejected():
    """Doc authored by us but in non-allowed collection must be rejected."""
    blocked_doc = {
        "id": "doc-blocked-003",
        "title": "My Doc In Wrong Collection",
        "text": "content",
        "collectionId": "col-ccc-333",
        "createdBy": {"id": "user-me-123", "name": "Test Bot"},
        "createdAt": "2026-01-01T00:00:00Z",
        "updatedAt": "2026-01-02T00:00:00Z",
    }
    srv._client.documents["doc-blocked-003"] = blocked_doc
    result = await srv._handle_update_document(
        document_id="doc-blocked-003",
        text="should fail",
        dry_run=False,
    )
    data = json.loads(result)
    assert data["error"] is True
    assert "not in allowlist" in data["message"]


async def test_append_to_document_in_blocked_collection_rejected():
    """Append to own doc in non-allowed collection must be rejected."""
    blocked_doc = {
        "id": "doc-blocked-004",
        "title": "My Doc In Wrong Collection",
        "text": "content",
        "collectionId": "col-ccc-333",
        "createdBy": {"id": "user-me-123", "name": "Test Bot"},
        "createdAt": "2026-01-01T00:00:00Z",
        "updatedAt": "2026-01-02T00:00:00Z",
    }
    srv._client.documents["doc-blocked-004"] = blocked_doc
    result = await srv._handle_append_to_document(
        document_id="doc-blocked-004",
        content="\nshould fail",
        dry_run=False,
    )
    data = json.loads(result)
    assert data["error"] is True
    assert "not in allowlist" in data["message"]


async def test_document_info_returns_metadata():
    result = await srv._handle_document_info(document_id="doc-own-001")
    data = json.loads(result)
    assert data["id"] == "doc-own-001"
    assert data["title"] == "My Writeup"
    assert data["collection_id"] == "col-aaa-111"
    assert data["created_by"] == "user-me-123"
    assert "created_at" in data
    assert "updated_at" in data
    assert data["owned_by_me"] is True
