"""Shared test fixtures for outline-write MCP server."""

from __future__ import annotations

import pytest


FAKE_COLLECTIONS = [
    {"id": "col-aaa-111", "name": "vulns-docs", "documents": []},
    {"id": "col-bbb-222", "name": "Engagement Reports", "documents": []},
    {"id": "col-ccc-333", "name": "Internal Notes", "documents": []},
]

FAKE_USER = {"id": "user-me-123", "name": "Test Bot"}

FAKE_DOC_OWN = {
    "id": "doc-own-001",
    "title": "My Writeup",
    "text": "# Existing content\n\nSome text here.",
    "collectionId": "col-aaa-111",
    "createdBy": {"id": "user-me-123", "name": "Test Bot"},
    "createdAt": "2026-01-01T00:00:00Z",
    "updatedAt": "2026-01-02T00:00:00Z",
}

FAKE_DOC_OTHER = {
    "id": "doc-other-002",
    "title": "Someone Else's Page",
    "text": "Their content.",
    "collectionId": "col-aaa-111",
    "createdBy": {"id": "user-other-456", "name": "Other User"},
    "createdAt": "2026-01-01T00:00:00Z",
    "updatedAt": "2026-01-02T00:00:00Z",
}


class FakeOutlineClient:
    """Mock Outline API client returning canned responses."""

    def __init__(
        self,
        collections: list[dict] | None = None,
        documents: dict[str, dict] | None = None,
        user: dict | None = None,
        create_response: dict | None = None,
        update_response: dict | None = None,
        raise_on_request: Exception | None = None,
    ):
        self.collections = collections or FAKE_COLLECTIONS
        self.documents = documents or {
            "doc-own-001": FAKE_DOC_OWN,
            "doc-other-002": FAKE_DOC_OTHER,
        }
        self.user = user or FAKE_USER
        self.create_response = create_response
        self.update_response = update_response
        self.raise_on_request = raise_on_request
        self.calls: list[tuple[str, dict]] = []

    async def list_collections(self) -> list[dict]:
        self.calls.append(("list_collections", {}))
        if self.raise_on_request:
            raise self.raise_on_request
        return self.collections

    async def get_collection(self, id: str) -> dict:
        self.calls.append(("get_collection", {"id": id}))
        if self.raise_on_request:
            raise self.raise_on_request
        for c in self.collections:
            if c["id"] == id:
                return c
        raise RuntimeError(f"Collection {id} not found")

    async def get_document(self, id: str) -> dict:
        self.calls.append(("get_document", {"id": id}))
        if self.raise_on_request:
            raise self.raise_on_request
        if id in self.documents:
            return self.documents[id]
        raise RuntimeError(f"Document {id} not found")

    async def create_document(
        self,
        collection_id: str,
        title: str,
        text: str,
        parent_document_id: str | None = None,
        publish: bool = True,
    ) -> dict:
        self.calls.append(("create_document", {
            "collection_id": collection_id,
            "title": title,
            "text": text,
            "parent_document_id": parent_document_id,
            "publish": publish,
        }))
        if self.raise_on_request:
            raise self.raise_on_request
        if self.create_response:
            return self.create_response
        return {
            "id": "doc-new-999",
            "title": title,
            "text": text,
            "collectionId": collection_id,
            "createdBy": self.user,
            "createdAt": "2026-11-17T00:00:00Z",
            "updatedAt": "2026-11-17T00:00:00Z",
        }

    async def update_document(
        self,
        id: str,
        title: str | None = None,
        text: str | None = None,
        append: bool = False,
    ) -> dict:
        self.calls.append(("update_document", {
            "id": id,
            "title": title,
            "text": text,
            "append": append,
        }))
        if self.raise_on_request:
            raise self.raise_on_request
        if self.update_response:
            return self.update_response
        doc = self.documents.get(id, {}).copy()
        if title is not None:
            doc["title"] = title
        if text is not None:
            doc["text"] = text
        return doc

    async def search_documents(
        self,
        query: str,
        collection_id: str | None = None,
        limit: int = 25,
    ) -> dict:
        self.calls.append(("search_documents", {
            "query": query,
            "collection_id": collection_id,
            "limit": limit,
        }))
        if self.raise_on_request:
            raise self.raise_on_request
        return {"data": [], "pagination": {"total": 0}}

    async def get_current_user(self) -> dict:
        self.calls.append(("get_current_user", {}))
        if self.raise_on_request:
            raise self.raise_on_request
        return self.user


@pytest.fixture
def fake_client():
    return FakeOutlineClient()


@pytest.fixture
def fake_collections():
    return FAKE_COLLECTIONS
