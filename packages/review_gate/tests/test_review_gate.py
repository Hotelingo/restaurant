from __future__ import annotations

import unittest
from uuid import UUID

from packages.review_gate import (
    ActDecisionGateInput,
    ClaimGateInput,
    ReviewGateBlocked,
    ReviewGateCode,
    ReviewGateInput,
    enforce_review_gate,
    evaluate_review_gate,
)


SIGNER = UUID("10000000-0000-0000-0000-000000000001")
MANAGER = UUID("10000000-0000-0000-0000-000000000002")
CLAIM = UUID("10000000-0000-0000-0000-000000000003")
DECISION = UUID("10000000-0000-0000-0000-000000000004")


def good_claim(**overrides) -> ClaimGateInput:
    values = {
        "claim_id": CLAIM,
        "decision_status": "accepted",
        "number_match": True,
        "citation_present": True,
        "status_echo": True,
        "direction": True,
        "banned_wording_clear": True,
        "scope": True,
    }
    values.update(overrides)
    return ClaimGateInput(**values)


def good_act(**overrides) -> ActDecisionGateInput:
    values = {
        "decision_id": DECISION,
        "owner_present": True,
        "lever_present": True,
        "guardrail_present": True,
        "metric_present": True,
        "due_date_present": True,
        "cadence_present": True,
    }
    values.update(overrides)
    return ActDecisionGateInput(**values)


def good_snapshot(**overrides) -> ReviewGateInput:
    values = {
        "reconciliation_failed": False,
        "pack_stamped_not_reconciled": False,
        "claims": (good_claim(),),
        "act_decisions": (good_act(),),
        "unresolved_comment_count": 0,
        "signer_user_id": SIGNER,
        "signer_is_reviewer": True,
        "decision_maker_user_ids": (MANAGER,),
    }
    values.update(overrides)
    return ReviewGateInput(**values)


class ReviewGateTests(unittest.TestCase):
    def test_passes_exactly_eleven_conditions(self) -> None:
        result = evaluate_review_gate(good_snapshot())
        self.assertTrue(result.passed)
        self.assertEqual(len(result.outcomes), 11)
        self.assertEqual(result.failures, ())

    def test_failed_reconciliation_requires_not_reconciled_stamp(self) -> None:
        result = evaluate_review_gate(
            good_snapshot(reconciliation_failed=True)
        )
        self.assertFalse(result.passed)
        self.assertEqual(
            result.failures[0].code,
            ReviewGateCode.RECONCILIATION_DISCLOSURE,
        )

        disclosed = evaluate_review_gate(
            good_snapshot(
                reconciliation_failed=True,
                pack_stamped_not_reconciled=True,
            )
        )
        self.assertTrue(disclosed.passed)

    def test_every_claim_requires_reviewer_resolution(self) -> None:
        result = evaluate_review_gate(
            good_snapshot(claims=(good_claim(decision_status="edited"),))
        )
        failure = next(
            item
            for item in result.failures
            if item.code == ReviewGateCode.CLAIMS_RESOLVED
        )
        self.assertEqual(failure.subject_ids, (CLAIM,))

    def test_act_decision_requires_all_control_fields(self) -> None:
        result = evaluate_review_gate(
            good_snapshot(act_decisions=(good_act(guardrail_present=False),))
        )
        failure = next(
            item
            for item in result.failures
            if item.code == ReviewGateCode.ACT_REQUIREMENTS
        )
        self.assertEqual(failure.subject_ids, (DECISION,))
        self.assertIn("guardrail", failure.remediation)

    def test_act_scheduling_accepts_due_date_or_cadence(self) -> None:
        due_only = evaluate_review_gate(
            good_snapshot(
                act_decisions=(good_act(cadence_present=False),)
            )
        )
        cadence_only = evaluate_review_gate(
            good_snapshot(
                act_decisions=(good_act(due_date_present=False),)
            )
        )
        self.assertTrue(due_only.passed)
        self.assertTrue(cadence_only.passed)

    def test_unresolved_reviewer_comment_blocks(self) -> None:
        result = evaluate_review_gate(
            good_snapshot(unresolved_comment_count=2)
        )
        self.assertIn(
            ReviewGateCode.COMMENTS_RESOLVED,
            {item.code for item in result.failures},
        )

    def test_each_claim_check_is_an_independent_gate(self) -> None:
        field_to_code = {
            "number_match": ReviewGateCode.CLAIM_NUMBER_MATCH,
            "citation_present": ReviewGateCode.CLAIM_CITATION,
            "status_echo": ReviewGateCode.CLAIM_STATUS_ECHO,
            "direction": ReviewGateCode.CLAIM_DIRECTION,
            "banned_wording_clear": ReviewGateCode.CLAIM_BANNED_WORDING,
            "scope": ReviewGateCode.CLAIM_SCOPE,
        }
        for field, expected_code in field_to_code.items():
            with self.subTest(field=field):
                result = evaluate_review_gate(
                    good_snapshot(claims=(good_claim(**{field: False}),))
                )
                failure = next(
                    item
                    for item in result.failures
                    if item.code == expected_code
                )
                self.assertEqual(failure.subject_ids, (CLAIM,))
                self.assertTrue(failure.remediation)

    def test_reviewer_must_be_independent_of_decision_makers(self) -> None:
        wrong_role = evaluate_review_gate(
            good_snapshot(signer_is_reviewer=False)
        )
        self.assertIn(
            ReviewGateCode.REVIEWER_INDEPENDENCE,
            {item.code for item in wrong_role.failures},
        )

        self_signed = evaluate_review_gate(
            good_snapshot(decision_maker_user_ids=(SIGNER,))
        )
        self.assertIn(
            ReviewGateCode.REVIEWER_INDEPENDENCE,
            {item.code for item in self_signed.failures},
        )

    def test_gate_failure_cannot_be_overridden(self) -> None:
        blocked = good_snapshot(unresolved_comment_count=1)
        with self.assertRaises(ReviewGateBlocked) as error:
            enforce_review_gate(blocked)
        self.assertFalse(error.exception.result.passed)

        with self.assertRaises(TypeError):
            enforce_review_gate(blocked, override=True)  # type: ignore[call-arg]

    def test_failures_are_actionable_and_stable(self) -> None:
        result = evaluate_review_gate(
            good_snapshot(
                reconciliation_failed=True,
                claims=(
                    good_claim(
                        decision_status="draft",
                        number_match=False,
                        citation_present=False,
                        status_echo=False,
                        direction=False,
                        banned_wording_clear=False,
                        scope=False,
                    ),
                ),
                act_decisions=(good_act(owner_present=False),),
                unresolved_comment_count=1,
                signer_is_reviewer=False,
            )
        )
        self.assertFalse(result.passed)
        self.assertTrue(all(item.message for item in result.failures))
        self.assertTrue(all(item.remediation for item in result.failures))
        self.assertEqual(
            [item.code for item in result.outcomes],
            list(ReviewGateCode),
        )

    def test_negative_comment_count_is_rejected(self) -> None:
        with self.assertRaises(ValueError):
            evaluate_review_gate(
                good_snapshot(unresolved_comment_count=-1)
            )


if __name__ == "__main__":
    unittest.main()
