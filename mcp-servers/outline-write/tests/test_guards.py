"""Tests for collection guard, authorship check, and audit logging."""

from __future__ import annotations

import json
import logging

import pytest

from outline_write.guards import CollectionGuard, audit_log, check_authorship
from tests.conftest import FakeOutlineClient


async def test_collection_guard_resolves_names(fake_client):
    guard = CollectionGuard(["vulns-docs", "Engagement Reports"], fake_client)
    await guard.resolve()
    assert guard.allowed_ids == {"col-aaa-111", "col-bbb-222"}


async def test_collection_guard_skips_unknown_name(fake_client):
    guard = CollectionGuard(["vulns-docs", "Nonexistent Collection"], fake_client)
    await guard.resolve()
    assert guard.allowed_ids == {"col-aaa-111"}


async def test_empty_allowlist_refuses_start(fake_client):
    guard = CollectionGuard(["Nonexistent A", "Nonexistent B"], fake_client)
    with pytest.raises(ValueError, match="No allowed collections resolved"):
        await guard.resolve()


async def test_enforce_allowed_collection_passes(fake_client):
    guard = CollectionGuard(["vulns-docs"], fake_client)
    await guard.resolve()
    guard.enforce("col-aaa-111")


async def test_enforce_blocked_collection_raises(fake_client):
    guard = CollectionGuard(["vulns-docs"], fake_client)
    await guard.resolve()
    with pytest.raises(ValueError, match="not in allowlist"):
        guard.enforce("col-ccc-333")


async def test_check_authorship_own_doc_returns_true(fake_client):
    result = await check_authorship(fake_client, "doc-own-001", "user-me-123")
    assert result is True


async def test_check_authorship_other_doc_returns_false(fake_client):
    result = await check_authorship(fake_client, "doc-other-002", "user-me-123")
    assert result is False


def test_audit_log_writes_json_to_stderr(caplog):
    with caplog.at_level(logging.INFO, logger="outline_write.audit"):
        audit_log("create_document", document_id="doc-123", collection_id="col-456")

    assert len(caplog.records) == 1
    record = caplog.records[0]
    data = json.loads(record.message)
    assert data["operation"] == "create_document"
    assert data["document_id"] == "doc-123"
    assert data["collection_id"] == "col-456"
    assert "timestamp" in data
