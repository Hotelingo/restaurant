from __future__ import annotations

from decimal import Decimal
import unittest
from uuid import UUID

from workers.pl_worker import (
    Claim,
    PreparedRun,
    WorkerDataError,
    aggregate_financial_facts,
    calculate_pl_bundle,
)


ACTUAL = {
    "NET_SALES": Decimal("228500"),
    "PRODUCT_COST": Decimal("70282"),
    "CHANNEL_COST": Decimal("3600"),
    "DIRECT_LABOUR": Decimal("84317"),
    "OTHER_DIRECT_OPERATING": Decimal("2500"),
    "SHARED_RESTAURANT_COST": Decimal("14252"),
    "OWNER_STRUCTURAL_COST": Decimal("26000"),
}

BUDGET = {
    "NET_SALES": Decimal("232000"),
    "PRODUCT_COST": Decimal("66908"),
    "CHANNEL_COST": Decimal("3300"),
    "DIRECT_LABOUR": Decimal("79112"),
    "OTHER_DIRECT_OPERATING": Decimal("2300"),
    "SHARED_RESTAURANT_COST": Decimal("12160"),
    "OWNER_STRUCTURAL_COST": Decimal("26000"),
}


def _refs(prefix: str, values: dict[str, Decimal]) -> dict[str, tuple[str, ...]]:
    return {
        code: (f"financial_fact:{prefix}-{index}",)
        for index, code in enumerate(values, start=1)
    }


def _prepared(*, with_comparator: bool) -> PreparedRun:
    claim = Claim(
        request_id=UUID("10000000-0000-0000-0000-000000000001"),
        organisation_id=UUID("10000000-0000-0000-0000-000000000002"),
        outlet_id=UUID("10000000-0000-0000-0000-000000000003"),
        period_id=UUID("10000000-0000-0000-0000-000000000004"),
        source_batch_id=UUID("10000000-0000-0000-0000-000000000005"),
        reason="unit-test",
        attempt_no=1,
    )
    return PreparedRun(
        run_id=UUID("10000000-0000-0000-0000-000000000006"),
        claim=claim,
        currency="USD",
        comparator_scenario="budget",
        actual_values=ACTUAL,
        actual_refs=_refs("a", ACTUAL),
        comparator_values=BUDGET if with_comparator else None,
        comparator_refs=_refs("b", BUDGET) if with_comparator else None,
        settings_snapshot={"primary_comparator": "budget"},
    )


class CalcWorkerUnitTests(unittest.TestCase):
    def test_aggregate_uses_canonical_codes_and_never_amounts_for_mapping(self) -> None:
        rows = [
            {
                "fact_id": "f2",
                "ladder_code": "NET_SALES",
                "amount": Decimal("28.50"),
            },
            {
                "fact_id": "f1",
                "ladder_code": "NET_SALES",
                "amount": Decimal("200.00"),
            },
            {
                "fact_id": "f3",
                "ladder_code": "PRODUCT_COST",
                "amount": Decimal("70.25"),
            },
        ]
        totals, refs = aggregate_financial_facts(rows)
        self.assertEqual(totals["NET_SALES"], Decimal("228.50"))
        self.assertEqual(totals["PRODUCT_COST"], Decimal("70.25"))
        self.assertEqual(
            refs["NET_SALES"],
            ("financial_fact:f1", "financial_fact:f2"),
        )

    def test_aggregate_rejects_calculated_destination(self) -> None:
        with self.assertRaises(WorkerDataError) as error:
            aggregate_financial_facts(
                [
                    {
                        "fact_id": "bad",
                        "ladder_code": "OPERATING_PROFIT",
                        "amount": Decimal("1"),
                    }
                ]
            )
        self.assertEqual(error.exception.code, "UNSUPPORTED_LADDER_CODE")

    def test_full_pl_bundle_contains_actual_comparator_and_variance(self) -> None:
        bundle = calculate_pl_bundle(_prepared(with_comparator=True))
        self.assertEqual(len(bundle.results), 33)
        self.assertEqual(len(bundle.dependencies), 42)
        self.assertRegex(bundle.result_hash, r"^[0-9a-f]{64}$")

        actual_op = next(
            result
            for result in bundle.results
            if result.category == "actual"
            and result.calc_id == "PL.OPERATING_PROFIT"
        )
        budget_op = next(
            result
            for result in bundle.results
            if result.category == "comparator"
            and result.calc_id == "PL.OPERATING_PROFIT"
        )
        variance_op = next(
            result
            for result in bundle.results
            if result.category == "variance"
            and result.calc_id == "PL.VAR.OPERATING_PROFIT"
        )

        self.assertEqual(actual_op.value_numeric, Decimal("53549.0000"))
        self.assertEqual(budget_op.value_numeric, Decimal("68220.0000"))
        self.assertEqual(variance_op.raw_delta, Decimal("-14671.0000"))
        self.assertEqual(variance_op.profit_effect, Decimal("-14671.0000"))
        self.assertEqual(variance_op.value_numeric, Decimal("-14671.0000"))

    def test_missing_comparator_is_persisted_as_not_calculated_not_zero(self) -> None:
        bundle = calculate_pl_bundle(_prepared(with_comparator=False))
        self.assertEqual(len(bundle.results), 22)
        variances = [result for result in bundle.results if result.category == "variance"]
        self.assertEqual(len(variances), 11)
        for result in variances:
            self.assertEqual(result.calculation_status, "NOT_CALCULATED")
            self.assertEqual(result.explanation_code, "COMPARATOR_NOT_COMMITTED")
            self.assertIsNone(result.value_numeric)
            self.assertIsNone(result.raw_delta)
            self.assertIsNone(result.profit_effect)

    def test_hash_is_stable_even_when_result_row_ids_change(self) -> None:
        first = calculate_pl_bundle(_prepared(with_comparator=True))
        second = calculate_pl_bundle(_prepared(with_comparator=True))
        self.assertNotEqual(
            {result.id for result in first.results},
            {result.id for result in second.results},
        )
        self.assertEqual(first.result_hash, second.result_hash)


if __name__ == "__main__":
    unittest.main()
