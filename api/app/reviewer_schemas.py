from __future__ import annotations

from datetime import datetime
from typing import Literal
from uuid import UUID

from pydantic import BaseModel, Field


class ReviewGateOutcomeRead(BaseModel):
    code: str
    passed: bool
    message: str
    remediation: str
    subject_ids: list[UUID] = Field(default_factory=list)


class ReviewGateResponse(BaseModel):
    review_id: UUID
    pack_version_id: UUID
    passed: bool
    outcomes: list[ReviewGateOutcomeRead]
    failures: list[ReviewGateOutcomeRead]


class ReviewCommentCreateRequest(BaseModel):
    parent_comment_id: UUID | None = None
    body: str = Field(min_length=1, max_length=8000)


class ReviewCommentResolveRequest(BaseModel):
    resolution_note: str = Field(min_length=1, max_length=8000)


class ReviewCommentRead(BaseModel):
    id: UUID
    review_id: UUID
    parent_comment_id: UUID | None
    body: str
    author_user_id: UUID
    author_role: str
    resolution_status: Literal["open", "resolved"]
    resolution_note: str | None
    resolved_by: UUID | None
    resolved_at: datetime | None
    created_at: datetime


class ReviewCommentMutationResponse(BaseModel):
    comment: ReviewCommentRead
    reused: bool


class PackSubmitResponse(BaseModel):
    pack_version_id: UUID
    status: str
    reused: bool


class ReconciliationDisclosureRequest(BaseModel):
    reason: str = Field(min_length=1, max_length=8000)


class ReconciliationDisclosureResponse(BaseModel):
    pack_version_id: UUID
    reconciliation_disclosure: str
    reused: bool


class PackSignoffRequest(BaseModel):
    decision: Literal["signed", "changes_requested"]
    caveat: str | None = Field(default=None, max_length=8000)
    scope_reviewed: list[str] = Field(default_factory=list, max_length=100)
    scope_not_reviewed: list[str] = Field(default_factory=list, max_length=100)


class SignoffRead(BaseModel):
    id: UUID
    review_id: UUID
    pack_version_id: UUID
    calc_run_id: UUID
    reviewer_user_id: UUID
    reviewer_name: str
    reviewer_role: str
    decision: Literal["signed", "changes_requested"]
    caveat: str | None
    scope_reviewed: list[str]
    scope_not_reviewed: list[str]
    gate_snapshot: dict
    created_at: datetime


class PackSignoffResponse(BaseModel):
    signoff: SignoffRead
    pack_status: str
    reused: bool


class PackHistoryVersionRead(BaseModel):
    id: UUID
    version_no: int
    calc_run_id: UUID
    status: str
    supersedes_pack_version_id: UUID | None
    generated_at: datetime
    artifact_sha256: str | None
    created_at: datetime
    signoffs: list[SignoffRead] = Field(default_factory=list)


class ReviewPackHistoryResponse(BaseModel):
    review_id: UUID
    versions: list[PackHistoryVersionRead]
