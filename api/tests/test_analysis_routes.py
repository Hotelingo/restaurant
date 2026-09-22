from __future__ import annotations

import os
from decimal import Decimal
from uuid import UUID

os.environ.setdefault("DATABASE_URL", "postgresql://test:test@localhost:5432/test")
os.environ.setdefault("NEON_AUTH_BASE_URL", "https://example.neon.tech/neondb/auth")
os.environ.setdefault("NEON_AUTH_JWKS_URL", "https://example.neon.tech/neondb/auth/.well-known/jwks.json")

from app.main import app
from app.analysis_schemas import CalcResultRead
from app.routes.analysis import (
    _food_cost_group_read,
    _food_cost_readiness_from_context,
    _result_from_row,
)


def test_slice3_analysis_routes_are_registered() -> None:
    paths = app.openapi()["paths"]
    assert "get" in paths["/calc-runs/{run_id}"]
    assert "get" in paths["/calc-runs/{run_id}/results"]
    assert "get" in paths["/outlets/{outlet_id}/analysis/pnl"]
    assert "get" in paths["/outlets/{outlet_id}/analysis/food-cost"]
    assert "get" in paths["/periods/{period_id}/reconciliation"]


def test_pl_analysis_period_filter_is_optional() -> None:
    operation = app.openapi()["paths"]["/outlets/{outlet_id}/analysis/pnl"]["get"]
    period = next(
        item for item in operation["parameters"]
        if item["in"] == "query" and item["name"] == "period_id"
    )
    assert period["required"] is False


def test_result_adapter_preserves_not_calculated_as_non_numeric() -> None:
    row = {
        "id": UUID("00000000-0000-0000-0000-000000000001"),
        "calc_id": "PL.VAR.NET_SALES",
        "grain_type": "management_pl_variance",
        "grain_key": {"ladder_code": "NET_SALES"},
        "value_numeric": None,
        "value_text": None,
        "unit": "currency",
        "currency_code": "USD",
        "calculation_status": "NOT_CALCULATED",
        "evidence_status": "evidence_required",
        "explanation_code": "COMPARATOR_NOT_COMMITTED",
        "result_metadata": {},
        "input_refs": [],
        "raw_delta": None,
        "profit_effect": None,
    }
    result = _result_from_row(row)
    assert result.value_numeric is None
    assert result.value_text is None
    assert result.explanation_code == "COMPARATOR_NOT_COMMITTED"


def test_result_adapter_serialises_decimal_without_float_conversion() -> None:
    row = {
        "id": UUID("00000000-0000-0000-0000-000000000002"),
        "calc_id": "PL.OPERATING_PROFIT",
        "grain_type": "management_pl",
        "grain_key": {"scenario": "actual", "ladder_code": "OPERATING_PROFIT"},
        "value_numeric": Decimal("53549.0000"),
        "value_text": None,
        "unit": "currency",
        "currency_code": "USD",
        "calculation_status": "CALCULATED",
        "evidence_status": "supported",
        "explanation_code": None,
        "result_metadata": {},
        "input_refs": ["financial_fact:abc"],
        "raw_delta": None,
        "profit_effect": None,
    }
    result = _result_from_row(row)
    assert result.value_numeric == "53549.0000"
    assert result.currency_code == "USD"
    assert result.input_refs == ["financial_fact:abc"]



def test_food_cost_analysis_period_filter_is_optional() -> None:
    operation = app.openapi()["paths"]["/outlets/{outlet_id}/analysis/food-cost"]["get"]
    period = next(
        item for item in operation["parameters"]
        if item["in"] == "query" and item["name"] == "period_id"
    )
    assert period["required"] is False


def test_food_cost_readiness_is_explicit_not_calculated_when_inputs_missing() -> None:
    readiness = _food_cost_readiness_from_context(
        {
            "readiness_status": "partial",
            "latest_batch_id": UUID("00000000-0000-0000-0000-000000000010"),
            "details_json": {
                "t2_item_sales_committed": True,
                "t3_stock_committed": False,
                "t4a_item_cost_committed": True,
            },
        },
        has_completed_run=False,
    )
    assert readiness.calculation_status == "NOT_CALCULATED"
    assert readiness.explanation_code == "FOOD_COST_INPUTS_INCOMPLETE"
    assert readiness.missing_inputs == ["T3_STOCK"]


def test_food_cost_group_preserves_not_calculated_metric_as_null() -> None:
    expected = CalcResultRead(
        id=UUID("00000000-0000-0000-0000-000000000020"),
        calc_id="FC.EXPECTED_USAGE",
        grain_type="food_cost",
        grain_key={"product_group": "food"},
        value_numeric=None,
        value_text=None,
        unit="currency",
        currency_code="USD",
        calculation_status="NOT_CALCULATED",
        evidence_status="evidence_required",
        explanation_code="ITEM_COST_MISSING",
        result_metadata={},
        input_refs=["item_sales_fact:abc"],
        raw_delta=None,
        profit_effect=None,
    )
    group = _food_cost_group_read("food", [expected])
    assert group.expected_usage is not None
    assert group.expected_usage.value_numeric is None
    assert group.expected_usage.explanation_code == "ITEM_COST_MISSING"
    assert group.evidence_status == "evidence_required"
    assert group.actual_consumption is None
