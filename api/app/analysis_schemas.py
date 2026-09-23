from __future__ import annotations

from datetime import date, datetime
from typing import Any
from uuid import UUID

from pydantic import BaseModel


class CalcInputTrace(BaseModel):
    input_role: str
    template_code: str
    scenario: str
    batch_id: UUID
    profile_version_id: UUID
    canonical_commit_hash: str
    source_file_id: UUID
    original_filename: str
    source_sha256: str


class CalcRunSummary(BaseModel):
    id: UUID
    outlet_id: UUID
    period_id: UUID
    engine_version: str
    status: str
    comparator_scenario: str | None
    result_hash: str | None
    started_at: datetime | None
    completed_at: datetime | None
    settings_snapshot: dict[str, Any]
    inputs: list[CalcInputTrace]


class CalcResultRead(BaseModel):
    id: UUID
    calc_id: str
    grain_type: str
    grain_key: dict[str, Any]
    value_numeric: str | None
    value_text: str | None
    unit: str
    currency_code: str | None
    calculation_status: str
    evidence_status: str
    explanation_code: str | None
    result_metadata: dict[str, Any]
    input_refs: list[str]
    raw_delta: str | None
    profit_effect: str | None


class CalcResultsResponse(BaseModel):
    run_id: UUID
    results: list[CalcResultRead]


class PeriodSummary(BaseModel):
    id: UUID
    label: str
    period_start: date
    period_end: date


class PLLineRead(BaseModel):
    line_code: str
    label: str
    display_order: int
    is_calculated: bool
    actual: CalcResultRead | None
    comparator: CalcResultRead | None
    variance: CalcResultRead | None


class PLAnalysisResponse(BaseModel):
    outlet_id: UUID
    outlet_name: str
    currency_code: str
    period: PeriodSummary
    run: CalcRunSummary
    lines: list[PLLineRead]
    first_material_movement: CalcResultRead | None


class ReconciliationLineRead(BaseModel):
    line_code: str
    label: str
    display_order: int
    statement_accounts: list[str]
    management_amount: str | None
    accounting_amount: str
    difference: str | None
    status: str
    calc_result_id: UUID | None
    financial_fact_ids: list[UUID]
    explanation_code: str | None


class ReconciliationResponse(BaseModel):
    outlet_id: UUID
    outlet_name: str
    currency_code: str
    period: PeriodSummary
    run_id: UUID
    source_batch_id: UUID
    source_file_id: UUID
    original_filename: str
    source_sha256: str
    status: str
    scope: str
    lines: list[ReconciliationLineRead]
    cross_module_status: str
    cross_module_note: str



class FoodCostReadinessRead(BaseModel):
    status: str
    latest_batch_id: UUID | None
    details: dict[str, Any]
    missing_inputs: list[str]
    calculation_status: str
    explanation_code: str | None


class FoodCostGroupRead(BaseModel):
    product_group: str
    evidence_status: str
    actual_consumption: CalcResultRead | None
    actual_cost_pct: CalcResultRead | None
    budget_benchmark: CalcResultRead | None
    budget_gap: CalcResultRead | None
    expected_usage: CalcResultRead | None
    expected_cost_pct: CalcResultRead | None
    menu_mix_effect: CalcResultRead | None
    actual_vs_expected: CalcResultRead | None
    supported_driver_total: CalcResultRead | None
    residual: CalcResultRead | None
    decision_path: CalcResultRead | None


class FoodCostAnalysisResponse(BaseModel):
    outlet_id: UUID
    outlet_name: str
    currency_code: str
    period: PeriodSummary
    readiness: FoodCostReadinessRead
    run: CalcRunSummary | None
    groups: list[FoodCostGroupRead]



class RevenueReadinessRead(BaseModel):
    status: str
    latest_batch_id: UUID | None
    details: dict[str, Any]
    missing_inputs: list[str]
    calculation_status: str
    explanation_code: str | None


class RevenueGrainRead(BaseModel):
    business_view_type: str
    business_view_key: str
    activity_unit_type: str
    evidence_status: str
    activity_units: CalcResultRead | None
    avg_spend: CalcResultRead | None
    revenue: CalcResultRead | None
    volume_effect: CalcResultRead | None
    spend_effect: CalcResultRead | None
    total_variance: CalcResultRead | None


class RevenueContributionRead(BaseModel):
    evidence_status: str
    contribution: CalcResultRead | None
    contribution_per_activity_unit: CalcResultRead | None
    contribution_margin_pct: CalcResultRead | None


class RevenueSourceChannelRead(BaseModel):
    fact_id: UUID
    source_channel: str
    activity_units: str | None
    attributed_revenue: str | None
    direct_channel_cost: str | None
    commission: str | None
    promotion_cost: str | None
    source_evidence_status: str | None


class RevenueAnalysisResponse(BaseModel):
    outlet_id: UUID
    outlet_name: str
    currency_code: str
    period: PeriodSummary
    readiness: RevenueReadinessRead
    run: CalcRunSummary | None
    grains: list[RevenueGrainRead]
    contribution: RevenueContributionRead | None
    source_channels: list[RevenueSourceChannelRead]



class LabourOtherReadinessRead(BaseModel):
    status: str
    latest_batch_id: UUID | None
    details: dict[str, Any]
    missing_inputs: list[str]
    calculation_status: str
    explanation_code: str | None


class LabourRoleGroupRead(BaseModel):
    role_group: str
    activity_basis: str | None
    evidence_status: str
    actual_rate: CalcResultRead | None
    comparator_rate: CalcResultRead | None
    hours_effect_raw: CalcResultRead | None
    rate_effect_raw: CalcResultRead | None
    total_variance: CalcResultRead | None
    hours_per_activity: CalcResultRead | None
    cost_per_activity: CalcResultRead | None
    overtime_hours: CalcResultRead | None
    overtime_rate_effect: CalcResultRead | None


class OtherCostRead(BaseModel):
    line_code: str
    comparator_scenario: str | None
    evidence_status: str
    quantity_effect: CalcResultRead | None
    rate_effect: CalcResultRead | None
    total_variance: CalcResultRead | None


class LabourOtherAnalysisResponse(BaseModel):
    outlet_id: UUID
    outlet_name: str
    currency_code: str
    period: PeriodSummary
    readiness: LabourOtherReadinessRead
    run: CalcRunSummary | None
    labour: list[LabourRoleGroupRead]
    other_costs: list[OtherCostRead]
