from __future__ import annotations

from pathlib import Path
import unittest

from packages.import_engine import (
    build_revenue_staging_rows,
    parse_csv,
)


FIXTURES = (
    Path(__file__).resolve().parents[3]
    / "fixtures"
    / "amberside"
    / "upload_files"
)


def _table(name: str):
    data = (FIXTURES / name).read_bytes()
    return parse_csv(data, filename=name).tables[0]


class RevenueStagingTests(unittest.TestCase):
    def test_amberside_t1b_binds_period_and_embedded_budget(self) -> None:
        result = build_revenue_staging_rows(
            _table("Amberside_MealPeriods_Jul2026.csv"),
            template_code="T1B",
            target_period="2026-07",
        )

        self.assertEqual(len(result.rows), 6)
        self.assertEqual(sum(bool(row.parse_errors) for row in result.rows), 0)

        brunch = result.rows[0].parsed
        self.assertEqual(brunch["period"], "2026-07")
        self.assertEqual(brunch["business_view_type"], "meal_period")
        self.assertEqual(brunch["business_view_key"], "Brunch")
        self.assertEqual(brunch["activity_units"], "700")
        self.assertEqual(brunch["activity_unit_type"], "covers")
        self.assertEqual(brunch["revenue"], "25900")
        self.assertEqual(brunch["source_avg_spend"], "37")
        self.assertEqual(brunch["comparator_activity_units"], "650")
        self.assertEqual(brunch["source_comparator_avg_spend"], "36")
        self.assertEqual(brunch["comparator_revenue"], "23400")

    def test_amberside_t7_binds_period_and_evidence_status(self) -> None:
        result = build_revenue_staging_rows(
            _table("Amberside_CustomerSource_Jul2026.csv"),
            template_code="T7",
            target_period="2026-07",
        )

        self.assertEqual(len(result.rows), 9)
        self.assertEqual(sum(bool(row.parse_errors) for row in result.rows), 0)

        direct = result.rows[0].parsed
        self.assertEqual(direct["period"], "2026-07")
        self.assertEqual(direct["source_channel"], "Direct / Walk-in")
        self.assertEqual(direct["attributed_revenue"], "67000")
        self.assertEqual(direct["direct_channel_cost"], "0")
        self.assertEqual(direct["source_evidence_status"], "partly_supported")

        missing = result.rows[-1].parsed
        self.assertEqual(missing["source_channel"], "Not attributed")
        self.assertEqual(
            missing["source_evidence_status"],
            "evidence_required",
        )

    def test_t1b_negative_units_are_blocking_parse_error(self) -> None:
        table = parse_csv(
            b"Meal_Period,Units,Unit_Basis,Revenue\nLunch,-2,covers,100\n",
            filename="negative.csv",
        ).tables[0]

        result = build_revenue_staging_rows(
            table,
            template_code="T1B",
            target_period="2026-07",
        )
        self.assertEqual(result.rows[0].row_status, "error")
        self.assertEqual(
            result.rows[0].parse_errors[0]["code"],
            "ACTIVITY_UNITS_NEGATIVE",
        )

    def test_t7_requires_measure(self) -> None:
        table = parse_csv(
            b"Customer_Source,Revenue,Channel_Cost\nWalk-in,,0\n",
            filename="missing.csv",
        ).tables[0]

        result = build_revenue_staging_rows(
            table,
            template_code="T7",
            target_period="2026-07",
        )
        self.assertEqual(result.rows[0].row_status, "error")
        self.assertEqual(
            result.rows[0].parse_errors[0]["code"],
            "MISSING_T7_MEASURE",
        )


if __name__ == "__main__":
    unittest.main()
