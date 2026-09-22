from __future__ import annotations

from datetime import date, datetime
from decimal import Decimal
from typing import Literal
from uuid import UUID

from pydantic import BaseModel, Field, field_validator

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
