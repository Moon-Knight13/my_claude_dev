"""Safety guards: collection allowlist, authorship check, audit logging."""

from __future__ import annotations

import json
import logging
from datetime import datetime, timezone
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from outline_write.client import OutlineClient

_audit_logger = logging.getLogger("outline_write.audit")


class CollectionGuard:
    """Enforce writes only to explicitly allowed collections."""

    def __init__(self, allowed_names: list[str], client: Any) -> None:
        self._allowed_names = allowed_names
        self._client = client
        self._allowed: dict[str, str] = {}

    async def resolve(self) -> None:
        collections = await self._client.list_collections()
        for name in self._allowed_names:
            for col in collections:
                if col["name"].lower() == name.lower() or col["id"] == name:
                    self._allowed[col["id"]] = col["name"]
                    break
        if not self._allowed:
            raise ValueError(
                f"No allowed collections resolved from: {self._allowed_names}"
            )

    @property
    def allowed_ids(self) -> set[str]:
        return set(self._allowed.keys())

    @property
    def allowed_names_map(self) -> dict[str, str]:
        return dict(self._allowed)

    def enforce(self, collection_id: str) -> None:
        if collection_id not in self._allowed:
            names = ", ".join(self._allowed.values())
            raise ValueError(
                f"Collection {collection_id} not in allowlist. "
                f"Allowed: {names}"
            )


async def check_authorship(
    client: Any, document_id: str, user_id: str
) -> bool:
    doc = await client.get_document(document_id)
    return doc["createdBy"]["id"] == user_id


def audit_log(operation: str, **kwargs: Any) -> None:
    entry = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "operation": operation,
        **kwargs,
    }
    _audit_logger.info(json.dumps(entry))
