from __future__ import annotations

from pathlib import Path
import unittest

from packages.import_engine import (
    build_food_cost_staging_rows,
    parse_csv,
)


FIXTURES = (
    Path(__file__).resolve().parents[3]
    / "fixtures"
    / "amberside"
    / "upload_files"
)


def _table(name: str):
    data=(FIXTURES / name).read_bytes()
    return parse_csv(name,data).tables[0]


class FoodCostStagingTests(unittest.TestCase):
    def test_t2_uses_selected_period_as_fixed_value(self) -> None:
        result=build_food_cost_staging_rows(
            _table("Amberside_POS_ItemSales_Jul2026.csv"),
            template_code="T2",
            target_period="2026-07",
        )
        self.assertEqual(len(result.rows),12)
        first=result.rows[0].parsed
        self.assertEqual(first["period"],"2026-07")
        self.assertEqual(first["item_code"],"F01")
        self.assertEqual(first["units_sold"],"900")
        self.assertEqual(first["net_revenue"],"40500.0")
        self.assertFalse(result.rows[0].parse_errors)

    def test_t3_never_canonicalises_fixture_expected_usage(self) -> None:
        result=build_food_cost_staging_rows(
            _table("Amberside_Stock_Jul2026.csv"),
            template_code="T3",
            target_period="2026-07",
        )
        self.assertEqual(len(result.rows),2)
        self.assertIn("Expected_Usage",result.ignored_source_fields)
        for row in result.rows:
            self.assertIn("Expected_Usage",row.raw)
            self.assertNotIn("expected_usage",row.parsed)
            self.assertIn("opening_inventory",row.parsed)
            self.assertIn("purchases",row.parsed)
            self.assertIn("closing_inventory",row.parsed)

    def test_t3_keeps_demo_revenue_and_budget_pct_as_source_context(self) -> None:
        result=build_food_cost_staging_rows(
            _table("Amberside_Stock_Jul2026.csv"),
            template_code="T3",
            target_period="2026-07",
        )
        food=result.rows[0].parsed
        self.assertEqual(food["source_product_revenue"],"191100")
        self.assertEqual(food["source_budget_cost_pct"],"0.3")
        self.assertNotIn("expected_usage",food)

    def test_t4a_requires_explicit_effective_date_default_for_fixture(self) -> None:
        without_default=build_food_cost_staging_rows(
            _table("Amberside_RecipeCosts.csv"),
            template_code="T4A",
            target_period="2026-07",
        )
        self.assertTrue(all(row.parse_errors for row in without_default.rows))
        self.assertTrue(
            all(
                any(error["code"]=="MISSING_EFFECTIVE_FROM" for error in row.parse_errors)
                for row in without_default.rows
            )
        )

        with_default=build_food_cost_staging_rows(
            _table("Amberside_RecipeCosts.csv"),
            template_code="T4A",
            target_period="2026-07",
            effective_from_default="2026-07-01",
        )
        self.assertEqual(len(with_default.rows),12)
        self.assertTrue(all(not row.parse_errors for row in with_default.rows))
        self.assertEqual(
            with_default.rows[0].parsed["effective_from"],
            "2026-07-01",
        )
        self.assertEqual(
            with_default.rows[0].parsed["effective_from_basis"],
            "fixed_default",
        )

    def test_negative_or_invalid_stock_values_remain_parseable_numbers_for_validation(self) -> None:
        table=_table("Amberside_Stock_Jul2026.csv")
        result=build_food_cost_staging_rows(
            table,
            template_code="T3",
            target_period="2026-07",
        )
        self.assertEqual(result.rows[0].parsed["opening_inventory"],"9800")


if __name__ == "__main__":
    unittest.main()
