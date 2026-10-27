"""Simple TTL cache for API responses."""

from __future__ import annotations

import time
from typing import Any


class TTLCache:
    """In-memory cache with per-key TTL."""

    def __init__(self, default_ttl: int = 300):
        self._store: dict[str, tuple[float, Any]] = {}
        self._default_ttl = default_ttl

    def get(self, key: str) -> Any | None:
        entry = self._store.get(key)
        if entry is None:
            return None
        expires_at, value = entry
        if time.monotonic() > expires_at:
            del self._store[key]
            return None
        return value

    def get_stale(self, key: str) -> Any | None:
        """Return cached value even if expired (for graceful degradation)."""
        entry = self._store.get(key)
        if entry is None:
            return None
        return entry[1]

    def set(self, key: str, value: Any, ttl: int | None = None) -> None:
        effective_ttl = ttl if ttl is not None else self._default_ttl
        self._store[key] = (time.monotonic() + effective_ttl, value)

    def invalidate(self, key: str) -> None:
        self._store.pop(key, None)

    def clear(self) -> None:
        self._store.clear()
