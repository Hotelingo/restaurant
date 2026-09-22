from __future__ import annotations

import os

import pytest
from pydantic import ValidationError

os.environ.setdefault("DATABASE_URL", "postgresql://test:test@localhost:5432/test")
os.environ.setdefault("NEON_AUTH_BASE_URL", "https://example.neon.tech/neondb/auth")
os.environ.setdefault(
    "NEON_AUTH_JWKS_URL",
    "https://example.neon.tech/neondb/auth/.well-known/jwks.json",
)

from app.main import app
from app.reviewer_schemas import (
    PackSignoffRequest,
    ReconciliationDisclosureRequest,
    ReviewCommentCreateRequest,
    ReviewCommentResolveRequest,
)


def test_reviewer_workbench_routes_are_registered() -> None:
    paths = app.openapi()["paths"]
    assert "get" in paths["/reviews/{review_id}/gates"]
    assert "get" in paths["/reviews/{review_id}/comments"]
    assert "post" in paths["/reviews/{review_id}/comments"]
    assert "post" in paths[
        "/reviews/{review_id}/comments/{comment_id}/resolve"
    ]
    assert "post" in paths["/packs/{pack_id}/submit"]
    assert "post" in paths["/packs/{pack_id}/reconciliation-disclosure"]
    assert "post" in paths["/packs/{pack_id}/signoff"]
    assert "get" in paths["/reviews/{review_id}/history"]


def test_workbench_mutations_require_idempotency_key() -> None:
    spec = app.openapi()
    mutations = [
        ("/reviews/{review_id}/comments", "post"),
        ("/reviews/{review_id}/comments/{comment_id}/resolve", "post"),
        ("/packs/{pack_id}/submit", "post"),
        ("/packs/{pack_id}/reconciliation-disclosure", "post"),
        ("/packs/{pack_id}/signoff", "post"),
    ]
    for path, method in mutations:
        operation = spec["paths"][path][method]
        header = next(
            item
            for item in operation["parameters"]
            if item["in"] == "header" and item["name"] == "Idempotency-Key"
        )
        assert header["required"] is True
        assert header["schema"]["minLength"] == 8


def test_comment_and_resolution_text_cannot_be_blank() -> None:
    with pytest.raises(ValidationError):
        ReviewCommentCreateRequest(body="")
    with pytest.raises(ValidationError):
        ReviewCommentResolveRequest(resolution_note="")


def test_not_reconciled_disclosure_requires_reason() -> None:
    with pytest.raises(ValidationError):
        ReconciliationDisclosureRequest(reason="")


def test_signoff_decision_is_closed_enum() -> None:
    with pytest.raises(ValidationError):
        PackSignoffRequest(decision="override")  # type: ignore[arg-type]


def test_signoff_scopes_are_explicit_lists() -> None:
    payload = PackSignoffRequest(
        decision="signed",
        caveat="Cross-module reconciliation is outside this pack.",
        scope_reviewed=["Management P&L"],
        scope_not_reviewed=["Inventory"],
    )
    assert payload.scope_reviewed == ["Management P&L"]
    assert payload.scope_not_reviewed == ["Inventory"]
