from __future__ import annotations

import csv
import unittest
from decimal import Decimal
from pathlib import Path

from packages.calc_engine import (
    ContributionInput,
    RevenueVarianceInput,
    calculate_contribution,
    calculate_revenue_variance,
)


FIXTURES = (
    Path(__file__).resolve().parents[3]
    / "fixtures"
    / "amberside"
    / "upload_files"
)


def _by_id(results):
    return {result.calc_id: result for result in results}


class RevenueEngineTests(unittest.TestCase):
    def test_amberside_meal_period_volume_spend_decomposition(self) -> None:
        expected = {
            "Brunch": (Decimal("1800"), Decimal("700"), Decimal("2500")),
            "Lunch": (Decimal("-5270"), Decimal("0"), Decimal("-5270")),
            "Dinner": (Decimal("-2820"), Decimal("2390"), Decimal("-430")),
            "Delivery / Takeaway": (
                Decimal("1800"),
                Decimal("0"),
                Decimal("1800"),
            ),
            "Private Event": (
                Decimal("-560"),
                Decimal("-960"),
                Decimal("-1520"),
            ),
            "Corporate / Group": (
                Decimal("-310"),
                Decimal("-270"),
                Decimal("-580"),
            ),
        }

        with open(
            FIXTURES / "Amberside_MealPeriods_Jul2026.csv",
            encoding="utf-8-sig",
            newline="",
        ) as fh:
            rows = list(csv.DictReader(fh))

        total_volume = Decimal("0")
        total_spend = Decimal("0")
        total_variance = Decimal("0")

        for row in rows:
            results = _by_id(
                calculate_revenue_variance(
                    RevenueVarianceInput(
                        grain_key=row["Meal_Period"],
                        activity_unit_type=row["Unit_Basis"],
                        actual_units=Decimal(row["Units"]),
                        actual_revenue=Decimal(row["Revenue"]),
                        comparator_units=Decimal(row["Budget_Units"]),
                        comparator_revenue=Decimal(row["Budget_Revenue"]),
                        currency="USD",
                        actual_refs=(f"t1b:{row['Meal_Period']}:actual",),
                        comparator_refs=(f"t1b:{row['Meal_Period']}:budget",),
                    )
                )
            )

            volume, spend, variance = expected[row["Meal_Period"]]
            self.assertEqual(results["RV.VOLUME_EFFECT"].value, volume)
            self.assertEqual(results["RV.SPEND_EFFECT"].value, spend)
            self.assertEqual(results["RV.TOTAL_VARIANCE"].value, variance)
            self.assertEqual(
                results["RV.VOLUME_EFFECT"].value
                + results["RV.SPEND_EFFECT"].value,
                results["RV.TOTAL_VARIANCE"].value,
            )
            self.assertEqual(
                results["RV.AVG_SPEND"].value,
                Decimal(row["Revenue"]) / Decimal(row["Units"]),
            )

            total_volume += volume
            total_spend += spend
            total_variance += variance

        self.assertEqual(total_volume, Decimal("-5360"))
        self.assertEqual(total_spend, Decimal("1860"))
        self.assertEqual(total_variance, Decimal("-3500"))
        self.assertEqual(total_volume + total_spend, total_variance)

    def test_zero_activity_does_not_manufacture_average_spend(self) -> None:
        results = _by_id(
            calculate_revenue_variance(
                RevenueVarianceInput(
                    grain_key="closed-period",
                    activity_unit_type="covers",
                    actual_units=Decimal("0"),
                    actual_revenue=Decimal("0"),
                    comparator_units=Decimal("100"),
                    comparator_revenue=Decimal("3000"),
                    currency="USD",
                )
            )
        )

        self.assertEqual(
            results["RV.AVG_SPEND"].calculation_status,
            "NOT_CALCULATED",
        )
        self.assertEqual(
            results["RV.AVG_SPEND"].explanation_code,
            "ACTIVITY_UNITS_ZERO",
        )
        self.assertEqual(results["RV.TOTAL_VARIANCE"].value, Decimal("-3000"))
        self.assertEqual(results["RV.VOLUME_EFFECT"].value, Decimal("-3000"))
        self.assertEqual(results["RV.SPEND_EFFECT"].value, Decimal("0"))

    def test_missing_comparator_is_explicit_not_calculated(self) -> None:
        results = _by_id(
            calculate_revenue_variance(
                RevenueVarianceInput(
                    grain_key="brunch",
                    activity_unit_type="covers",
                    actual_units=Decimal("700"),
                    actual_revenue=Decimal("25900"),
                    comparator_units=None,
                    comparator_revenue=None,
                    currency="USD",
                )
            )
        )

        for calc_id in (
            "RV.VOLUME_EFFECT",
            "RV.SPEND_EFFECT",
            "RV.TOTAL_VARIANCE",
        ):
            self.assertEqual(results[calc_id].calculation_status, "NOT_CALCULATED")
            self.assertEqual(
                results[calc_id].explanation_code,
                "COMPARATOR_NOT_COMMITTED",
            )

    def test_activity_units_cannot_be_negative(self) -> None:
        with self.assertRaisesRegex(ValueError, "actual_units cannot be negative"):
            RevenueVarianceInput(
                grain_key="dinner",
                activity_unit_type="covers",
                actual_units=Decimal("-1"),
                actual_revenue=Decimal("10"),
                comparator_units=Decimal("1"),
                comparator_revenue=Decimal("10"),
                currency="USD",
            )


class ContributionEngineTests(unittest.TestCase):
    def test_amberside_outlet_contribution_matches_management_pl(self) -> None:
        results = _by_id(
            calculate_contribution(
                ContributionInput(
                    grain_key="outlet",
                    net_sales=Decimal("228500"),
                    direct_channel_cost=Decimal("3600"),
                    product_cost=Decimal("70282"),
                    direct_labour=Decimal("84317"),
                    other_direct_operating_cost=Decimal("2500"),
                    activity_units=Decimal("5650"),
                    currency="USD",
                    input_refs=("pl:jul-2026",),
                )
            )
        )

        self.assertEqual(
            results["CT.CONTRIBUTION"].value,
            Decimal("67801"),
        )
        self.assertEqual(
            results["CT.CONTRIBUTION_PER_ACTIVITY_UNIT"].value,
            Decimal("67801") / Decimal("5650"),
        )
        self.assertEqual(
            results["CT.CONTRIBUTION_MARGIN_PCT"].value,
            Decimal("67801") / Decimal("228500"),
        )
        self.assertEqual(
            dict(results["CT.CONTRIBUTION"].metadata)[
                "shared_overhead_allocated"
            ],
            "false",
        )

    def test_missing_direct_cost_blocks_contribution_not_as_zero(self) -> None:
        results = _by_id(
            calculate_contribution(
                ContributionInput(
                    grain_key="dinner",
                    net_sales=Decimal("114720"),
                    direct_channel_cost=None,
                    product_cost=Decimal("30000"),
                    direct_labour=Decimal("20000"),
                    other_direct_operating_cost=Decimal("1000"),
                    activity_units=Decimal("2390"),
                    currency="USD",
                )
            )
        )

        self.assertEqual(
            results["CT.CONTRIBUTION"].calculation_status,
            "NOT_CALCULATED",
        )
        self.assertEqual(
            results["CT.CONTRIBUTION"].explanation_code,
            "DIRECT_CHANNEL_COST_MISSING",
        )
        self.assertIsNone(results["CT.CONTRIBUTION"].value)
        self.assertEqual(
            results["CT.CONTRIBUTION_MARGIN_PCT"].calculation_status,
            "NOT_CALCULATED",
        )

    def test_zero_net_sales_keeps_margin_not_calculated(self) -> None:
        results = _by_id(
            calculate_contribution(
                ContributionInput(
                    grain_key="test",
                    net_sales=Decimal("0"),
                    direct_channel_cost=Decimal("0"),
                    product_cost=Decimal("0"),
                    direct_labour=Decimal("0"),
                    other_direct_operating_cost=Decimal("0"),
                    activity_units=Decimal("1"),
                    currency="USD",
                )
            )
        )

        self.assertEqual(results["CT.CONTRIBUTION"].value, Decimal("0"))
        self.assertEqual(
            results["CT.CONTRIBUTION_MARGIN_PCT"].calculation_status,
            "NOT_CALCULATED",
        )
        self.assertEqual(
            results["CT.CONTRIBUTION_MARGIN_PCT"].explanation_code,
            "NET_SALES_ZERO",
        )


if __name__ == "__main__":
    unittest.main()
