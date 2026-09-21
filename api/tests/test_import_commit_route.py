from __future__ import annotations

import os

os.environ.setdefault("DATABASE_URL", "postgresql://test:test@localhost:5432/test")
os.environ.setdefault("NEON_AUTH_BASE_URL", "https://example.neon.tech/neondb/auth")
os.environ.setdefault("NEON_AUTH_JWKS_URL", "https://example.neon.tech/neondb/auth/.well-known/jwks.json")

from app.main import app


def test_financial_import_commit_route_is_registered() -> None:
    paths = app.openapi()["paths"]
    assert "/imports/{batch_id}/commit" in paths
    assert "post" in paths["/imports/{batch_id}/commit"]


def test_commit_openapi_requires_idempotency_key() -> None:
    operation = app.openapi()["paths"]["/imports/{batch_id}/commit"]["post"]
    header = next(
        item
        for item in operation["parameters"]
        if item["in"] == "header" and item["name"] == "Idempotency-Key"
    )
    assert header["required"] is True
    assert header["schema"]["minLength"] == 8
