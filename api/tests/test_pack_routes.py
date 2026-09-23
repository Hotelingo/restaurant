from __future__ import annotations

import os
from uuid import UUID

import pytest
from pydantic import ValidationError

os.environ.setdefault("DATABASE_URL", "postgresql://test:test@localhost:5432/test")
os.environ.setdefault("NEON_AUTH_BASE_URL", "https://example.neon.tech/neondb/auth")
os.environ.setdefault(
    "NEON_AUTH_JWKS_URL",
    "https://example.neon.tech/neondb/auth/.well-known/jwks.json",
)

from app.main import app
from app.pack_schemas import PackClaimCreateRequest, PackClaimEditRequest


def test_owner_pack_routes_are_registered() -> None:
    paths = app.openapi()["paths"]
    assert "post" in paths["/reviews/{review_id}/packs"]
    assert "get" in paths["/packs/{pack_id}"]
    assert "get" in paths["/packs/{pack_id}/claims"]
    assert "post" in paths["/packs/{pack_id}/claims"]
    assert "post" in paths["/packs/{pack_id}/claims/{claim_id}/edit"]
    assert "get" in paths["/packs/{pack_id}/claims/{claim_id}/check"]
    assert "post" in paths["/packs/{pack_id}/claims/{claim_id}/accept"]
    assert "post" in paths["/packs/{pack_id}/claims/{claim_id}/reject"]
    assert "post" in paths["/packs/{pack_id}/render"]
    assert "get" in paths["/packs/{pack_id}/artifact-url"]


def test_owner_pack_mutations_require_idempotency_key() -> None:
    spec = app.openapi()
    mutations = [
        ("/reviews/{review_id}/packs", "post"),
        ("/packs/{pack_id}/claims", "post"),
        ("/packs/{pack_id}/claims/{claim_id}/edit", "post"),
        ("/packs/{pack_id}/claims/{claim_id}/accept", "post"),
        ("/packs/{pack_id}/claims/{claim_id}/reject", "post"),
        ("/packs/{pack_id}/render", "post"),
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


def test_claim_creation_requires_calc_result_citation() -> None:
    with pytest.raises(ValidationError):
        PackClaimCreateRequest(
            section_code="headline",
            claim_text="Operating profit was 53,549.",
            evidence_status="supported",
            calc_result_ids=[],
        )


def test_claim_creation_keeps_citation_ids_as_uuids() -> None:
    result_id = UUID("00000000-0000-0000-0000-000000000001")
    payload = PackClaimCreateRequest(
        section_code="headline",
        claim_text="Operating profit was 53,549.",
        evidence_status="supported",
        calc_result_ids=[result_id],
    )
    assert payload.calc_result_ids == [result_id]


def test_claim_edit_cannot_be_blank() -> None:
    with pytest.raises(ValidationError):
        PackClaimEditRequest(claim_text="")
