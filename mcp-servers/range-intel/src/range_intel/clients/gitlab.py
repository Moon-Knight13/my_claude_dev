"""GitLab API v4 client for repository file access."""

from __future__ import annotations

import logging
from typing import Any
from urllib.parse import quote

import httpx

from range_intel.cache import TTLCache

logger = logging.getLogger(__name__)


class GitLabClient:
    def __init__(
        self,
        base_url: str,
        token: str,
        project: str,
        ref: str = "main",
        cache_ttl: int = 1800,
    ):
        self._client = httpx.AsyncClient(
            base_url=base_url.rstrip("/"),
            headers={"PRIVATE-TOKEN": token},
            timeout=30,
        )
        self._ref = ref
        self._cache = TTLCache(default_ttl=cache_ttl)
        self._project_input = project
        self._project_id: int | None = None

    async def close(self) -> None:
        await self._client.aclose()

    async def _resolve_project(self) -> int:
        if self._project_id is not None:
            return self._project_id

        if self._project_input.isdigit():
            self._project_id = int(self._project_input)
            return self._project_id

        encoded = quote(self._project_input, safe="")
        r = await self._client.get(f"/api/v4/projects/{encoded}")
        r.raise_for_status()
        self._project_id = r.json()["id"]
        logger.info(
            "Resolved project '%s' → id=%d", self._project_input, self._project_id
        )
        return self._project_id

    async def list_tree(self, path: str, recursive: bool = False) -> list[dict]:
        cache_key = f"tree:{self._ref}:{path}:{recursive}"
        cached = self._cache.get(cache_key)
        if cached is not None:
            return cached

        pid = await self._resolve_project()
        entries: list[dict] = []
        page = 1
        while True:
            r = await self._client.get(
                f"/api/v4/projects/{pid}/repository/tree",
                params={
                    "path": path,
                    "ref": self._ref,
                    "per_page": 100,
                    "page": page,
                    "recursive": str(recursive).lower(),
                },
            )
            r.raise_for_status()
            batch = r.json()
            if not batch:
                break
            entries.extend(batch)
            if len(batch) < 100:
                break
            page += 1

        self._cache.set(cache_key, entries)
        return entries

    async def read_file(self, file_path: str) -> str:
        cache_key = f"file:{self._ref}:{file_path}"
        cached = self._cache.get(cache_key)
        if cached is not None:
            return cached

        pid = await self._resolve_project()
        encoded_path = quote(file_path, safe="")
        r = await self._client.get(
            f"/api/v4/projects/{pid}/repository/files/{encoded_path}/raw",
            params={"ref": self._ref},
        )
        r.raise_for_status()
        content = r.text
        self._cache.set(cache_key, content)
        return content

    async def list_vm_directories(self, vm_path: str) -> list[str]:
        entries = await self.list_tree(vm_path)
        return [e["name"] for e in entries if e["type"] == "tree"]

    async def read_readme(self, vm_path: str, vm_dir: str) -> str | None:
        file_path = f"{vm_path}/{vm_dir}/README.md"
        try:
            return await self.read_file(file_path)
        except httpx.HTTPStatusError as e:
            if e.response.status_code == 404:
                logger.debug("No README.md in %s", vm_dir)
                return None
            raise

    async def read_vuln_defaults(
        self, vuln_path: str, platform: str, vuln_name: str
    ) -> str | None:
        file_path = f"{vuln_path}/{platform}/{vuln_name}/defaults/main.yml"
        try:
            return await self.read_file(file_path)
        except httpx.HTTPStatusError as e:
            if e.response.status_code == 404:
                return None
            raise
