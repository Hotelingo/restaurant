from __future__ import annotations

from collections.abc import Callable
from uuid import UUID

from .model import (
    GateOutcome,
    ReviewGateBlocked,
    ReviewGateCode,
    ReviewGateInput,
    ReviewGateResult,
)


def _claim_subjects(
    snapshot: ReviewGateInput,
    predicate: Callable[[object], bool],
) -> tuple[UUID, ...]:
    return tuple(
        claim.claim_id
        for claim in snapshot.claims
        if not predicate(claim)
    )


def _outcome(
    code: ReviewGateCode,
    passed: bool,
    message: str,
    remediation: str,
    subject_ids: tuple[UUID, ...] = (),
) -> GateOutcome:
    return GateOutcome(
        code=code,
        passed=passed,
        message=message,
        remediation=remediation,
        subject_ids=subject_ids,
    )


def evaluate_review_gate(snapshot: ReviewGateInput) -> ReviewGateResult:
    if snapshot.unresolved_comment_count < 0:
        raise ValueError("unresolved_comment_count cannot be negative")

    unresolved_claims = tuple(
        claim.claim_id
        for claim in snapshot.claims
        if claim.decision_status not in ("accepted", "rejected")
    )
    incomplete_act = tuple(
        decision.decision_id
        for decision in snapshot.act_decisions
        if not decision.requirements_complete
    )

    number_failures = _claim_subjects(snapshot, lambda claim: claim.number_match)
    citation_failures = _claim_subjects(snapshot, lambda claim: claim.citation_present)
    status_failures = _claim_subjects(snapshot, lambda claim: claim.status_echo)
    direction_failures = _claim_subjects(snapshot, lambda claim: claim.direction)
    wording_failures = _claim_subjects(snapshot, lambda claim: claim.banned_wording_clear)
    scope_failures = _claim_subjects(snapshot, lambda claim: claim.scope)

    reconciliation_ok = (
        not snapshot.reconciliation_failed
        or snapshot.pack_stamped_not_reconciled
    )
    comments_ok = snapshot.unresolved_comment_count == 0
    reviewer_independence_ok = (
        snapshot.signer_is_reviewer
        and snapshot.signer_user_id not in snapshot.decision_maker_user_ids
    )

    outcomes = (
        _outcome(
            ReviewGateCode.RECONCILIATION_DISCLOSURE,
            reconciliation_ok,
            (
                "Reconciliation is complete or the pack explicitly discloses "
                "that it is Not Reconciled."
            ),
            (
                "Resolve the failed reconciliation, or stamp the Owner Pack "
                "Not Reconciled and include the reason."
            ),
        ),
        _outcome(
            ReviewGateCode.CLAIMS_RESOLVED,
            not unresolved_claims,
            "Every claim has an explicit reviewer decision.",
            "Accept or reject every remaining draft/edited claim before sign-off.",
            unresolved_claims,
        ),
        _outcome(
            ReviewGateCode.ACT_REQUIREMENTS,
            not incomplete_act,
            "Every ACT decision carries the required control fields.",
            (
                "Complete owner, lever, guardrail, verification metric, due date "
                "and cadence for each ACT decision."
            ),
            incomplete_act,
        ),
        _outcome(
            ReviewGateCode.COMMENTS_RESOLVED,
            comments_ok,
            "No reviewer comment remains unresolved.",
            "Resolve every open reviewer comment before sign-off.",
        ),
        _outcome(
            ReviewGateCode.CLAIM_NUMBER_MATCH,
            not number_failures,
            "Every numeric magnitude matches cited engine output.",
            "Edit or reject claims containing a number absent from their cited results.",
            number_failures,
        ),
        _outcome(
            ReviewGateCode.CLAIM_CITATION,
            not citation_failures,
            "Every claim has an allowed citation or hypothesis basis.",
            "Add an immutable calculation citation or reject the uncited claim.",
            citation_failures,
        ),
        _outcome(
            ReviewGateCode.CLAIM_STATUS_ECHO,
            not status_failures,
            "Claims preserve the evidence/calculation status of their cited results.",
            (
                "Edit the claim to echo Not Calculated, Partial, Evidence Required "
                "or other non-final status without upgrading it."
            ),
            status_failures,
        ),
        _outcome(
            ReviewGateCode.CLAIM_DIRECTION,
            not direction_failures,
            "Directional wording agrees with the cited variance sign.",
            "Correct the above/below, adverse/favourable or up/down wording.",
            direction_failures,
        ),
        _outcome(
            ReviewGateCode.CLAIM_BANNED_WORDING,
            not wording_failures,
            "No prohibited accusation, causal overclaim or absolute wording is present.",
            "Remove or rewrite prohibited wording before the claim can be accepted.",
            wording_failures,
        ),
        _outcome(
            ReviewGateCode.CLAIM_SCOPE,
            not scope_failures,
            "Every claim stays within the pack period, comparator and authorised input scope.",
            "Remove out-of-scope entities or cite an in-scope result.",
            scope_failures,
        ),
        _outcome(
            ReviewGateCode.REVIEWER_INDEPENDENCE,
            reviewer_independence_ok,
            "The signer is a Reviewer and did not make a decision in this review.",
            (
                "Use an authorised Reviewer who is independent of the recorded "
                "management decisions."
            ),
        ),
    )

    return ReviewGateResult(
        passed=all(outcome.passed for outcome in outcomes),
        outcomes=outcomes,
    )


def enforce_review_gate(snapshot: ReviewGateInput) -> ReviewGateResult:
    result = evaluate_review_gate(snapshot)
    if not result.passed:
        raise ReviewGateBlocked(result)
    return result
