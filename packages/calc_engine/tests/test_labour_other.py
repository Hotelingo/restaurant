from __future__ import annotations

import csv
import unittest
from decimal import Decimal
from pathlib import Path

from packages.calc_engine import (
    LabourInput,
    OtherCostInput,
    calculate_labour,
    calculate_other_cost,
)


FIXTURE = (
    Path(__file__).resolve().parents[3]
    / "fixtures"
    / "amberside"
    / "upload_files"
    / "Amberside_Labour_Jul2026.csv"
)


def _by_id(results):
    return {result.calc_id: result for result in results}


class LabourEngineTests(unittest.TestCase):
    def test_amberside_role_groups_close_hours_plus_rate_to_total(self) -> None:
        activity_basis = {
            "Dinner FOH": "dinner_covers",
            "Kitchen prep": "total_covers",
            "Lunch FOH": "lunch_covers",
            "Bar": "brunch_plus_dinner_covers",
            "Management / shared": "total_covers",
        }
        expected_total = {
            "Dinner FOH": Decimal("2150"),
            "Kitchen prep": Decimal("2200"),
            "Lunch FOH": Decimal("900"),
            "Bar": Decimal("300"),
            "Management / shared": Decimal("-345"),
        }

        with FIXTURE.open(encoding="utf-8-sig", newline="") as fh:
            rows = list(csv.DictReader(fh))

        total_actual = Decimal("0")
        total_budget = Decimal("0")
        total_variance = Decimal("0")

        for index, row in enumerate(rows, start=1):
            results = _by_id(
                calculate_labour(
                    LabourInput(
                        grain_key=row["Area"],
                        actual_hours=Decimal(row["Paid_Hours"]),
                        comparator_hours=Decimal(row["Budget_Hours"]),
                        actual_cost=Decimal(row["Labour_Cost"]),
                        comparator_cost=Decimal(row["Budget_Labour_Cost"]),
                        currency="USD",
                        activity_units=Decimal(row["Covers_or_Orders"]),
                        activity_basis=activity_basis[row["Area"]],
                        overtime_hours=Decimal(row["Overtime_Hours"]),
                        input_refs=(f"t5:{index}",),
                    )
                )
            )

            self.assertEqual(
                results["LB.TOTAL_VARIANCE"].value,
                expected_total[row["Area"]],
            )
            self.assertEqual(
                results["LB.HOURS_EFFECT_RAW"].value
                + results["LB.RATE_EFFECT_RAW"].value,
                results["LB.TOTAL_VARIANCE"].value,
            )
            self.assertEqual(
                dict(results["LB.HOURS_PER_ACTIVITY"].metadata)[
                    "activity_basis"
                ],
                activity_basis[row["Area"]],
            )
            self.assertEqual(
                results["LB.OVERTIME_RATE_EFFECT"].calculation_status,
                "NOT_CALCULATED",
            )
            self.assertEqual(
                results["LB.OVERTIME_RATE_EFFECT"].explanation_code,
                "OVERTIME_RATE_EVIDENCE_MISSING",
            )
            self.assertNotIn(
                "OVERSTAFFED",
                {
                    result.value_text
                    for result in results.values()
                    if result.value_text
                },
            )

            total_actual += Decimal(row["Labour_Cost"])
            total_budget += Decimal(row["Budget_Labour_Cost"])
            total_variance += results["LB.TOTAL_VARIANCE"].value

        self.assertEqual(total_actual, Decimal("84317"))
        self.assertEqual(total_budget, Decimal("79112"))
        self.assertEqual(total_variance, Decimal("5205"))
        self.assertEqual(total_actual - total_budget, total_variance)

    def test_repeated_activity_basis_is_context_not_additive_units(self) -> None:
        kitchen = _by_id(
            calculate_labour(
                LabourInput(
                    grain_key="Kitchen prep",
                    actual_hours=Decimal("800"),
                    comparator_hours=Decimal("730"),
                    actual_cost=Decimal("20500"),
                    comparator_cost=Decimal("18300"),
                    activity_units=Decimal("5650"),
                    activity_basis="total_covers",
                    currency="USD",
                )
            )
        )
        management = _by_id(
            calculate_labour(
                LabourInput(
                    grain_key="Management / shared",
                    actual_hours=Decimal("430"),
                    comparator_hours=Decimal("410"),
                    actual_cost=Decimal("9817"),
                    comparator_cost=Decimal("10162"),
                    activity_units=Decimal("5650"),
                    activity_basis="total_covers",
                    currency="USD",
                )
            )
        )

        self.assertEqual(
            dict(kitchen["LB.COST_PER_ACTIVITY"].metadata)["activity_basis"],
            "total_covers",
        )
        self.assertEqual(
            dict(management["LB.COST_PER_ACTIVITY"].metadata)["activity_basis"],
            "total_covers",
        )
        self.assertEqual(kitchen["LB.HOURS_PER_ACTIVITY"].input_refs, ())
        self.assertEqual(management["LB.HOURS_PER_ACTIVITY"].input_refs, ())
        # The engine produces independent role-group ratios and no roll-up
        # activity result that could incorrectly turn 5,650 + 5,650 into 11,300.
        self.assertTrue(
            all(result.grain_key == "Kitchen prep" for result in kitchen.values())
        )
        self.assertTrue(
            all(
                result.grain_key == "Management / shared"
                for result in management.values()
            )
        )

    def test_activity_units_require_explicit_basis(self) -> None:
        with self.assertRaisesRegex(ValueError, "activity_basis is required"):
            LabourInput(
                grain_key="Dinner FOH",
                actual_hours=Decimal("10"),
                comparator_hours=Decimal("10"),
                actual_cost=Decimal("100"),
                comparator_cost=Decimal("100"),
                activity_units=Decimal("20"),
                activity_basis=None,
                currency="USD",
            )

    def test_zero_hours_are_not_calculated_not_zero_rates(self) -> None:
        results = _by_id(
            calculate_labour(
                LabourInput(
                    grain_key="Closed",
                    actual_hours=Decimal("0"),
                    comparator_hours=Decimal("0"),
                    actual_cost=Decimal("0"),
                    comparator_cost=Decimal("0"),
                    currency="USD",
                )
            )
        )
        self.assertEqual(
            results["LB.ACTUAL_RATE"].explanation_code,
            "ACTUAL_HOURS_ZERO",
        )
        self.assertEqual(
            results["LB.COMPARATOR_RATE"].explanation_code,
            "COMPARATOR_HOURS_ZERO",
        )
        self.assertEqual(
            results["LB.HOURS_EFFECT_RAW"].calculation_status,
            "NOT_CALCULATED",
        )
        self.assertEqual(results["LB.TOTAL_VARIANCE"].value, Decimal("0"))


class OtherCostEngineTests(unittest.TestCase):
    def test_quantity_rate_bridge_closes_exactly(self) -> None:
        results = _by_id(
            calculate_other_cost(
                OtherCostInput(
                    grain_key="utilities",
                    actual_cost=Decimal("720"),
                    comparator_cost=Decimal("500"),
                    actual_qty=Decimal("120"),
                    comparator_qty=Decimal("100"),
                    actual_rate=Decimal("6"),
                    comparator_rate=Decimal("5"),
                    currency="USD",
                    input_refs=("cost:utilities",),
                )
            )
        )

        self.assertEqual(
            results["OC.QUANTITY_EFFECT"].value,
            Decimal("100"),
        )
        self.assertEqual(
            results["OC.RATE_EFFECT"].value,
            Decimal("120"),
        )
        self.assertEqual(
            results["OC.TOTAL_VARIANCE"].value,
            Decimal("220"),
        )
        self.assertEqual(
            results["OC.QUANTITY_EFFECT"].value
            + results["OC.RATE_EFFECT"].value,
            results["OC.TOTAL_VARIANCE"].value,
        )
        self.assertEqual(
            results["OC.TOTAL_VARIANCE"].profit_effect,
            Decimal("-220"),
        )

    def test_total_variance_survives_without_quantity_rate_evidence(self) -> None:
        other_direct = _by_id(
            calculate_other_cost(
                OtherCostInput(
                    grain_key="other_direct_operating",
                    actual_cost=Decimal("2500"),
                    comparator_cost=Decimal("2300"),
                    currency="USD",
                )
            )
        )
        shared = _by_id(
            calculate_other_cost(
                OtherCostInput(
                    grain_key="shared_restaurant_costs",
                    actual_cost=Decimal("14252"),
                    comparator_cost=Decimal("12160"),
                    currency="USD",
                )
            )
        )

        self.assertEqual(
            other_direct["OC.TOTAL_VARIANCE"].value,
            Decimal("200"),
        )
        self.assertEqual(
            shared["OC.TOTAL_VARIANCE"].value,
            Decimal("2092"),
        )
        for results in (other_direct, shared):
            self.assertEqual(
                results["OC.QUANTITY_EFFECT"].calculation_status,
                "NOT_CALCULATED",
            )
            self.assertEqual(
                results["OC.RATE_EFFECT"].calculation_status,
                "NOT_CALCULATED",
            )
            self.assertEqual(
                results["OC.QUANTITY_EFFECT"].explanation_code,
                "QUANTITY_RATE_EVIDENCE_MISSING",
            )

    def test_inconsistent_quantity_rate_evidence_is_data_error(self) -> None:
        with self.assertRaisesRegex(
            ArithmeticError,
            "OC quantity/rate decomposition failed exact control identity",
        ):
            calculate_other_cost(
                OtherCostInput(
                    grain_key="utilities",
                    actual_cost=Decimal("700"),
                    comparator_cost=Decimal("500"),
                    actual_qty=Decimal("120"),
                    comparator_qty=Decimal("100"),
                    actual_rate=Decimal("6"),
                    comparator_rate=Decimal("5"),
                    currency="USD",
                )
            )


if __name__ == "__main__":
    unittest.main()
