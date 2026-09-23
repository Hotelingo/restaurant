from __future__ import annotations

from dataclasses import dataclass
from enum import StrEnum
from typing import Literal
from uuid import UUID


ClaimDecisionStatus = Literal["draft", "edited", "accepted", "rejected"]


class ReviewGateCode(StrEnum):
    RECONCILIATION_DISCLOSURE = "RG.RECONCILIATION_DISCLOSURE"
    CLAIMS_RESOLVED = "RG.CLAIMS_RESOLVED"
    ACT_REQUIREMENTS = "RG.ACT_REQUIREMENTS"
    COMMENTS_RESOLVED = "RG.COMMENTS_RESOLVED"
    CLAIM_NUMBER_MATCH = "RG.CLAIM_NUMBER_MATCH"
    CLAIM_CITATION = "RG.CLAIM_CITATION"
    CLAIM_STATUS_ECHO = "RG.CLAIM_STATUS_ECHO"
    CLAIM_DIRECTION = "RG.CLAIM_DIRECTION"
    CLAIM_BANNED_WORDING = "RG.CLAIM_BANNED_WORDING"
    CLAIM_SCOPE = "RG.CLAIM_SCOPE"
    REVIEWER_INDEPENDENCE = "RG.REVIEWER_INDEPENDENCE"


@dataclass(frozen=True, slots=True)
class ClaimGateInput:
    claim_id: UUID
    decision_status: ClaimDecisionStatus
    number_match: bool
    citation_present: bool
    status_echo: bool
    direction: bool
    banned_wording_clear: bool
    scope: bool


@dataclass(frozen=True, slots=True)
class ActDecisionGateInput:
    decision_id: UUID
    owner_present: bool
    lever_present: bool
    guardrail_present: bool
    metric_present: bool
    due_date_present: bool
    cadence_present: bool

    @property
    def requirements_complete(self) -> bool:
        return all(
            (
                self.owner_present,
                self.lever_present,
                self.guardrail_present,
                self.metric_present,
                self.due_date_present or self.cadence_present,
            )
        )


@dataclass(frozen=True, slots=True)
class ReviewGateInput:
    reconciliation_failed: bool
    pack_stamped_not_reconciled: bool
    claims: tuple[ClaimGateInput, ...]
    act_decisions: tuple[ActDecisionGateInput, ...]
    unresolved_comment_count: int
    signer_user_id: UUID
    signer_is_reviewer: bool
    decision_maker_user_ids: tuple[UUID, ...]


@dataclass(frozen=True, slots=True)
class GateOutcome:
    code: ReviewGateCode
    passed: bool
    message: str
    remediation: str
    subject_ids: tuple[UUID, ...] = ()


@dataclass(frozen=True, slots=True)
class ReviewGateResult:
    passed: bool
    outcomes: tuple[GateOutcome, ...]

    @property
    def failures(self) -> tuple[GateOutcome, ...]:
        return tuple(outcome for outcome in self.outcomes if not outcome.passed)


class ReviewGateBlocked(RuntimeError):
    def __init__(self, result: ReviewGateResult) -> None:
        self.result = result
        codes = ", ".join(outcome.code for outcome in result.failures)
        super().__init__(f"review gate failed: {codes}")
