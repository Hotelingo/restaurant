from __future__ import annotations

from datetime import date, datetime
from typing import Any
from uuid import UUID

from pydantic import BaseModel


class CalcInputTrace(BaseModel):
    input_role: str
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
