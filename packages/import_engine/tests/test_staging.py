from __future__ import annotations

from pathlib import Path
import unittest

from packages.import_engine import parse_source
from packages.import_engine.staging import (
    StagingError,
    build_financial_staging_rows,
)

ROOT = Path(__file__).resolve().parents[3]
FIXTURES = ROOT / "fixtures" / "amberside" / "upload_files"


class FinancialStagingTests(unittest.TestCase):
    def test_amberside_t1_stages_july_without_trusting_suggested_line(self) -> None:
        table = parse_source(
            "Amberside_PnL_Jul2026.csv",
            (FIXTURES / "Amberside_PnL_Jul2026.csv").read_bytes(),
        ).tables[0]
        result = build_financial_staging_rows(
            table,
            template_code="T1",
            target_period="2026-07",
        )

        self.assertEqual(len(result.rows), 15)
        first = result.rows[0]
        self.assertEqual(first.source_row_no, 2)
        self.assertEqual(first.parsed["account_code"], "4000")
        self.assertEqual(first.parsed["account_name"], "Food sales (net)")
        self.assertEqual(first.parsed["period"], "2026-07")
        self.assertEqual(first.parsed["amount"], "191100")
        self.assertNotIn("ladder_line", first.parsed)
        self.assertNotIn("suggested_management_line", first.parsed)
        self.assertEqual(first.row_status, "parsed")

    def test_amberside_t6_stages_ladder_identity_without_synthetic_account(self) -> None:
        table = parse_source(
            "Amberside_Budget_Jul2026.csv",
            (FIXTURES / "Amberside_Budget_Jul2026.csv").read_bytes(),
        ).tables[0]
        result = build_financial_staging_rows(
            table,
            template_code="T6",
            target_period="July 2026",
        )

        self.assertEqual(len(result.rows), 7)
        first = result.rows[0]
        self.assertEqual(first.parsed["management_line"], "Net Sales")
        self.assertEqual(first.parsed["amount"], "232000")
        self.assertNotIn("account_code", first.parsed)
        self.assertNotIn("account_name", first.parsed)

    def test_wide_source_contributes_only_target_month(self) -> None:
        from packages.import_engine.model import ParsedTable

        table = ParsedTable(
            source_name="multi.csv",
            sheet_name="__csv__",
            file_type="csv",
            encoding="utf-8",
            header_row=1,
            headers=("Account_Code", "Account_Name", "July_2026", "August_2026"),
            rows=(("4000", "Food sales", "100", "120"),),
            orientation="wide_months",
        )
        result = build_financial_staging_rows(
            table,
            template_code="T1",
            target_period="2026-08",
        )
        self.assertEqual(len(result.rows), 1)
        self.assertEqual(result.rows[0].parsed["amount"], "120")
        self.assertEqual(result.rows[0].parsed["period"], "2026-08")

    def test_long_form_rows_outside_target_period_are_not_staged(self) -> None:
        from packages.import_engine.model import ParsedTable

        table = ParsedTable(
            source_name="long.csv",
            sheet_name="__csv__",
            file_type="csv",
            encoding="utf-8",
            header_row=1,
            headers=("Period", "Account_Name", "Amount"),
            rows=(
                ("2026-07", "Sales", "100"),
                ("2026-08", "Sales", "120"),
            ),
            orientation="rows",
        )
        result = build_financial_staging_rows(
            table,
            template_code="T1",
            target_period="2026-07",
        )
        self.assertEqual(len(result.rows), 1)
        self.assertEqual(result.rows[0].parsed["amount"], "100")

    def test_invalid_amount_is_staged_as_blockable_error(self) -> None:
        from packages.import_engine.model import ParsedTable

        table = ParsedTable(
            source_name="bad.csv",
            sheet_name="__csv__",
            file_type="csv",
            encoding="utf-8",
            header_row=1,
            headers=("Account_Name", "July_2026"),
            rows=(("Sales", "not-money"),),
            orientation="wide_months",
        )
        result = build_financial_staging_rows(
            table,
            template_code="T1",
            target_period="2026-07",
        )
        self.assertEqual(result.rows[0].row_status, "error")
        self.assertEqual(result.rows[0].parse_errors[0]["code"], "INVALID_AMOUNT")
        self.assertNotIn("amount", result.rows[0].parsed)

    def test_missing_target_period_is_rejected(self) -> None:
        table = parse_source(
            "Amberside_PnL_Jul2026.csv",
            (FIXTURES / "Amberside_PnL_Jul2026.csv").read_bytes(),
        ).tables[0]
        with self.assertRaises(StagingError):
            build_financial_staging_rows(
                table,
                template_code="T1",
                target_period="2026-08",
            )


if __name__ == "__main__":
    unittest.main()
