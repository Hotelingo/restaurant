from __future__ import annotations

import csv
from decimal import Decimal
from pathlib import Path
import unittest

from packages.calc_engine.food_cost import (
    ExpectedUsageItem,
    FoodCostBridgeInput,
    FoodCostDriverImpact,
    calculate_decision_path,
    calculate_expected_usage,
    calculate_food_cost_bridge,
    calculate_residual,
    calculate_supported_driver_total,
)
from packages.calc_engine.materiality import MaterialitySnapshot


FIXTURES = (
    Path(__file__).resolve().parents[3]
    / "fixtures"
    / "amberside"
    / "upload_files"
)


def _read(name: str) -> list[dict[str, str]]:
    with open(FIXTURES / name, encoding="utf-8-sig", newline="") as fh:
        return list(csv.DictReader(fh))


def _d(value: str) -> Decimal:
    return Decimal(value.strip())


def _amberside_items() -> list[ExpectedUsageItem]:
    costs = {
        row["Item_Code"]: _d(row["Approved_Cost_per_Unit"])
        for row in _read("Amberside_RecipeCosts.csv")
    }
    return [
        ExpectedUsageItem(
            item_key=row["Item_Code"],
            product_group=(
                "Beverage" if row["Item_Code"].startswith("B") else "Food"
            ),
            units_sold=_d(row["Units"]),
            approved_cost_per_unit=costs[row["Item_Code"]],
            sales_refs=(f"T2:{row['Item_Code']}",),
            cost_refs=(f"T4A:{row['Item_Code']}",),
        )
        for row in _read("Amberside_POS_ItemSales_Jul2026.csv")
    ]


def _bridge(group: str):
    stock = {
        row["Product_Group"]: row
        for row in _read("Amberside_Stock_Jul2026.csv")
    }[group]
    expected = calculate_expected_usage(
        _amberside_items(),
        product_group=group,
        currency="USD",
    )
    results = calculate_food_cost_bridge(
        FoodCostBridgeInput(
            product_group=group,
            opening_inventory=_d(stock["Opening_Inventory"]),
            purchases=_d(stock["Purchases"]),
            closing_inventory=_d(stock["Closing_Inventory"]),
            product_revenue=_d(stock["Revenue"]),
            comparator_cost_pct=_d(stock["Budget_Cost_Pct"]),
            currency="USD",
            stock_refs=(f"T3:{group}",),
            revenue_refs=(f"T2:revenue:{group}",),
            comparator_refs=(f"benchmark:{group}",),
        ),
        expected_usage=expected,
    )
    return {result.calc_id: result for result in results}


def _materiality() -> MaterialitySnapshot:
    return MaterialitySnapshot(
        setting_id="food-demo-materiality",
        absolute_threshold=Decimal("1000"),
        percent_threshold=Decimal("0.10"),
        approved=True,
        risk_override_enabled=False,
    )


class FoodCostEngineTests(unittest.TestCase):
    def test_amberside_food_bridge_matches_golden_values(self) -> None:
        result = _bridge("Food")
        self.assertEqual(result["FC.ACTUAL_CONSUMPTION"].value, Decimal("61343"))
        self.assertEqual(result["FC.EXPECTED_USAGE"].value, Decimal("60400"))
        self.assertEqual(result["FC.ACTUAL_VS_EXPECTED"].value, Decimal("943"))
        self.assertEqual(result["FC.BUDGET_BENCHMARK"].value, Decimal("57330.0"))
        self.assertEqual(result["FC.BUDGET_GAP"].value, Decimal("4013.0"))
        self.assertEqual(result["FC.MENU_MIX_EFFECT"].value, Decimal("3070.0"))
        self.assertEqual(
            result["FC.ACTUAL_COST_PCT"].value,
            Decimal("61343") / Decimal("191100"),
        )
        self.assertEqual(
            result["FC.EXPECTED_COST_PCT"].value,
            Decimal("60400") / Decimal("191100"),
        )

    def test_amberside_beverage_bridge_matches_golden_values(self) -> None:
        result = _bridge("Beverage")
        self.assertEqual(result["FC.ACTUAL_CONSUMPTION"].value, Decimal("6439"))
        self.assertEqual(result["FC.EXPECTED_USAGE"].value, Decimal("6180"))
        self.assertEqual(result["FC.ACTUAL_VS_EXPECTED"].value, Decimal("259"))
        self.assertEqual(result["FC.BUDGET_BENCHMARK"].value, Decimal("6028.00"))
        self.assertEqual(result["FC.BUDGET_GAP"].value, Decimal("411.00"))
        self.assertEqual(result["FC.MENU_MIX_EFFECT"].value, Decimal("152.00"))

    def test_two_story_bridge_closes_exactly(self) -> None:
        for group in ("Food", "Beverage"):
            with self.subTest(group=group):
                result = _bridge(group)
                self.assertEqual(
                    result["FC.MENU_MIX_EFFECT"].value
                    + result["FC.ACTUAL_VS_EXPECTED"].value,
                    result["FC.BUDGET_GAP"].value,
                )

    def test_expected_usage_is_derived_from_t2_times_t4a_only(self) -> None:
        result = calculate_expected_usage(
            _amberside_items(),
            product_group="Food",
            currency="USD",
        )
        self.assertEqual(result.value, Decimal("60400"))
        self.assertEqual(dict(result.metadata)["derivation"], "T2_X_T4A")
        self.assertTrue(
            all(ref.startswith(("T2:", "T4A:")) for ref in result.input_refs)
        )

    def test_missing_item_cost_makes_expected_usage_not_calculated(self) -> None:
        items = list(_amberside_items())
        first = items[0]
        items[0] = ExpectedUsageItem(
            item_key=first.item_key,
            product_group=first.product_group,
            units_sold=first.units_sold,
            approved_cost_per_unit=None,
            sales_refs=first.sales_refs,
            cost_refs=first.cost_refs,
        )
        result = calculate_expected_usage(
            items,
            product_group="Food",
            currency="USD",
        )
        self.assertEqual(result.calculation_status, "NOT_CALCULATED")
        self.assertEqual(result.explanation_code, "ITEM_COST_MISSING")

    def test_amberside_food_routes_to_menu_economic_handoff_not_leakage(self) -> None:
        result = calculate_decision_path(
            tuple(_bridge("Food").values()),
            inventory_evidence_status="validated",
            materiality_snapshot=_materiality(),
        )
        self.assertEqual(result.value_text, "MENU_ECONOMIC_HANDOFF")
        metadata = dict(result.metadata)
        self.assertEqual(metadata["budget_gap_drives_branch"], "false")
        self.assertIn("amount_test", metadata["menu_mix_rules"])

    def test_amberside_beverage_has_no_material_gap(self) -> None:
        result = calculate_decision_path(
            tuple(_bridge("Beverage").values()),
            inventory_evidence_status="validated",
            materiality_snapshot=_materiality(),
        )
        self.assertEqual(result.value_text, "NO_MATERIAL_GAP")

    def test_decision_path_has_favourable_validation_branch(self) -> None:
        actual = _bridge("Food")
        ave = actual["FC.ACTUAL_VS_EXPECTED"]
        favourable = type(ave)(
            calc_id=ave.calc_id,
            grain_type=ave.grain_type,
            grain_key=ave.grain_key,
            value=Decimal("-2500"),
            unit=ave.unit,
            currency=ave.currency,
            calculation_status="CALCULATED",
            evidence_status=ave.evidence_status,
            explanation_code=None,
            input_refs=ave.input_refs,
        )
        results = [
            favourable if result.calc_id == "FC.ACTUAL_VS_EXPECTED" else result
            for result in actual.values()
        ]
        decision = calculate_decision_path(
            results,
            inventory_evidence_status="validated",
            materiality_snapshot=_materiality(),
        )
        self.assertEqual(decision.value_text, "FAVOURABLE_VALIDATE_DATA")

    def test_decision_path_uses_actual_vs_expected_not_budget_gap(self) -> None:
        food = _bridge("Food")
        self.assertEqual(food["FC.BUDGET_GAP"].value, Decimal("4013.0"))
        self.assertEqual(food["FC.ACTUAL_VS_EXPECTED"].value, Decimal("943"))
        decision = calculate_decision_path(
            tuple(food.values()),
            inventory_evidence_status="validated",
            materiality_snapshot=_materiality(),
        )
        self.assertNotEqual(
            decision.value_text,
            "OPERATING_CONTROL_INVESTIGATION",
        )
        self.assertEqual(decision.value_text, "MENU_ECONOMIC_HANDOFF")

    def test_decision_path_requires_validated_inventory_evidence(self) -> None:
        decision = calculate_decision_path(
            tuple(_bridge("Food").values()),
            inventory_evidence_status="supported",
            materiality_snapshot=_materiality(),
        )
        self.assertEqual(decision.value_text, "VALIDATE_FIRST")

    def test_decision_path_requires_confirmed_materiality(self) -> None:
        decision = calculate_decision_path(
            tuple(_bridge("Food").values()),
            inventory_evidence_status="validated",
            materiality_snapshot=None,
        )
        self.assertEqual(decision.value_text, "VALIDATE_FIRST")

    def test_supported_driver_total_excludes_unsupported_evidence(self) -> None:
        drivers = [
            FoodCostDriverImpact(
                driver_code="FC.DRIVER.WASTE",
                impact=Decimal("400"),
                evidence_status="validated",
                coverage_key="food:july:waste",
                input_refs=("evidence:waste",),
            ),
            FoodCostDriverImpact(
                driver_code="FC.DRIVER.YIELD",
                impact=Decimal("0"),
                evidence_status="evidence_required",
                coverage_key="food:july:yield",
                input_refs=("request:yield",),
            ),
        ]
        total = calculate_supported_driver_total(
            drivers,
            product_group="Food",
            currency="USD",
        )
        self.assertEqual(total.value, Decimal("400"))
        self.assertEqual(dict(total.metadata)["included_driver_count"], "1")

    def test_unsupported_driver_cannot_carry_an_amount(self) -> None:
        with self.assertRaisesRegex(
            ValueError,
            "unsupported driver evidence cannot carry a quantified impact",
        ):
            FoodCostDriverImpact(
                driver_code="FC.DRIVER.YIELD",
                impact=Decimal("125"),
                evidence_status="evidence_required",
                coverage_key="food:july:yield",
            )

    def test_overlapping_supported_driver_coverage_requires_override(self) -> None:
        drivers = [
            FoodCostDriverImpact(
                driver_code="FC.DRIVER.WASTE",
                impact=Decimal("300"),
                evidence_status="validated",
                coverage_key="food:july:line-a",
            ),
            FoodCostDriverImpact(
                driver_code="FC.DRIVER.PRODUCTION",
                impact=Decimal("200"),
                evidence_status="supported",
                coverage_key="food:july:line-a",
            ),
        ]
        with self.assertRaisesRegex(ValueError, "explicit reviewer override"):
            calculate_supported_driver_total(
                drivers,
                product_group="Food",
                currency="USD",
            )

        total = calculate_supported_driver_total(
            drivers,
            product_group="Food",
            currency="USD",
            overlap_override_reference="reviewer-override-42",
        )
        self.assertEqual(total.value, Decimal("500"))
        self.assertEqual(
            dict(total.metadata)["reviewer_override_reference"],
            "reviewer-override-42",
        )

    def test_residual_stays_visible_at_zero_positive_or_negative(self) -> None:
        ave = _bridge("Food")["FC.ACTUAL_VS_EXPECTED"]
        cases = (
            (Decimal("943"), Decimal("0")),
            (Decimal("400"), Decimal("543")),
            (Decimal("1200"), Decimal("-257")),
        )
        for driver_total, expected_residual in cases:
            with self.subTest(driver_total=driver_total):
                total = calculate_supported_driver_total(
                    [
                        FoodCostDriverImpact(
                            driver_code="FC.DRIVER.OTHER_SUPPORTED",
                            impact=driver_total,
                            evidence_status="supported",
                            coverage_key=f"food:test:{driver_total}",
                        )
                    ],
                    product_group="Food",
                    currency="USD",
                )
                residual = calculate_residual(ave, total, currency="USD")
                self.assertEqual(residual.calculation_status, "CALCULATED")
                self.assertEqual(residual.value, expected_residual)

    def test_missing_revenue_is_not_zero(self) -> None:
        expected = calculate_expected_usage(
            _amberside_items(),
            product_group="Food",
            currency="USD",
        )
        result = {
            item.calc_id: item
            for item in calculate_food_cost_bridge(
                FoodCostBridgeInput(
                    product_group="Food",
                    opening_inventory=Decimal("9800"),
                    purchases=Decimal("62900"),
                    closing_inventory=Decimal("11357"),
                    product_revenue=None,
                    comparator_cost_pct=Decimal("0.30"),
                    currency="USD",
                ),
                expected_usage=expected,
            )
        }
        self.assertEqual(
            result["FC.ACTUAL_COST_PCT"].calculation_status,
            "NOT_CALCULATED",
        )
        self.assertEqual(
            result["FC.ACTUAL_COST_PCT"].explanation_code,
            "DENOMINATOR_MISSING",
        )
        self.assertEqual(
            result["FC.BUDGET_BENCHMARK"].calculation_status,
            "NOT_CALCULATED",
        )
        self.assertIsNone(result["FC.BUDGET_BENCHMARK"].value)


if __name__ == "__main__":
    unittest.main()
