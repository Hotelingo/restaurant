from __future__ import annotations

from datetime import date, datetime
from typing import Literal
from uuid import UUID

from pydantic import BaseModel, Field, model_validator


ActionStatus = Literal[
    "OPEN_ON_TRACK",
    "CLOSED",
    "OVERDUE_NOT_COMPLETED",
    "REPEATED_ISSUE",
    "REOPENED",
]

ActionStatusTag = Literal[
    "waiting_on_owner",
    "follow_up_monitor",
]

VerificationAnswer = Literal["YES", "NO", "UNKNOWN"]
VerificationOutcome = Literal["CONTINUE", "CLOSE", "REOPEN"]


class ActionCreateRequest(BaseModel):
    owner: str | None = Field(default=None, max_length=500)
    owner_user_id: UUID | None = None
    forecast_effect: str | None = Field(default=None, max_length=2000)


class ActionRead(BaseModel):
    id: UUID
    review_id: UUID
    review_issue_id: UUID
    decision_id: UUID
    owner: str
    owner_user_id: UUID | None
    lever: str | None
    guardrail: str | None
    metric: str | None
    target_trigger: str | None
    due_date: date | None
    cadence: str | None
    forecast_effect: str | None
    status: ActionStatus
    status_tag: ActionStatusTag | None
    closure_evidence: str | None
    created_by: UUID
    created_at: datetime
    updated_at: datetime


class ActionMutationResponse(BaseModel):
    action: ActionRead
    reused: bool


class ActionListResponse(BaseModel):
    actions: list[ActionRead]


class ActionStatusRequest(BaseModel):
    status: ActionStatus
    status_tag: ActionStatusTag | None = None
    closure_evidence: str | None = Field(default=None, max_length=4000)
    note: str | None = Field(default=None, max_length=4000)

    @model_validator(mode="after")
    def validate_close_evidence(self):
        if self.status == "CLOSED" and not (
            self.closure_evidence and self.closure_evidence.strip()
        ):
            raise ValueError("CLOSED requires closure_evidence")
        return self


class ActionEventRead(BaseModel):
    id: UUID
    action_id: UUID
    event_type: Literal["status_change", "comment", "verification"]
    from_status: ActionStatus | None
    to_status: ActionStatus | None
    status_tag: ActionStatusTag | None
    note: str | None
    evidence: str | None
    created_by: UUID
    created_at: datetime


class ActionEventListResponse(BaseModel):
    events: list[ActionEventRead]


class PriorActionCheckRequest(BaseModel):
    verification_period_id: UUID

    completed_answer: VerificationAnswer
    completion_evidence: str | None = Field(default=None, max_length=4000)

    driver_moved_answer: VerificationAnswer
    driver_evidence: str | None = Field(default=None, max_length=4000)

    result_responded_answer: VerificationAnswer
    result_evidence: str | None = Field(default=None, max_length=4000)

    outcome: VerificationOutcome
    status_tag: ActionStatusTag | None = None

    closure_evidence: str | None = Field(default=None, max_length=4000)
    reopen_reason: str | None = Field(default=None, max_length=4000)
    note: str | None = Field(default=None, max_length=4000)

    @model_validator(mode="after")
    def validate_verification_contract(self):
        checks = (
            ("completed_answer", self.completed_answer, self.completion_evidence),
            ("driver_moved_answer", self.driver_moved_answer, self.driver_evidence),
            (
                "result_responded_answer",
                self.result_responded_answer,
                self.result_evidence,
            ),
        )
        for field_name, answer, evidence in checks:
            if answer != "UNKNOWN" and not (evidence and evidence.strip()):
                raise ValueError(f"{field_name} YES/NO requires evidence")

        if not any(
            value and value.strip()
            for value in (
                self.completion_evidence,
                self.driver_evidence,
                self.result_evidence,
                self.note,
            )
        ):
            raise ValueError("verification requires evidence or a note")

        has_closure = bool(self.closure_evidence and self.closure_evidence.strip())
        has_reopen = bool(self.reopen_reason and self.reopen_reason.strip())

        if self.outcome == "CLOSE":
            if not has_closure:
                raise ValueError("CLOSE requires closure_evidence")
            if has_reopen:
                raise ValueError("CLOSE cannot carry reopen_reason")
        elif self.outcome == "REOPEN":
            if not has_reopen:
                raise ValueError("REOPEN requires reopen_reason")
            if has_closure:
                raise ValueError("REOPEN cannot carry closure_evidence")
        else:
            if has_closure or has_reopen:
                raise ValueError(
                    "CONTINUE cannot carry closure_evidence or reopen_reason"
                )

        if self.status_tag == "follow_up_monitor" and self.outcome != "CLOSE":
            raise ValueError("follow_up_monitor is only valid with CLOSE")
        if self.status_tag == "waiting_on_owner" and self.outcome != "CONTINUE":
            raise ValueError("waiting_on_owner is only valid with CONTINUE")

        return self


class PriorActionCheckRead(BaseModel):
    id: UUID
    action_id: UUID
    verification_period_id: UUID
    completed_answer: VerificationAnswer
    completion_evidence: str | None
    driver_moved_answer: VerificationAnswer
    driver_evidence: str | None
    result_responded_answer: VerificationAnswer
    result_evidence: str | None
    outcome: VerificationOutcome
    action_status_before: ActionStatus
    action_status_after: ActionStatus
    status_tag: ActionStatusTag | None
    closure_evidence: str | None
    reopen_reason: str | None
    note: str | None
    created_by: UUID
    created_at: datetime


class PriorActionCheckMutationResponse(BaseModel):
    verification: PriorActionCheckRead
    action: ActionRead
    reused: bool


class PriorActionCheckListResponse(BaseModel):
    verifications: list[PriorActionCheckRead]


class PriorActionItem(BaseModel):
    action: ActionRead
    verification: PriorActionCheckRead | None


class PriorActionWorkspaceResponse(BaseModel):
    outlet_id: UUID
    verification_period_id: UUID
    source_period_id: UUID | None
    prior_actions: list[PriorActionItem]
