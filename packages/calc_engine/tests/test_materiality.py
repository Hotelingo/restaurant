from __future__ import annotations

from decimal import Decimal
import unittest

from packages.calc_engine import (
    MaterialityOverrides,
    MaterialitySnapshot,
    calculate_pl_ladder,
    calculate_pl_variances,
    evaluate_materiality,
    first_material_movement,
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


def _snapshot(
    *,
    absolute: str | None = "1000",
    percentage: str | None = "0.10",
    confirmed: bool = True,
    risk_enabled: bool = True,
) -> MaterialitySnapshot:
    return MaterialitySnapshot(
        snapshot_id="mat-general-v1",
        absolute_threshold=Decimal(absolute) if absolute is not None else None,
        percentage_threshold=Decimal(percentage) if percentage is not None else None,
        confirmed=confirmed,
        risk_override_enabled=risk_enabled,
        source_kind="user_confirmed",
    )


class MaterialityTests(unittest.TestCase):
    def test_amberside_first_material_movement_is_net_sales_by_amount(self) -> None:
        actual = calculate_pl_ladder(ACTUAL, currency="USD")
        budget = calculate_pl_ladder(BUDGET, currency="USD")
        variance = calculate_pl_variances(actual, budget, currency="USD")

        result = first_material_movement(
            variance,
            budget,
            snapshot=_snapshot(),
        )

        self.assertEqual(result.calculation_status, "CALCULATED")
        self.assertEqual(result.first_ladder_code, "NET_SALES")
        self.assertEqual(result.impact, Decimal("-3500"))
        self.assertEqual(result.materiality_reasons, ("amount_test",))
        self.assertEqual(result.evaluated_line_codes, ("NET_SALES",))
        self.assertEqual(result.materiality_snapshot_id, "mat-general-v1")

    def test_percentage_rule_is_exact_and_uses_absolute_comparator(self) -> None:
        evaluation = evaluate_materiality(
            line_code="NET_SALES",
            impact=Decimal("-3500"),
            comparator_value=Decimal("232000"),
            snapshot=_snapshot(absolute="10000", percentage="0.01"),
        )
        self.assertTrue(evaluation.material)
        self.assertEqual(evaluation.reasons, ("percentage_test",))
        self.assertEqual(
            evaluation.movement_pct,
            Decimal("3500") / Decimal("232000"),
        )

    def test_all_triggered_rules_are_retained_in_stable_order(self) -> None:
        evaluation = evaluate_materiality(
            line_code="PRODUCT_COST",
            impact=Decimal("-3374"),
            comparator_value=Decimal("66908"),
            snapshot=_snapshot(absolute="1000", percentage="0.01"),
            overrides=MaterialityOverrides(
                recurrence_override=True,
                risk_override=True,
            ),
        )
        self.assertEqual(
            evaluation.reasons,
            (
                "amount_test",
                "percentage_test",
                "recurrence_override",
                "risk_override",
            ),
        )

    def test_zero_comparator_does_not_turn_percentage_into_zero(self) -> None:
        evaluation = evaluate_materiality(
            line_code="NET_SALES",
            impact=Decimal("500"),
            comparator_value=Decimal("0"),
            snapshot=_snapshot(absolute="1000", percentage="0.01"),
        )
        self.assertFalse(evaluation.material)
        self.assertIsNone(evaluation.movement_pct)
        self.assertEqual(evaluation.reasons, ())

    def test_risk_override_requires_snapshot_permission(self) -> None:
        evaluation = evaluate_materiality(
            line_code="NET_SALES",
            impact=Decimal("1"),
            comparator_value=Decimal("1000"),
            snapshot=_snapshot(
                absolute="10000",
                percentage="0.50",
                risk_enabled=False,
            ),
            overrides=MaterialityOverrides(risk_override=True),
        )
        self.assertFalse(evaluation.material)

    def test_recurrence_override_can_make_small_movement_material(self) -> None:
        evaluation = evaluate_materiality(
            line_code="NET_SALES",
            impact=Decimal("1"),
            comparator_value=Decimal("1000"),
            snapshot=_snapshot(absolute="10000", percentage="0.50"),
            overrides=MaterialityOverrides(recurrence_override=True),
        )
        self.assertEqual(evaluation.reasons, ("recurrence_override",))

    def test_unconfirmed_snapshot_blocks_sequence(self) -> None:
        actual = calculate_pl_ladder(ACTUAL, currency="USD")
        budget = calculate_pl_ladder(BUDGET, currency="USD")
        variance = calculate_pl_variances(actual, budget, currency="USD")

        result = first_material_movement(
            variance,
            budget,
            snapshot=_snapshot(confirmed=False),
        )
        self.assertEqual(result.calculation_status, "NOT_CALCULATED")
        self.assertEqual(result.explanation_code, "MATERIALITY_NOT_CONFIRMED")
        self.assertIsNone(result.first_ladder_code)

    def test_no_comparator_produces_no_calculated_variances(self) -> None:
        actual = calculate_pl_ladder(ACTUAL, currency="USD")
        variance = calculate_pl_variances(actual, None, currency="USD")
        result = first_material_movement(
            variance,
            None,
            snapshot=_snapshot(),
        )
        self.assertEqual(result.calculation_status, "NOT_CALCULATED")
        self.assertEqual(result.explanation_code, "NO_CALCULATED_VARIANCES")

    def test_no_material_movement_is_a_calculated_outcome_not_zero(self) -> None:
        actual = calculate_pl_ladder(ACTUAL, currency="USD")
        budget = calculate_pl_ladder(BUDGET, currency="USD")
        variance = calculate_pl_variances(actual, budget, currency="USD")
        result = first_material_movement(
            variance,
            budget,
            snapshot=_snapshot(absolute="999999", percentage="9"),
        )
        self.assertEqual(result.calculation_status, "CALCULATED")
        self.assertIsNone(result.first_ladder_code)
        self.assertIsNone(result.impact)
        self.assertEqual(result.materiality_reasons, ())
        self.assertEqual(len(result.evaluated_line_codes), 11)


if __name__ == "__main__":
    unittest.main()
