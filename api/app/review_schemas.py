from __future__ import annotations

from datetime import datetime
from typing import Any, Literal
from uuid import UUID

from pydantic import BaseModel


ComparatorScenario = Literal["budget", "forecast", "prior_year"]


class ReviewCreateRequest(BaseModel):
    outlet_id: UUID
    period_id: UUID


class ReviewFrameRequest(BaseModel):
    context_version_id: UUID
    active_calc_run_id: UUID
    comparator_scenario: ComparatorScenario


class ReviewRead(BaseModel):
    id: UUID
    outlet_id: UUID
    period_id: UUID
    status: str
    comparator_scenario: str | None
    context_version_id: UUID | None
    materiality_snapshot: dict[str, Any]
    active_calc_run_id: UUID | None
    review_leader_id: UUID
    started_at: datetime
    frame_confirmed_at: datetime | None
    closed_at: datetime | None
    created_at: datetime
    updated_at: datetime


class ReviewMutationResponse(BaseModel):
    review: ReviewRead
    reused: bool


class ReviewListResponse(BaseModel):
    reviews: list[ReviewRead]


class ReviewIssueCreateRequest(BaseModel):
    source_calc_result_id: UUID
    title: str | None = None
    selection_reason: str | None = None


class ReviewIssueRead(BaseModel):
    id: UUID
    review_id: UUID
    source_calc_run_id: UUID
    source_calc_result_id: UUID
    title: str
    movement_amount: str
    movement_rate: str | None
    ladder_code: str
    module: str
    materiality_reason: str
    materiality_rules: list[str]
    shortlist_order: int
    selection_reason: str | None
    evidence_status: str
    issue_status: str
    created_by: UUID
    created_at: datetime
    updated_at: datetime


class ReviewIssueMutationResponse(BaseModel):
    issue: ReviewIssueRead
    shortlist_count: int
    shortlist_guidance: Literal[
        "below_expected",
        "expected_range",
        "six_with_reason",
        "above_expected_warning",
    ]
    reused: bool


class ReviewIssueListResponse(BaseModel):
    issues: list[ReviewIssueRead]
    shortlist_count: int
    shortlist_guidance: Literal[
        "below_expected",
        "expected_range",
        "six_with_reason",
        "above_expected_warning",
    ]


class ReviewIssueOrderRequest(BaseModel):
    issue_ids: list[UUID]


class ReviewIssueOrderResponse(BaseModel):
    issues: list[ReviewIssueRead]
    reordered_count: int
    reused: bool
