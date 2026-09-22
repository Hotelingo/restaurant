from __future__ import annotations

from datetime import datetime
from typing import Literal
from uuid import UUID

from pydantic import BaseModel, Field


PackStatus = Literal[
    "draft",
    "in_review",
    "changes_requested",
    "signed",
    "superseded",
]

ClaimStatus = Literal[
    "draft",
    "edited",
    "accepted",
    "rejected",
]

EvidenceStatus = Literal[
    "validated",
    "supported",
    "partly_supported",
    "evidence_required",
    "not_reconciled",
    "not_applicable",
]


class PackVersionRead(BaseModel):
    id: UUID
    review_id: UUID
    version_no: int
    calc_run_id: UUID
    status: PackStatus
    supersedes_pack_version_id: UUID | None
    generated_at: datetime
    artifact_bucket: str | None
    artifact_path: str | None
    artifact_sha256: str | None
    renderer_version: str | None
    template_version: str | None
    created_by: UUID
    created_at: datetime
    updated_at: datetime


class PackMutationResponse(BaseModel):
    pack: PackVersionRead
    reused: bool


class ClaimCitationRead(BaseModel):
    id: UUID
    calc_result_id: UUID
    calc_id: str
    grain_type: str
    grain_key: dict
    value_numeric: str | None
    value_text: str | None
    unit: str
    currency_code: str | None
    calculation_status: str
    evidence_status: str
    citation_role: str


class ClaimCheckRead(BaseModel):
    passed: bool
    number_match: bool
    citation_present: bool
    banned_wording: bool
    unmatched_numbers: list
    banned_terms: list[str]
    status_echo: str
    direction: str
    scope: str
    pack_calc_run_id: UUID


class PackClaimRead(BaseModel):
    id: UUID
    pack_version_id: UUID
    section_code: str
    claim_text: str
    claim_status: ClaimStatus
    evidence_status: EvidenceStatus
    edited_by: UUID | None
    edited_at: datetime | None
    reviewed_by: UUID | None
    reviewed_at: datetime | None
    created_by: UUID
    created_at: datetime
    citations: list[ClaimCitationRead] = Field(default_factory=list)
    check: ClaimCheckRead | None = None


class PackReadResponse(BaseModel):
    pack: PackVersionRead
    claims: list[PackClaimRead]


class PackClaimCreateRequest(BaseModel):
    section_code: str = Field(min_length=1, max_length=100)
    claim_text: str = Field(min_length=1, max_length=8000)
    evidence_status: EvidenceStatus
    calc_result_ids: list[UUID] = Field(min_length=1, max_length=100)


class PackClaimEditRequest(BaseModel):
    claim_text: str = Field(min_length=1, max_length=8000)


class PackClaimMutationResponse(BaseModel):
    claim: PackClaimRead
    reused: bool


class PackClaimReviewResponse(BaseModel):
    claim: PackClaimRead
    check: ClaimCheckRead
    reused: bool


class PackArtifactUrlResponse(BaseModel):
    url: str
    expires_in_seconds: int
    artifact_sha256: str
