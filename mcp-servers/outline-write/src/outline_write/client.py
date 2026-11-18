"""Outline wiki API client for write operations."""

from __future__ import annotations

import httpx


class OutlineClient:
    """Async Outline API client. All endpoints use POST (Outline convention)."""

    def __init__(self, api_url: str, api_key: str) -> None:
        url = api_url.rstrip("/")
        if not url.endswith("/api"):
            url += "/api"
        self._base_url = url
        self._api_key = api_key
        self._http: httpx.AsyncClient | None = None

    async def _client(self) -> httpx.AsyncClient:
        if self._http is None or self._http.is_closed:
            self._http = httpx.AsyncClient(
                base_url=self._base_url,
                headers={
                    "Content-Type": "application/json",
                    "Authorization": f"Bearer {self._api_key}",
                },
                timeout=30.0,
            )
        return self._http

    async def _request(self, endpoint: str, body: dict | None = None) -> dict:
        client = await self._client()
        response = await client.post(f"/{endpoint}", json=body or {})
        if response.status_code >= 400:
            text = response.text[:500]
            raise RuntimeError(
                f"Outline API {endpoint}: {response.status_code} {text}"
            )
        return response.json()

    async def list_collections(self) -> list[dict]:
        result = await self._request("collections.list", {"limit": 100})
        return result["data"]

    async def get_collection(self, id: str) -> dict:
        result = await self._request("collections.info", {"id": id})
        return result["data"]

    async def get_document(self, id: str) -> dict:
        result = await self._request("documents.info", {"id": id})
        return result["data"]

    async def create_document(
        self,
        collection_id: str,
        title: str,
        text: str,
        parent_document_id: str | None = None,
        publish: bool = True,
    ) -> dict:
        body: dict = {
            "collectionId": collection_id,
            "title": title,
            "text": text,
            "publish": publish,
        }
        if parent_document_id:
            body["parentDocumentId"] = parent_document_id
        result = await self._request("documents.create", body)
        return result["data"]

    async def update_document(
        self,
        id: str,
        title: str | None = None,
        text: str | None = None,
        append: bool = False,
    ) -> dict:
        body: dict = {"id": id}
        if title is not None:
            body["title"] = title
        if text is not None:
            body["text"] = text
        if append:
            body["append"] = True
        result = await self._request("documents.update", body)
        return result["data"]

    async def search_documents(
        self,
        query: str,
        collection_id: str | None = None,
        limit: int = 25,
    ) -> dict:
        body: dict = {"query": query, "limit": limit}
        if collection_id:
            body["collectionId"] = collection_id
        return await self._request("documents.search", body)

    async def get_current_user(self) -> dict:
        result = await self._request("auth.info")
        return result["data"]["user"]

    async def close(self) -> None:
        if self._http and not self._http.is_closed:
            await self._http.aclose()
