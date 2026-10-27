"""Providentia API v3 client."""

from __future__ import annotations

import logging
from typing import Any

import httpx

from range_intel.cache import TTLCache
from range_intel.models import Environment, Host, HostInstance, Network, Tag

logger = logging.getLogger(__name__)


class ProvidentiaClient:
    def __init__(self, base_url: str, token: str, cache_ttl: int = 300):
        self._client = httpx.AsyncClient(
            base_url=base_url.rstrip("/"),
            headers={"Authorization": f"Token {token}"},
            timeout=30,
        )
        self._cache = TTLCache(default_ttl=cache_ttl)

    async def close(self) -> None:
        await self._client.aclose()

    async def _get(self, path: str) -> Any:
        cached = self._cache.get(path)
        if cached is not None:
            return cached

        try:
            r = await self._client.get(path)
            r.raise_for_status()
            data = r.json().get("result", r.json())
            self._cache.set(path, data)
            return data
        except httpx.HTTPStatusError as e:
            logger.error("Providentia %s returned %s", path, e.response.status_code)
            stale = self._cache.get_stale(path)
            if stale is not None:
                logger.warning("Returning stale cache for %s", path)
                return stale
            raise
        except httpx.ConnectError:
            logger.error("Providentia unreachable")
            stale = self._cache.get_stale(path)
            if stale is not None:
                logger.warning("Returning stale cache for %s (connection failed)", path)
                return stale
            raise

    async def environments(self) -> list[Environment]:
        data = await self._get("/api/v3/")
        return [Environment(**e) for e in data]

    async def hosts(self, env: str) -> list[str]:
        return await self._get(f"/api/v3/{env}/hosts")

    async def host(self, env: str, host_id: str) -> Host:
        data = await self._get(f"/api/v3/{env}/hosts/{host_id}")
        return Host(**data)

    async def inventory(self, env: str) -> list[Host]:
        data = await self._get(f"/api/v3/{env}/inventory")
        return [Host(**h) for h in data]

    async def networks(self, env: str) -> list[Network]:
        data = await self._get(f"/api/v3/{env}/networks")
        return [Network(**n) for n in data]

    async def tags(self, env: str) -> list[Tag]:
        data = await self._get(f"/api/v3/{env}/tags")
        return [Tag(**t) for t in data]
