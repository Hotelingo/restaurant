from __future__ import annotations

from decimal import Decimal
import unittest

from packages.calc_engine import (
    MaterialitySnapshot,
    calculate_pl_ladder,
    calculate_pl_variances,
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
    absolute: str | None,
    percent: str | None,
    approved: bool = True,
    risk_enabled: bool = False,
) -> MaterialitySnapshot:
    return MaterialitySnapshot(
        setting_id="mat-general-v1",
        absolute_threshold=Decimal(absolute) if absolute is not None else None,
        percent_threshold=Decimal(percent) if percent is not None else None,
        approved=approved,
        risk_override_enabled=risk_enabled,
    )


def _pl():
    actual = calculate_pl_ladder(ACTUAL, currency="USD")
    budget = calculate_pl_ladder(BUDGET, currency="USD")
    variance = calculate_pl_variances(actual, budget, currency="USD")
    return actual, budget, variance


def _metadata(result) -> dict[str, str]:
    return dict(result.metadata)


class FirstMaterialMovementTests(unittest.TestCase):
    def test_amount_rule_returns_first_ladder_movement_and_impact(self) -> None:
        _, budget, variance = _pl()
        result = first_material_movement(
            variance,
            budget,
            materiality_snapshot=_snapshot(absolute="1000", percent="0.10"),
        )

        self.assertEqual(result.calculation_status, "CALCULATED")
        self.assertEqual(result.value_text, "NET_SALES")
        self.assertIsNone(result.value)
        metadata = _metadata(result)
        self.assertEqual(metadata["materiality_reason"], "amount_test")
        self.assertEqual(metadata["matched_rules"], "amount_test")
        self.assertEqual(metadata["impact"], "-3500")
        self.assertEqual(metadata["raw_delta"], "-3500")
        self.assertEqual(metadata["selection_basis"], "materiality_only")

    def test_percentage_rule_uses_individual_comparator_line_and_ladder_order(self) -> None:
        _, budget, variance = _pl()
        result = first_material_movement(
            variance,
            budget,
            materiality_snapshot=_snapshot(absolute="1000000", percent="0.10"),
        )

        self.assertEqual(result.value_text, "CONTRIBUTION")
        metadata = _metadata(result)
        self.assertEqual(metadata["materiality_reason"], "percentage_test")
        self.assertEqual(metadata["matched_rules"], "percentage_test")
        self.assertGreater(Decimal(metadata["percentage_ratio"]), Decimal("0.10"))

    def test_recurrence_override_is_an_explicit_or_rule(self) -> None:
        _, budget, variance = _pl()
        result = first_material_movement(
            variance,
            budget,
            materiality_snapshot=_snapshot(absolute="1000000", percent="1"),
            recurrence_overrides=frozenset({"CHANNEL_COST"}),
        )

        self.assertEqual(result.value_text, "CHANNEL_COST")
        self.assertEqual(_metadata(result)["materiality_reason"], "recurrence_override")

    def test_risk_override_requires_the_snapshot_switch(self) -> None:
        _, budget, variance = _pl()

        disabled = first_material_movement(
            variance,
            budget,
            materiality_snapshot=_snapshot(
                absolute="1000000",
                percent="1",
                risk_enabled=False,
            ),
            risk_overrides=frozenset({"DIRECT_LABOUR"}),
        )
        self.assertEqual(disabled.value_text, "NO_MATERIAL_MOVEMENT")

        enabled = first_material_movement(
            variance,
            budget,
            materiality_snapshot=_snapshot(
                absolute="1000000",
                percent="1",
                risk_enabled=True,
            ),
            risk_overrides=frozenset({"DIRECT_LABOUR"}),
        )
        self.assertEqual(enabled.value_text, "DIRECT_LABOUR")
        self.assertEqual(_metadata(enabled)["materiality_reason"], "risk_override")

    def test_all_matching_rules_are_recorded_with_deterministic_primary_reason(self) -> None:
        _, budget, variance = _pl()
        result = first_material_movement(
            variance,
            budget,
            materiality_snapshot=_snapshot(absolute="1000", percent="0.01"),
            recurrence_overrides=frozenset({"NET_SALES"}),
        )

        metadata = _metadata(result)
        self.assertEqual(result.value_text, "NET_SALES")
        self.assertEqual(metadata["materiality_reason"], "amount_test")
        self.assertEqual(
            metadata["matched_rules"],
            "amount_test|percentage_test|recurrence_override",
        )

    def test_no_material_movement_is_a_calculated_categorical_state(self) -> None:
        _, budget, variance = _pl()
        result = first_material_movement(
            variance,
            budget,
            materiality_snapshot=_snapshot(absolute="1000000", percent="1"),
        )

        self.assertEqual(result.calculation_status, "CALCULATED")
        self.assertEqual(result.value_text, "NO_MATERIAL_MOVEMENT")
        self.assertEqual(_metadata(result)["material"], "false")
        self.assertEqual(_metadata(result)["materiality_reason"], "")

    def test_materiality_must_be_present_and_confirmed(self) -> None:
        _, budget, variance = _pl()

        missing = first_material_movement(
            variance,
            budget,
            materiality_snapshot=None,
        )
        self.assertEqual(missing.calculation_status, "NOT_CALCULATED")
        self.assertEqual(missing.explanation_code, "MATERIALITY_UNSET")

        unconfirmed = first_material_movement(
            variance,
            budget,
            materiality_snapshot=_snapshot(
                absolute="1000",
                percent="0.10",
                approved=False,
            ),
        )
        self.assertEqual(unconfirmed.calculation_status, "NOT_CALCULATED")
        self.assertEqual(unconfirmed.explanation_code, "MATERIALITY_UNCONFIRMED")

    def test_missing_comparator_is_not_a_false_no_movement(self) -> None:
        actual = calculate_pl_ladder(ACTUAL, currency="USD")
        variance = calculate_pl_variances(actual, None, currency="USD")
        result = first_material_movement(
            variance,
            None,
            materiality_snapshot=_snapshot(absolute="1000", percent="0.10"),
        )
        self.assertEqual(result.calculation_status, "NOT_CALCULATED")
        self.assertEqual(result.explanation_code, "COMPARATOR_NOT_COMMITTED")
        self.assertIsNone(result.value)
        self.assertIsNone(result.value_text)

    def test_zero_comparator_line_does_not_divide_by_zero(self) -> None:
        zero_budget = dict(BUDGET)
        zero_budget["NET_SALES"] = Decimal("0")
        actual = calculate_pl_ladder(ACTUAL, currency="USD")
        budget = calculate_pl_ladder(zero_budget, currency="USD")
        variance = calculate_pl_variances(actual, budget, currency="USD")

        result = first_material_movement(
            variance,
            budget,
            materiality_snapshot=_snapshot(absolute="1000000", percent="1"),
        )
        self.assertEqual(result.calculation_status, "CALCULATED")
        # The zero denominator on Net Sales cannot trigger percentage materiality.
        self.assertNotEqual(result.value_text, "NET_SALES")

    def test_output_contract_has_no_operating_cause_field_or_label(self) -> None:
        _, budget, variance = _pl()
        result = first_material_movement(
            variance,
            budget,
            materiality_snapshot=_snapshot(absolute="1000", percent="0.10"),
        )
        metadata = _metadata(result)
        forbidden_keys = {"cause", "driver", "diagnosis", "root_cause"}
        self.assertTrue(forbidden_keys.isdisjoint(metadata))
        self.assertEqual(metadata["selection_basis"], "materiality_only")


if __name__ == "__main__":
    unittest.main()
