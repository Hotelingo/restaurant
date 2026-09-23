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


def test_food_cost_parse_contract_exposes_explicit_t4a_effective_date_default() -> None:
    operation = app.openapi()["paths"]["/imports/{batch_id}/parse"]["post"]
    schema_ref = operation["requestBody"]["content"]["application/json"]["schema"]["$ref"]
    schema_name = schema_ref.rsplit("/", 1)[-1]
    schema = app.openapi()["components"]["schemas"][schema_name]
    assert "effective_from_default" in schema["properties"]
    assert "effective_from_default" not in schema["required"]


def test_mapping_contract_supports_item_and_product_group_confirmation() -> None:
    operation = app.openapi()["paths"]["/imports/{batch_id}/mapping/confirm"]["post"]
    schema_ref = operation["requestBody"]["content"]["application/json"]["schema"]["$ref"]
    schema_name = schema_ref.rsplit("/", 1)[-1]
    schema = app.openapi()["components"]["schemas"][schema_name]
    assert "item_mappings" in schema["properties"]
    assert "product_group_mappings" in schema["properties"]


def _select_output_names(sql: str) -> set[str]:
    """Postgres output column names of a single top-level SELECT list."""
    body = sql.split("select", 1)[1]
    depth, current, items = 0, "", []
    i = 0
    while i < len(body):
        ch = body[i]
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        if depth == 0 and body.startswith("from ", i) and body[i - 1] in " \n":
            break
        if ch == "," and depth == 0:
            items.append(current)
            current = ""
        else:
            current += ch
        i += 1
    items.append(current)
    names = set()
    for item in items:
        item = " ".join(item.split())
        if " as " in item:
            names.add(item.rsplit(" as ", 1)[1].strip())
        else:
            names.add(item.split("::", 1)[0].rsplit(".", 1)[-1].strip())
    return names


def test_batch_status_query_returns_exactly_the_response_fields() -> None:
    # Regression: the query returned `detected_fingerprint`, the model needs
    # `fingerprint`, and every status call failed with a 500.
    import asyncio

    from app.routes.import_workflow import ImportStatusResponse, _batch_status_payload

    captured: dict[str, str] = {}

    class _Result:
        async def fetchone(self):
            return None

    class _Conn:
        async def execute(self, sql, params):
            captured["sql"] = sql
            return _Result()

    asyncio.run(_batch_status_payload(_Conn(), "00000000-0000-0000-0000-000000000000"))
    assert _select_output_names(captured["sql"]) == set(ImportStatusResponse.model_fields)
