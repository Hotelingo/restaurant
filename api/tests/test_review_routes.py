from __future__ import annotations

import os

os.environ.setdefault("DATABASE_URL", "postgresql://test:test@localhost:5432/test")
os.environ.setdefault("NEON_AUTH_BASE_URL", "https://example.neon.tech/neondb/auth")
os.environ.setdefault("NEON_AUTH_JWKS_URL", "https://example.neon.tech/neondb/auth/.well-known/jwks.json")

from app.main import app


def test_review_and_frame_routes_are_registered() -> None:
    paths = app.openapi()["paths"]
    assert "post" in paths["/reviews"]
    assert "get" in paths["/reviews"]
    assert "get" in paths["/reviews/{review_id}"]
    assert "post" in paths["/reviews/{review_id}/frame"]
    assert "post" in paths["/reviews/{review_id}/issues"]
    assert "get" in paths["/reviews/{review_id}/issues"]
    assert "put" in paths["/reviews/{review_id}/issues/order"]


def test_review_mutations_require_idempotency_key() -> None:
    paths = app.openapi()["paths"]
    for path, method in (
        ("/reviews", "post"),
        ("/reviews/{review_id}/frame", "post"),
        ("/reviews/{review_id}/issues", "post"),
        ("/reviews/{review_id}/issues/order", "put"),
    ):
        operation = paths[path][method]
        header = next(
            item
            for item in operation["parameters"]
            if item["in"] == "header" and item["name"] == "Idempotency-Key"
        )
        assert header["required"] is True
        assert header["schema"]["minLength"] == 8


def test_frame_contract_restricts_comparator_vocabulary() -> None:
    schema = app.openapi()["components"]["schemas"]["ReviewFrameRequest"]
    comparator = schema["properties"]["comparator_scenario"]
    assert set(comparator["enum"]) == {"budget", "forecast", "prior_year"}



def test_shortlist_create_contract_accepts_only_result_identity_and_human_labels() -> None:
    schema = app.openapi()["components"]["schemas"]["ReviewIssueCreateRequest"]
    assert set(schema["properties"]) == {
        "source_calc_result_id",
        "title",
        "selection_reason",
    }
    assert "movement_amount" not in schema["properties"]
    assert "movement_rate" not in schema["properties"]
    assert "materiality_reason" not in schema["properties"]
