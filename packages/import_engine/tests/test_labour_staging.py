from __future__ import annotations

from pathlib import Path
import unittest

from packages.import_engine import build_labour_staging_rows, parse_csv


FIXTURE = (
    Path(__file__).resolve().parents[3]
    / "fixtures"
    / "amberside"
    / "upload_files"
    / "Amberside_Labour_Jul2026.csv"
)


class LabourStagingTests(unittest.TestCase):
    def test_amberside_t5_binds_period_and_preserves_missing_basis(self) -> None:
        table = parse_csv(FIXTURE.name, FIXTURE.read_bytes()).tables[0]
        result = build_labour_staging_rows(
            table,
            template_code="T5",
            target_period="2026-07",
        )

        self.assertEqual(len(result.rows), 5)
        self.assertEqual(sum(bool(row.parse_errors) for row in result.rows), 0)

        dinner = result.rows[0].parsed
        self.assertEqual(dinner["period"], "2026-07")
        self.assertEqual(dinner["role_group"], "Dinner FOH")
        self.assertEqual(dinner["actual_hours"], "1100")
        self.assertEqual(dinner["comparator_hours"], "1030")
        self.assertEqual(dinner["overtime_hours"], "100")
        self.assertEqual(dinner["actual_cost"], "27000")
        self.assertEqual(dinner["comparator_cost"], "24850")
        self.assertEqual(dinner["activity_units"], "2390")
        self.assertEqual(dinner["comparator_scenario"], "budget")
        self.assertNotIn("activity_basis", dinner)

    def test_standard_t5_preserves_explicit_workload_basis(self) -> None:
        table = parse_csv(
            "labour.csv",
            (
                b"Period,Role_Group,Paid_Hours,Labour_Cost,"
                b"Workload_Units,Workload_Basis\n"
                b"2026-07,Dinner FOH,100,2400,300,dinner_covers\n"
            ),
        ).tables[0]
        result = build_labour_staging_rows(
            table,
            template_code="T5",
            target_period="2026-07",
        )
        self.assertEqual(
            result.rows[0].parsed["activity_basis"],
            "dinner_covers",
        )

    def test_negative_activity_units_are_blocking_parse_error(self) -> None:
        table = parse_csv(
            "bad.csv",
            (
                b"Role_Group,Paid_Hours,Labour_Cost,"
                b"Workload_Units,Workload_Basis\n"
                b"Kitchen,10,200,-2,total_covers\n"
            ),
        ).tables[0]
        result = build_labour_staging_rows(
            table,
            template_code="T5",
            target_period="2026-07",
        )
        self.assertEqual(result.rows[0].row_status, "error")
        self.assertTrue(
            any(
                error["code"] == "ACTIVITY_UNITS_NEGATIVE"
                for error in result.rows[0].parse_errors
            )
        )


if __name__ == "__main__":
    unittest.main()
