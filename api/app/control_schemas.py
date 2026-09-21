from __future__ import annotations

from datetime import date, datetime
from decimal import Decimal
from typing import Any, Literal
from uuid import UUID

from pydantic import BaseModel, Field, field_validator, model_validator

SettingKey = Literal[
    "primary_comparator",
    "tax_basis",
    "sign_convention",
    "popularity_factor",
    "reconciliation_pos_to_pl_pct",
    "reconciliation_purchases_to_pl_pct",
    "reconciliation_pos_item_to_ledger_pct",
    "food_benchmark_pct",
    "beverage_benchmark_pct",
    "gap_benchmark",
    "reporting_calendar",
    "display_preferences",
]

MaterialityScope = Literal[
    "general", "food", "beverage", "labour", "other_cost", "menu"
]


class AdditionalOutletRequest(BaseModel):
    name: str = Field(min_length=1, max_length=200)
    code: str | None = Field(default=None, max_length=40)
    currency_code: str = Field(min_length=3, max_length=3)
    timezone: str = Field(min_length=1, max_length=100)
    fiscal_year_start_month: int = Field(ge=1, le=12)

    @field_validator("currency_code")
    @classmethod
    def normalize_currency(cls, value: str) -> str:
        return value.upper()


class AdditionalOutletResponse(BaseModel):
    outlet_id: UUID


class SettingWriteRequest(BaseModel):
    key: SettingKey
    value: Any

    @model_validator(mode="after")
    def validate_value(self):
        key = self.key
        value = self.value

        if key == "primary_comparator" and value not in {"budget", "prior_year"}:
            raise ValueError("primary_comparator must be budget or prior_year")
        if key == "tax_basis" and value not in {"tax_exclusive", "tax_inclusive"}:
            raise ValueError("tax_basis must be tax_exclusive or tax_inclusive")
        if key == "sign_convention" and value not in {
            "income_positive_costs_positive",
            "income_positive_costs_negative",
        }:
            raise ValueError("unsupported sign convention")
        if key == "gap_benchmark" and value not in {
            "budget_pct", "prior_period_pct", "expected_usage"
        }:
            raise ValueError("unsupported gap benchmark")
        if key == "reporting_calendar" and value not in {
            "calendar_month", "4-4-5_weeks", "4_or_5_week_periods"
        }:
            raise ValueError("unsupported reporting calendar")
        if key == "display_preferences" and not isinstance(value, dict):
            raise ValueError("display_preferences must be an object")

        numeric_keys = {
            "popularity_factor",
            "reconciliation_pos_to_pl_pct",
            "reconciliation_purchases_to_pl_pct",
            "reconciliation_pos_item_to_ledger_pct",
            "food_benchmark_pct",
            "beverage_benchmark_pct",
        }
        if key in numeric_keys:
            try:
                number = Decimal(str(value))
            except Exception as exc:
                raise ValueError(f"{key} must be numeric") from exc
            if number <= 0:
                raise ValueError(f"{key} must be greater than zero")
            if key != "popularity_factor" and number > 1:
                raise ValueError(f"{key} must be expressed as a decimal between zero and one")
            self.value = str(number)

        return self


class SettingWriteResponse(BaseModel):
    setting_id: UUID


class SettingBatchWriteRequest(BaseModel):
    settings: list[SettingWriteRequest] = Field(min_length=1, max_length=12)


class SettingBatchWriteResponse(BaseModel):
    setting_ids: list[UUID]


class MaterialityWriteRequest(BaseModel):
    scope_type: MaterialityScope
    absolute_threshold: Decimal | None = Field(default=None, gt=0)
    percent_threshold: Decimal | None = Field(default=None, gt=0, le=1)
    recurrence_rule: dict[str, Any] = Field(default_factory=dict)
    risk_override_enabled: bool = False
    proposal_basis: dict[str, Any] = Field(default_factory=dict)
    effective_from: date

    @model_validator(mode="after")
    def require_threshold(self):
        if self.absolute_threshold is None and self.percent_threshold is None:
            raise ValueError("At least one threshold is required")
        return self


class MaterialityWriteResponse(BaseModel):
    materiality_id: UUID
    source_kind: str


class MaterialityVersion(BaseModel):
    id: UUID
    scope_type: str
    absolute_threshold: Decimal | None
    percent_threshold: Decimal | None
    source_kind: str
    proposal_basis: dict[str, Any]
    recurrence_rule: dict[str, Any]
    risk_override_enabled: bool
    effective_from: date
    effective_to: date | None
    approved_at: datetime | None


class OutletControlsResponse(BaseModel):
    organisation_id: UUID
    outlet_id: UUID
    outlet_name: str
    currency_code: str
    timezone: str
    fiscal_year_start_month: int
    settings: dict[str, Any]
    materiality: list[MaterialityVersion]


class AuditEvent(BaseModel):
    id: int
    actor_user_id: UUID | None
    actor_name: str | None
    actor_email: str | None
    outlet_id: UUID | None
    action_code: str
    object_type: str
    object_id: str | None
    correlation_id: str | None
    occurred_at: datetime


class AuditLogResponse(BaseModel):
    organisation_id: UUID
    events: list[AuditEvent]
