from __future__ import annotations

from datetime import date, datetime
from decimal import Decimal
from typing import Literal
from uuid import UUID

from pydantic import BaseModel, Field, field_validator, model_validator

DiagnosisState = Literal["supported","hypothesis","unknown"]
EvidenceStatus = Literal[
    "validated",
    "supported",
    "partly_supported",
    "evidence_required",
    "not_reconciled",
    "not_applicable",
]


class DiagnosisCreateRequest(BaseModel):
    diagnosis_state: DiagnosisState
    driver_code: str | None = Field(default=None, min_length=1, max_length=100)
    evidence_status: EvidenceStatus
    supported_summary: str | None = Field(default=None, max_length=2000)
    hypothesis_summary: str | None = Field(default=None, max_length=2000)
    unknowns: str | None = Field(default=None, max_length=2000)


class DiagnosisRead(BaseModel):
    id: UUID
    review_issue_id: UUID
    version_no: int
    diagnosis_state: DiagnosisState
    driver_code: str | None
    driver_name: str | None
    supported_summary: str | None
    hypothesis_summary: str | None
    unknowns: str | None
    evidence_status: EvidenceStatus
    diagnostic_status: str
    supersedes_diagnosis_id: UUID | None
    created_by: UUID
    created_at: datetime


class DiagnosisMutationResponse(BaseModel):
    diagnosis: DiagnosisRead
    reused: bool


class DriverEvidenceCreateRequest(BaseModel):
    driver_code: str = Field(min_length=1, max_length=100)
    evidence_source_type: str = Field(min_length=1, max_length=100)
    evidence_source_id: str = Field(min_length=1, max_length=500)
    evidence_status: EvidenceStatus
    quantified_impact: Decimal | None = None
    note: str | None = Field(default=None, max_length=4000)


class DriverEvidenceRead(BaseModel):
    id: UUID
    review_issue_id: UUID
    diagnosis_id: UUID
    driver_code: str
    driver_name: str
    evidence_source_type: str
    evidence_source_id: str
    evidence_status: EvidenceStatus
    quantified_impact: str | None
    reconciliation_impact: str
    note: str | None
    approved_by: UUID | None
    created_by: UUID
    created_at: datetime


class DriverEvidenceMutationResponse(BaseModel):
    evidence: DriverEvidenceRead
    reused: bool


class EvidenceRequestCreateRequest(BaseModel):
    requested_dataset: str = Field(min_length=1, max_length=500)
    reason: str = Field(min_length=1, max_length=2000)
    minimum_fields: list[str] = Field(min_length=1, max_length=100)
    owner: str = Field(min_length=1, max_length=500)
    due_date: date

    @field_validator("minimum_fields")
    @classmethod
    def validate_minimum_fields(cls, value: list[str]) -> list[str]:
        cleaned = [item.strip() for item in value]
        if any(not item for item in cleaned):
            raise ValueError("minimum_fields cannot contain blank values")
        return cleaned


class EvidenceRequestFulfillRequest(BaseModel):
    batch_id: UUID


class EvidenceRequestRead(BaseModel):
    id: UUID
    review_issue_id: UUID
    requested_dataset: str
    reason: str
    minimum_fields: list[str]
    owner: str
    due_date: date
    status: str
    fulfilled_batch_id: UUID | None
    fulfilled_at: datetime | None
    created_by: UUID
    created_at: datetime
    updated_at: datetime


class EvidenceRequestMutationResponse(BaseModel):
    evidence_request: EvidenceRequestRead
    reused: bool


class IssueEvidenceWorkspaceResponse(BaseModel):
    issue_id: UUID
    issue_title: str
    issue_evidence_status: str
    latest_diagnosis: DiagnosisRead | None
    diagnosis_history: list[DiagnosisRead]
    driver_evidence: list[DriverEvidenceRead]
    evidence_requests: list[EvidenceRequestRead]


DecisionDisposition = Literal["ACT","MONITOR","INVESTIGATE","ESCALATE","CLOSE"]


class DecisionCreateRequest(BaseModel):
    disposition: DecisionDisposition
    decision_text: str = Field(min_length=1, max_length=4000)
    owner: str | None = Field(default=None, max_length=500)
    lever: str | None = Field(default=None, max_length=2000)
    guardrail: str | None = Field(default=None, max_length=2000)
    verification_metric: str | None = Field(default=None, max_length=1000)
    target_trigger: str | None = Field(default=None, max_length=2000)
    due_date: date | None = None
    cadence: str | None = Field(default=None, max_length=500)
    evidence_request_id: UUID | None = None
    decision_required: str | None = Field(default=None, max_length=2000)
    consequence_of_waiting: str | None = Field(default=None, max_length=2000)
    forecast_treatment: str | None = Field(default=None, max_length=2000)
    closure_evidence: str | None = Field(default=None, max_length=4000)

    @model_validator(mode="after")
    def validate_disposition_requirements(self):
        def present(value: str | None) -> bool:
            return bool(value and value.strip())

        if self.disposition == "ACT":
            missing = [
                name
                for name, value in (
                    ("owner", self.owner),
                    ("lever", self.lever),
                    ("guardrail", self.guardrail),
                    ("verification_metric", self.verification_metric),
                )
                if not present(value)
            ]
            if self.due_date is None and not present(self.cadence):
                missing.append("due_date_or_cadence")
            if missing:
                raise ValueError(
                    "ACT requires owner, lever, guardrail, verification_metric and due_date or cadence"
                )

        elif self.disposition == "INVESTIGATE":
            if (
                self.evidence_request_id is None
                or not present(self.owner)
                or self.due_date is None
            ):
                raise ValueError(
                    "INVESTIGATE requires evidence_request_id, owner and due_date"
                )

        elif self.disposition == "MONITOR":
            if not present(self.target_trigger) or not present(self.cadence):
                raise ValueError("MONITOR requires target_trigger and cadence")

        elif self.disposition == "ESCALATE":
            if (
                not present(self.decision_required)
                or not present(self.consequence_of_waiting)
                or not present(self.owner)
                or self.due_date is None
            ):
                raise ValueError(
                    "ESCALATE requires decision_required, consequence_of_waiting, owner and due_date"
                )

        elif self.disposition == "CLOSE":
            if not present(self.forecast_treatment) or not present(self.closure_evidence):
                raise ValueError(
                    "CLOSE requires forecast_treatment and closure_evidence"
                )

        return self


class DecisionRead(BaseModel):
    id: UUID
    review_issue_id: UUID
    version_no: int
    disposition: DecisionDisposition
    diagnosis_id: UUID | None
    decision_text: str
    owner: str | None
    lever: str | None
    guardrail: str | None
    verification_metric: str | None
    target_trigger: str | None
    due_date: date | None
    cadence: str | None
    evidence_request_id: UUID | None
    decision_required: str | None
    consequence_of_waiting: str | None
    forecast_treatment: str | None
    closure_evidence: str | None
    supersedes_decision_id: UUID | None
    decided_by: UUID
    decided_at: datetime


class DecisionMutationResponse(BaseModel):
    decision: DecisionRead
    reused: bool


class IssueDecisionWorkspaceResponse(BaseModel):
    issue_id: UUID
    issue_title: str
    issue_evidence_status: str
    active_decision: DecisionRead | None
    decision_history: list[DecisionRead]
