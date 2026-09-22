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
    _labour_other_readiness_from_context,
    _labour_role_group_read,
    _other_cost_read,
    _result_from_row,
    _revenue_contribution_read,
    _revenue_grain_read,
    _revenue_readiness_from_context,
)


def test_slice3_analysis_routes_are_registered() -> None:
    paths = app.openapi()["paths"]
    assert "get" in paths["/calc-runs/{run_id}"]
    assert "get" in paths["/calc-runs/{run_id}/results"]
    assert "get" in paths["/outlets/{outlet_id}/analysis/pnl"]
    assert "get" in paths["/outlets/{outlet_id}/analysis/food-cost"]
    assert "get" in paths["/outlets/{outlet_id}/analysis/revenue"]
    assert "get" in paths["/outlets/{outlet_id}/analysis/labour-other"]
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



def _rv_result(
    calc_id: str,
    *,
    value_numeric: str | None,
    calculation_status: str = "CALCULATED",
    explanation_code: str | None = None,
    grain_key: dict[str, str] | None = None,
) -> CalcResultRead:
    return CalcResultRead(
        id=UUID("00000000-0000-0000-0000-000000000030"),
        calc_id=calc_id,
        grain_type="revenue",
        grain_key=grain_key or {
            "business_view_type": "meal_period",
            "business_view_key": "Brunch",
            "activity_unit_type": "covers",
        },
        value_numeric=value_numeric,
        value_text=None,
        unit="currency",
        currency_code="USD",
        calculation_status=calculation_status,
        evidence_status=(
            "supported"
            if calculation_status == "CALCULATED"
            else "evidence_required"
        ),
        explanation_code=explanation_code,
        result_metadata={},
        input_refs=["revenue_activity_fact:abc"],
        raw_delta=None,
        profit_effect=None,
    )


def test_revenue_analysis_period_filter_is_optional() -> None:
    operation = app.openapi()["paths"]["/outlets/{outlet_id}/analysis/revenue"]["get"]
    period = next(
        item for item in operation["parameters"]
        if item["in"] == "query" and item["name"] == "period_id"
    )
    assert period["required"] is False


def test_revenue_readiness_reports_unreconciled_inputs_explicitly() -> None:
    readiness = _revenue_readiness_from_context(
        {
            "readiness_status": "not_reconciled",
            "latest_batch_id": UUID("00000000-0000-0000-0000-000000000031"),
            "details_json": {
                "t1b_committed": True,
                "t7_committed": True,
                "pnl_net_sales": 228500,
                "t1b_pnl_tie": False,
                "t7_pnl_tie": True,
            },
        },
        has_completed_run=False,
    )
    assert readiness.calculation_status == "NOT_CALCULATED"
    assert readiness.explanation_code == "REVENUE_INPUTS_NOT_RECONCILED"
    assert readiness.missing_inputs == []


def test_revenue_readiness_reports_missing_accounting_anchor() -> None:
    readiness = _revenue_readiness_from_context(
        {
            "readiness_status": "partial",
            "latest_batch_id": UUID("00000000-0000-0000-0000-000000000032"),
            "details_json": {
                "t1b_committed": True,
                "t7_committed": False,
                "pnl_net_sales": None,
            },
        },
        has_completed_run=False,
    )
    assert readiness.calculation_status == "NOT_CALCULATED"
    assert readiness.explanation_code == "REVENUE_INPUTS_INCOMPLETE"
    assert readiness.missing_inputs == [
        "T7_CHANNEL_SOURCE",
        "T1_MANAGEMENT_PL_NET_SALES",
    ]


def test_revenue_grain_preserves_not_calculated_bridge_metric() -> None:
    results = [
        _rv_result("RV.ACTIVITY_UNITS", value_numeric="700.0000"),
        _rv_result("RV.AVG_SPEND", value_numeric="37.0000"),
        _rv_result("RV.REVENUE", value_numeric="25900.0000"),
        _rv_result("RV.VOLUME_EFFECT", value_numeric=None,
                   calculation_status="NOT_CALCULATED",
                   explanation_code="COMPARATOR_NOT_COMMITTED"),
        _rv_result("RV.SPEND_EFFECT", value_numeric=None,
                   calculation_status="NOT_CALCULATED",
                   explanation_code="COMPARATOR_NOT_COMMITTED"),
        _rv_result("RV.TOTAL_VARIANCE", value_numeric=None,
                   calculation_status="NOT_CALCULATED",
                   explanation_code="COMPARATOR_NOT_COMMITTED"),
    ]
    grain = _revenue_grain_read(
        business_view_type="meal_period",
        business_view_key="Brunch",
        activity_unit_type="covers",
        results=results,
    )
    assert grain.evidence_status == "evidence_required"
    assert grain.total_variance is not None
    assert grain.total_variance.value_numeric is None
    assert grain.total_variance.explanation_code == "COMPARATOR_NOT_COMMITTED"


def test_revenue_contribution_preserves_mixed_unit_not_calculated_state() -> None:
    contribution = _rv_result(
        "CT.CONTRIBUTION",
        value_numeric="67801.0000",
        grain_key={"scope": "outlet"},
    )
    per_unit = _rv_result(
        "CT.CONTRIBUTION_PER_ACTIVITY_UNIT",
        value_numeric=None,
        calculation_status="NOT_CALCULATED",
        explanation_code="ACTIVITY_UNITS_MISSING",
        grain_key={"scope": "outlet"},
    )
    margin = _rv_result(
        "CT.CONTRIBUTION_MARGIN_PCT",
        value_numeric="0.2967",
        grain_key={"scope": "outlet"},
    )
    read = _revenue_contribution_read([contribution, per_unit, margin])
    assert read is not None
    assert read.evidence_status == "evidence_required"
    assert read.contribution is not None
    assert read.contribution.value_numeric == "67801.0000"
    assert read.contribution_per_activity_unit is not None
    assert read.contribution_per_activity_unit.value_numeric is None
    assert (
        read.contribution_per_activity_unit.explanation_code
        == "ACTIVITY_UNITS_MISSING"
    )



def _lboc_result(
    calc_id: str,
    *,
    value_numeric: str | None,
    calculation_status: str = "CALCULATED",
    explanation_code: str | None = None,
    grain_key: dict[str, str | None] | None = None,
    result_metadata: dict[str, str] | None = None,
    grain_type: str = "labour",
) -> CalcResultRead:
    return CalcResultRead(
        id=UUID("00000000-0000-0000-0000-000000000040"),
        calc_id=calc_id,
        grain_type=grain_type,
        grain_key=grain_key or {
            "role_group": "Kitchen prep",
            "activity_basis": "total_covers",
        },
        value_numeric=value_numeric,
        value_text=None,
        unit="currency",
        currency_code="USD",
        calculation_status=calculation_status,
        evidence_status=(
            "supported"
            if calculation_status == "CALCULATED"
            else "evidence_required"
        ),
        explanation_code=explanation_code,
        result_metadata=result_metadata or {},
        input_refs=["labour_fact:abc"],
        raw_delta=None,
        profit_effect=None,
    )


def test_labour_other_analysis_period_filter_is_optional() -> None:
    operation = app.openapi()["paths"][
        "/outlets/{outlet_id}/analysis/labour-other"
    ]["get"]
    period = next(
        item for item in operation["parameters"]
        if item["in"] == "query" and item["name"] == "period_id"
    )
    assert period["required"] is False


def test_labour_other_readiness_reports_missing_comparator_anchor() -> None:
    readiness = _labour_other_readiness_from_context(
        {
            "readiness_status": "partial",
            "latest_batch_id": UUID("00000000-0000-0000-0000-000000000041"),
            "details_json": {
                "t5_committed": True,
                "pnl_direct_labour": 84317,
                "t5_actual_labour_cost": 84317,
                "t5_comparator_labour_cost": 79112,
                "pnl_comparator_direct_labour": None,
                "actual_pnl_tie": True,
                "comparator_pnl_tie": False,
            },
        },
        has_completed_run=False,
    )
    assert readiness.calculation_status == "NOT_CALCULATED"
    assert readiness.explanation_code == "LABOUR_INPUTS_INCOMPLETE"
    assert readiness.missing_inputs == ["T6_COMPARATOR_DIRECT_LABOUR"]


def test_labour_other_readiness_reports_unreconciled_inputs_explicitly() -> None:
    readiness = _labour_other_readiness_from_context(
        {
            "readiness_status": "not_reconciled",
            "latest_batch_id": UUID("00000000-0000-0000-0000-000000000042"),
            "details_json": {
                "t5_committed": True,
                "pnl_direct_labour": 84317,
                "t5_actual_labour_cost": 85000,
                "t5_comparator_labour_cost": 79112,
                "pnl_comparator_direct_labour": 79112,
                "actual_pnl_tie": False,
                "comparator_pnl_tie": True,
            },
        },
        has_completed_run=False,
    )
    assert readiness.calculation_status == "NOT_CALCULATED"
    assert readiness.explanation_code == "LABOUR_INPUTS_NOT_RECONCILED"
    assert readiness.missing_inputs == []


def test_labour_group_preserves_activity_basis_and_optional_overtime_gap() -> None:
    results = [
        _lboc_result("LB.ACTUAL_RATE", value_numeric="25.6250"),
        _lboc_result("LB.COMPARATOR_RATE", value_numeric="25.0685"),
        _lboc_result("LB.HOURS_EFFECT_RAW", value_numeric="1754.7945"),
        _lboc_result("LB.RATE_EFFECT_RAW", value_numeric="445.2055"),
        _lboc_result("LB.TOTAL_VARIANCE", value_numeric="2200.0000"),
        _lboc_result(
            "LB.HOURS_PER_ACTIVITY",
            value_numeric="0.1416",
            result_metadata={"activity_basis": "total_covers"},
        ),
        _lboc_result(
            "LB.COST_PER_ACTIVITY",
            value_numeric="3.6283",
            result_metadata={"activity_basis": "total_covers"},
        ),
        _lboc_result("LB.OVERTIME_HOURS", value_numeric="40.0000"),
        _lboc_result(
            "LB.OVERTIME_RATE_EFFECT",
            value_numeric=None,
            calculation_status="NOT_CALCULATED",
            explanation_code="OVERTIME_RATE_EVIDENCE_MISSING",
        ),
    ]
    group = _labour_role_group_read(
        role_group="Kitchen prep",
        activity_basis="total_covers",
        results=results,
    )
    assert group.evidence_status == "supported"
    assert group.activity_basis == "total_covers"
    assert group.total_variance is not None
    assert group.total_variance.value_numeric == "2200.0000"
    assert group.overtime_rate_effect is not None
    assert group.overtime_rate_effect.value_numeric is None
    assert (
        group.overtime_rate_effect.explanation_code
        == "OVERTIME_RATE_EVIDENCE_MISSING"
    )


def test_other_cost_exposes_total_without_fabricating_quantity_rate() -> None:
    grain = {
        "ladder_code": "SHARED_RESTAURANT_COST",
        "actual_scenario": "actual",
        "comparator_scenario": "budget",
    }
    results = [
        _lboc_result(
            "OC.QUANTITY_EFFECT",
            value_numeric=None,
            calculation_status="NOT_CALCULATED",
            explanation_code="QUANTITY_RATE_EVIDENCE_MISSING",
            grain_key=grain,
            grain_type="other_cost",
        ),
        _lboc_result(
            "OC.RATE_EFFECT",
            value_numeric=None,
            calculation_status="NOT_CALCULATED",
            explanation_code="QUANTITY_RATE_EVIDENCE_MISSING",
            grain_key=grain,
            grain_type="other_cost",
        ),
        _lboc_result(
            "OC.TOTAL_VARIANCE",
            value_numeric="2092.0000",
            grain_key=grain,
            grain_type="other_cost",
        ),
    ]
    read = _other_cost_read(
        line_code="SHARED_RESTAURANT_COST",
        comparator_scenario="budget",
        results=results,
    )
    assert read.evidence_status == "supported_total_only"
    assert read.total_variance is not None
    assert read.total_variance.value_numeric == "2092.0000"
    assert read.quantity_effect is not None
    assert read.quantity_effect.value_numeric is None
    assert read.rate_effect is not None
    assert read.rate_effect.value_numeric is None
