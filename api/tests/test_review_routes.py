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


def test_review_mutations_require_idempotency_key() -> None:
    paths = app.openapi()["paths"]
    for path in ("/reviews", "/reviews/{review_id}/frame"):
        operation = paths[path]["post"]
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
