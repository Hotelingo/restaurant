from __future__ import annotations

from decimal import Decimal
import unittest

from packages.calc_engine import (
    PL_LADDER,
    calculate_pl_ladder,
    calculate_pl_variances,
    quantize_money_for_presentation,
    ratio_result,
    results_by_code,
)


FULL_ACTUAL = {
    "NET_SALES": Decimal("228500"),
    "PRODUCT_COST": Decimal("70282"),
    "CHANNEL_COST": Decimal("3600"),
    "DIRECT_LABOUR": Decimal("84317"),
    "OTHER_DIRECT_OPERATING": Decimal("2500"),
    "SHARED_RESTAURANT_COST": Decimal("14252"),
    "OWNER_STRUCTURAL_COST": Decimal("26000"),
}

FULL_BUDGET = {
    "NET_SALES": Decimal("232000"),
    "PRODUCT_COST": Decimal("66908"),
    "CHANNEL_COST": Decimal("3300"),
    "DIRECT_LABOUR": Decimal("79112"),
    "OTHER_DIRECT_OPERATING": Decimal("2300"),
    "SHARED_RESTAURANT_COST": Decimal("12160"),
    "OWNER_STRUCTURAL_COST": Decimal("26000"),
}


class PLEngineTests(unittest.TestCase):
    def test_stable_ladder_has_exactly_eleven_calc_ids_in_order(self) -> None:
        self.assertEqual(
            [line.calc_id for line in PL_LADDER],
            [
                "PL.NET_SALES",
                "PL.PRODUCT_COST",
                "PL.PRODUCT_MARGIN",
                "PL.CHANNEL_COST",
                "PL.DIRECT_LABOUR",
                "PL.OTHER_DIRECT_OPERATING",
                "PL.CONTRIBUTION",
                "PL.SHARED_COST",
                "PL.OPERATING_PROFIT",
                "PL.OWNER_STRUCTURAL_COST",
                "PL.OWNER_RESULT",
            ],
        )

    def test_full_ladder_uses_exact_decimal_arithmetic(self) -> None:
        results = results_by_code(calculate_pl_ladder(FULL_ACTUAL, currency="USD"))
        self.assertEqual(results["PRODUCT_MARGIN"].value, Decimal("158218"))
        self.assertEqual(results["CONTRIBUTION"].value, Decimal("67801"))
        self.assertEqual(results["OPERATING_PROFIT"].value, Decimal("53549"))
        self.assertEqual(results["OWNER_RESULT"].value, Decimal("27549"))
        self.assertTrue(
            all(result.calculation_status == "CALCULATED" for result in results.values())
        )

    def test_missing_source_line_is_not_silently_zero(self) -> None:
        source = dict(FULL_ACTUAL)
        del source["SHARED_RESTAURANT_COST"]
        results = results_by_code(calculate_pl_ladder(source, currency="USD"))

        self.assertEqual(results["SHARED_RESTAURANT_COST"].calculation_status, "NOT_CALCULATED")
        self.assertEqual(results["SHARED_RESTAURANT_COST"].explanation_code, "INPUT_MISSING")
        self.assertIsNone(results["SHARED_RESTAURANT_COST"].value)
        self.assertEqual(results["OPERATING_PROFIT"].calculation_status, "NOT_CALCULATED")
        self.assertEqual(
            results["OPERATING_PROFIT"].explanation_code,
            "DEPENDENCY_NOT_CALCULATED",
        )
        self.assertEqual(results["OWNER_RESULT"].calculation_status, "NOT_CALCULATED")

    def test_money_inputs_must_be_decimal(self) -> None:
        source = dict(FULL_ACTUAL)
        source["NET_SALES"] = 228500  # type: ignore[assignment]
        with self.assertRaises(TypeError):
            calculate_pl_ladder(source, currency="USD")

    def test_variance_stores_raw_delta_and_profit_effect(self) -> None:
        actual = calculate_pl_ladder(FULL_ACTUAL, currency="USD")
        budget = calculate_pl_ladder(FULL_BUDGET, currency="USD")
        variance = results_by_code(
            calculate_pl_variances(actual, budget, currency="USD")
        )

        self.assertEqual(variance["OPERATING_PROFIT"].raw_delta, Decimal("-14671"))
        self.assertEqual(variance["OPERATING_PROFIT"].profit_effect, Decimal("-14671"))
        self.assertEqual(variance["OPERATING_PROFIT"].value, Decimal("-14671"))

        self.assertEqual(variance["PRODUCT_COST"].raw_delta, Decimal("3374"))
        self.assertEqual(variance["PRODUCT_COST"].profit_effect, Decimal("-3374"))
        self.assertEqual(variance["PRODUCT_COST"].value, Decimal("-3374"))

    def test_missing_comparator_is_explicit_not_calculated(self) -> None:
        actual = calculate_pl_ladder(FULL_ACTUAL, currency="USD")
        variance = calculate_pl_variances(actual, None, currency="USD")
        self.assertEqual(len(variance), 11)
        self.assertTrue(
            all(result.calculation_status == "NOT_CALCULATED" for result in variance)
        )
        self.assertTrue(
            all(result.explanation_code == "COMPARATOR_NOT_COMMITTED" for result in variance)
        )

    def test_ratio_zero_or_missing_denominator_is_never_numeric_zero(self) -> None:
        zero = ratio_result(
            calc_id="TEST.RATIO",
            grain_type="test",
            grain_key="zero",
            numerator=Decimal("1"),
            denominator=Decimal("0"),
        )
        missing = ratio_result(
            calc_id="TEST.RATIO",
            grain_type="test",
            grain_key="missing",
            numerator=Decimal("1"),
            denominator=None,
        )
        self.assertEqual(zero.calculation_status, "NOT_CALCULATED")
        self.assertEqual(zero.explanation_code, "DENOMINATOR_ZERO")
        self.assertIsNone(zero.value)
        self.assertEqual(missing.explanation_code, "DENOMINATOR_MISSING")

    def test_presentation_quantisation_is_explicit_and_half_up(self) -> None:
        source = dict(FULL_ACTUAL)
        source["NET_SALES"] = Decimal("228500.005")
        results = results_by_code(calculate_pl_ladder(source, currency="USD"))
        raw = results["NET_SALES"].value
        self.assertEqual(raw, Decimal("228500.005"))
        assert raw is not None
        self.assertEqual(
            quantize_money_for_presentation(raw, minor_unit=Decimal("0.01")),
            Decimal("228500.01"),
        )


if __name__ == "__main__":
    unittest.main()
