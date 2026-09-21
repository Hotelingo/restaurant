from __future__ import annotations

from dataclasses import fields, replace
from decimal import Decimal
from pathlib import Path
import unittest

from packages.import_engine import parse_source
from packages.import_engine.validation import (
    DEFAULT_POS_PNL_TOLERANCE,
    DEFAULT_PURCHASES_PNL_TOLERANCE,
    ValidationResult,
    relative_difference,
    validate_non_negative_activity,
    validate_pos_to_pnl_sales,
    validate_purchases_to_pnl,
    validate_reconciliation,
    validate_stock_value,
    validation_gate,
)

ROOT = Path(__file__).resolve().parents[3]
FIXTURES = ROOT / "fixtures" / "amberside" / "upload_files"


def decimal_records(filename: str) -> tuple[dict[str, str], ...]:
    table = parse_source(filename, (FIXTURES / filename).read_bytes()).tables[0]
    return table.records()


class ValidationFrameworkTests(unittest.TestCase):
    def test_result_contract_contains_required_rule_fields(self) -> None:
        names = {field.name for field in fields(ValidationResult)}
        for required in {
            "rule_code",
            "severity",
            "scope",
            "actual",
            "expected",
            "tolerance",
            "message",
            "remediation",
        }:
            self.assertIn(required, names)

    def test_amberside_pos_to_pnl_food_and_beverage_reconcile_exactly(self) -> None:
        pos = decimal_records("Amberside_POS_ItemSales_Jul2026.csv")
        pnl = decimal_records("Amberside_PnL_Jul2026.csv")

        pos_totals = {"Food": Decimal("0"), "Beverage": Decimal("0")}
        for row in pos:
            bucket = "Beverage" if row["Population"] == "Beverages" else "Food"
            pos_totals[bucket] += Decimal(row["Net_Revenue"])

        pnl_totals = {
            "Food": next(Decimal(row["July_2026"]) for row in pnl if row["Account_Code"] == "4000"),
            "Beverage": next(Decimal(row["July_2026"]) for row in pnl if row["Account_Code"] == "4100"),
        }

        results = validate_pos_to_pnl_sales(
            pos_totals=pos_totals,
            pnl_totals=pnl_totals,
        )

        self.assertEqual(DEFAULT_POS_PNL_TOLERANCE, Decimal("0.005"))
        self.assertEqual(len(results), 2)
        for result in results:
            self.assertEqual(result.actual, result.expected)
            self.assertEqual(
                relative_difference(result.actual, result.expected),
                Decimal("0"),
            )
            self.assertEqual(result.severity, "info")
            self.assertEqual(result.capability_status, "reconciled")

    def test_pos_miss_above_tolerance_blocks_by_default(self) -> None:
        result = validate_pos_to_pnl_sales(
            pos_totals={"Food": Decimal("100")},
            pnl_totals={"Food": Decimal("90")},
        )[0]
        self.assertEqual(result.severity, "block")
        self.assertTrue(result.is_blocking)

    def test_tolerance_is_configurable_not_hard_wired_to_rule(self) -> None:
        result = validate_reconciliation(
            rule_code="CUSTOM",
            scope="Food",
            actual=Decimal("100"),
            expected=Decimal("90"),
            tolerance_ratio=Decimal("0.20"),
            failure_severity="block",
            message_label="Custom reconciliation",
            remediation="Review source.",
        )
        self.assertEqual(result.severity, "info")

    def test_missing_cross_file_total_is_not_reconciled(self) -> None:
        result = validate_purchases_to_pnl(
            purchases_total=Decimal("62900"),
            pnl_purchases_total=None,
            scope="Food",
        )
        self.assertEqual(DEFAULT_PURCHASES_PNL_TOLERANCE, Decimal("0.02"))
        self.assertEqual(result.severity, "info")
        self.assertEqual(result.capability_status, "not_reconciled")
        self.assertFalse(result.is_blocking)

    def test_purchases_difference_above_two_percent_warns(self) -> None:
        result = validate_purchases_to_pnl(
            purchases_total=Decimal("100"),
            pnl_purchases_total=Decimal("90"),
            scope="Food",
        )
        self.assertEqual(result.severity, "warn")
        self.assertEqual(result.capability_status, "reconciled")

    def test_negative_activity_units_block(self) -> None:
        result = validate_non_negative_activity(value="-1", scope="Dinner")
        self.assertEqual(result.severity, "block")
        self.assertTrue(result.is_blocking)

    def test_zero_activity_units_are_valid(self) -> None:
        result = validate_non_negative_activity(value="0", scope="Dinner")
        self.assertEqual(result.severity, "info")

    def test_unsupported_negative_stock_blocks(self) -> None:
        result = validate_stock_value(
            value="-10",
            scope="Food",
            field_name="closing_inventory",
        )
        self.assertEqual(result.severity, "block")
        self.assertTrue(result.is_blocking)

    def test_configured_negative_return_credit_is_allowed(self) -> None:
        result = validate_stock_value(
            value="-10",
            scope="Food",
            field_name="purchases",
            allow_negative_return_credit=True,
        )
        self.assertEqual(result.severity, "info")
        self.assertFalse(result.is_blocking)

    def test_unresolved_block_prevents_commit(self) -> None:
        blocked = validate_non_negative_activity(value="-2", scope="Lunch")
        warning = validate_purchases_to_pnl(
            purchases_total=Decimal("100"),
            pnl_purchases_total=Decimal("90"),
            scope="Food",
        )
        gate = validation_gate((blocked, warning))
        self.assertFalse(gate.can_commit)
        self.assertEqual(gate.unresolved_block_count, 1)

    def test_resolved_block_no_longer_prevents_commit(self) -> None:
        blocked = validate_non_negative_activity(value="-2", scope="Lunch")
        resolved = replace(
            blocked,
            resolved=True,
            resolution_note="Source corrected before final validation.",
        )
        gate = validation_gate((resolved,))
        self.assertTrue(gate.can_commit)
        self.assertEqual(gate.unresolved_block_count, 0)

    def test_zero_reference_is_not_silently_divided(self) -> None:
        self.assertEqual(
            relative_difference(Decimal("0"), Decimal("0")),
            Decimal("0"),
        )
        self.assertTrue(
            relative_difference(Decimal("1"), Decimal("0")).is_infinite()
        )


if __name__ == "__main__":
    unittest.main()
