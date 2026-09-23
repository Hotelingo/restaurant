from __future__ import annotations

from datetime import date
from uuid import UUID

from pydantic import BaseModel, Field


class ContextVersionRequest(BaseModel):
    service_style: str | None = Field(default=None, max_length=120)
    seats: int | None = Field(default=None, ge=0, le=100000)
    meal_periods: list[str] = Field(default_factory=list)
    business_formats: list[str] = Field(default_factory=list)
    customer_sources: list[str] = Field(default_factory=list)
    recipe_costing_status: str | None = Field(default=None, max_length=120)
    labour_recording_basis: str | None = Field(default=None, max_length=120)
    source_tracking_quality: str | None = Field(default=None, max_length=120)
    evidence_maturity: str | None = Field(default=None, max_length=120)
    effective_from: date


class ContextVersionResponse(BaseModel):
    context_id: UUID
    version_no: int


class ReportingPeriodRequest(BaseModel):
    period_start: date
    period_end: date
    label: str = Field(min_length=1, max_length=120)


class ReportingPeriodResponse(BaseModel):
    period_id: UUID


class SetupSummaryPeriod(BaseModel):
    id: UUID
    label: str
    period_start: date
    period_end: date
    close_status: str


class SetupSummaryResponse(BaseModel):
    organisation_id: UUID
    organisation_name: str
    outlet_id: UUID
    outlet_name: str
    outlet_code: str | None
    currency_code: str
    timezone: str
    latest_context_version: int | None
    periods: list[SetupSummaryPeriod]
