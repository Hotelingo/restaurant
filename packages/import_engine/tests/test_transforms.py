from __future__ import annotations

from datetime import date
from decimal import Decimal
from pathlib import Path
import unittest

from packages.import_engine import parse_source
from packages.import_engine.transforms import (
    CLOSED_TRANSFORM_CODES,
    TransformError,
    TransformSpec,
    apply_scalar_transform,
    apply_table_transform,
    case_normalization,
    controlled_uom_conversion,
    controlled_value_map,
    fixed_factor,
    fixed_value,
    parse_date,
    parse_month_label,
    remove_thousands_separators,
    sign_flip,
    split_delimited,
    tax_strip,
    trim_whitespace,
    unpivot_month_columns,
)

ROOT = Path(__file__).resolve().parents[3]
FIXTURES = ROOT / "fixtures" / "amberside" / "upload_files"


class ClosedTransformTests(unittest.TestCase):
    def test_registry_contains_exactly_thirteen_transforms(self) -> None:
        self.assertEqual(len(CLOSED_TRANSFORM_CODES), 13)

    def test_01_trim_whitespace(self) -> None:
        self.assertEqual(trim_whitespace("  Net Sales \t"), "Net Sales")

    def test_02_case_normalization(self) -> None:
        self.assertEqual(case_normalization(" Dine IN ", mode="casefold"), "dine in")
        self.assertEqual(case_normalization("food", mode="upper"), "FOOD")

    def test_03_remove_thousands_separators(self) -> None:
        self.assertEqual(remove_thousands_separators(" 1,234,567.80 "), "1234567.80")
        self.assertEqual(remove_thousands_separators("1\u202f234"), "1234")

    def test_04_sign_flip(self) -> None:
        self.assertEqual(sign_flip("1,250.50"), Decimal("-1250.50"))
        self.assertEqual(sign_flip("(12.00)"), Decimal("12.00"))

    def test_05_fixed_factor_multiply_and_divide(self) -> None:
        self.assertEqual(
            fixed_factor("2.5", factor="1000", operation="multiply"),
            Decimal("2500.0"),
        )
        self.assertEqual(
            fixed_factor("2500", factor="1000", operation="divide"),
            Decimal("2.5"),
        )
        with self.assertRaises(TransformError):
            fixed_factor("1", factor="0", operation="divide")

    def test_06_tax_strip(self) -> None:
        self.assertEqual(
            tax_strip("110", rate="0.10", basis="inclusive"),
            Decimal("100"),
        )
        self.assertEqual(
            tax_strip("100", rate="0.10", basis="exclusive"),
            Decimal("100"),
        )

    def test_07_parse_date(self) -> None:
        self.assertEqual(parse_date("21/09/2026"), date(2026, 9, 21))
        self.assertEqual(parse_date("2026-09-21"), date(2026, 9, 21))

    def test_08_parse_month_label(self) -> None:
        self.assertEqual(parse_month_label("July_2026"), "2026-07")
        self.assertEqual(parse_month_label("Budget_July_2026"), "2026-07")
        self.assertEqual(parse_month_label("2026-07"), "2026-07")

    def test_09_unpivot_month_columns_handles_wide_pnl(self) -> None:
        table = parse_source(
            "Amberside_PnL_Jul2026.csv",
            (FIXTURES / "Amberside_PnL_Jul2026.csv").read_bytes(),
        ).tables[0]

        rows = unpivot_month_columns(table)
        self.assertEqual(len(rows), 15)
        self.assertEqual(rows[0]["Account_Code"], "4000")
        self.assertEqual(rows[0]["Period"], "2026-07")
        self.assertEqual(rows[0]["Amount"], "191100")

    def test_10_split_delimited(self) -> None:
        self.assertEqual(
            split_delimited("Food | Dinner | Dine-in", delimiter="|", expected_parts=3),
            ("Food", "Dinner", "Dine-in"),
        )
        with self.assertRaises(TransformError):
            split_delimited("Food|Dinner", delimiter="|", expected_parts=3)

    def test_11_fixed_value_handles_wide_budget_scenario(self) -> None:
        table = parse_source(
            "Amberside_Budget_Jul2026.csv",
            (FIXTURES / "Amberside_Budget_Jul2026.csv").read_bytes(),
        ).tables[0]
        rows = unpivot_month_columns(table)
        enriched = tuple({**row, "Scenario": fixed_value(value="budget")} for row in rows)

        self.assertEqual(len(enriched), 7)
        self.assertEqual(enriched[0]["Period"], "2026-07")
        self.assertEqual(enriched[0]["Amount"], "232000")
        self.assertEqual(enriched[0]["Scenario"], "budget")

    def test_12_controlled_value_map(self) -> None:
        mapping = {"Bev": "Beverage", "Dine In": "Dine-in"}
        self.assertEqual(
            controlled_value_map(" bev ", mapping=mapping),
            "Beverage",
        )
        with self.assertRaises(TransformError):
            controlled_value_map("Unknown", mapping=mapping)

    def test_13_controlled_uom_conversion(self) -> None:
        conversions = {
            ("kg", "g"): Decimal("1000"),
            ("l", "ml"): Decimal("1000"),
        }
        self.assertEqual(
            controlled_uom_conversion(
                "2.5", from_uom="KG", to_uom="g", conversions=conversions
            ),
            Decimal("2500.0"),
        )
        with self.assertRaises(TransformError):
            controlled_uom_conversion(
                "2.5", from_uom="kg", to_uom="lb", conversions=conversions
            )

    def test_closed_dispatcher_rejects_unknown_code_and_no_callback_hook_exists(self) -> None:
        with self.assertRaises(TransformError):
            TransformSpec("python", {"callable": lambda value: value})

        self.assertEqual(
            apply_scalar_transform(
                "  bev ",
                TransformSpec(
                    "controlled_value_map",
                    {"mapping": {"bev": "Beverage"}},
                ),
            ),
            "Beverage",
        )

    def test_table_dispatcher_only_accepts_unpivot(self) -> None:
        table = parse_source(
            "Amberside_Budget_Jul2026.csv",
            (FIXTURES / "Amberside_Budget_Jul2026.csv").read_bytes(),
        ).tables[0]
        rows = apply_table_transform(
            table,
            TransformSpec("unpivot_month_columns"),
        )
        self.assertEqual(len(rows), 7)

        with self.assertRaises(TransformError):
            apply_table_transform(table, TransformSpec("trim_whitespace"))


if __name__ == "__main__":
    unittest.main()
