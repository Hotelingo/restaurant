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
