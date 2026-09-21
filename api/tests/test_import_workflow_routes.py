from __future__ import annotations

import os

os.environ.setdefault("DATABASE_URL", "postgresql://test:test@localhost:5432/test")
os.environ.setdefault("NEON_AUTH_BASE_URL", "https://example.neon.tech/neondb/auth")
os.environ.setdefault("NEON_AUTH_JWKS_URL", "https://example.neon.tech/neondb/auth/.well-known/jwks.json")

from app.main import app


def test_import_orchestration_routes_are_registered() -> None:
    paths = app.openapi()["paths"]
    assert "post" in paths["/imports/{batch_id}/parse"]
    assert "get" in paths["/imports/{batch_id}/status"]
    assert "get" in paths["/imports/{batch_id}/exceptions"]
    assert "post" in paths["/imports/{batch_id}/validate"]
    assert "post" in paths["/imports/{batch_id}/mapping/confirm"]


def test_parse_contract_requires_period_and_scenario() -> None:
    operation = app.openapi()["paths"]["/imports/{batch_id}/parse"]["post"]
    schema_ref = operation["requestBody"]["content"]["application/json"]["schema"]["$ref"]
    schema_name = schema_ref.rsplit("/", 1)[-1]
    schema = app.openapi()["components"]["schemas"][schema_name]
    assert {"period_id", "scenario"}.issubset(schema["required"])


def test_mapping_confirmation_requires_idempotency_key() -> None:
    operation = app.openapi()["paths"]["/imports/{batch_id}/mapping/confirm"]["post"]
    header = next(
        item
        for item in operation["parameters"]
        if item["in"] == "header" and item["name"] == "Idempotency-Key"
    )
    assert header["required"] is True
    assert header["schema"]["minLength"] == 8
