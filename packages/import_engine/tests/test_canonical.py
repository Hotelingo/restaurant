from __future__ import annotations

from collections import defaultdict
from decimal import Decimal
from pathlib import Path
import unittest

from packages.import_engine import parse_source
from packages.import_engine.canonical import (
    CanonicalisationError,
    build_account_grain_financial_drafts,
    build_ladder_grain_comparator_drafts,
)
from packages.import_engine.mapping import AccountMappingRule

ROOT = Path(__file__).resolve().parents[3]
FIXTURES = ROOT / "fixtures" / "amberside" / "upload_files"

ACCOUNT_RULES = (
    AccountMappingRule("4000", "Food sales (net)", "NET_SALES"),
    AccountMappingRule("4100", "Beverage sales", "NET_SALES"),
    AccountMappingRule("4200", "Other income", "NET_SALES"),
    AccountMappingRule("5000", "Food cost of sales", "PRODUCT_COST"),
    AccountMappingRule("5100", "Beverage cost of sales", "PRODUCT_COST"),
    AccountMappingRule("5200", "Other product cost", "PRODUCT_COST"),
    AccountMappingRule("5500", "Platform commissions and marketing", "CHANNEL_COST"),
    AccountMappingRule("6000", "Payroll, restaurant", "DIRECT_LABOUR"),
    AccountMappingRule("6100", "Packaging and consumables", "OTHER_DIRECT_OPERATING"),
    AccountMappingRule("6120", "Equipment hire", "SHARED_RESTAURANT_COST"),
    AccountMappingRule("7100", "Utilities", "SHARED_RESTAURANT_COST"),
    AccountMappingRule("7200", "Repairs and maintenance", "SHARED_RESTAURANT_COST"),
    AccountMappingRule("7300", "Cleaning and laundry", "SHARED_RESTAURANT_COST"),
    AccountMappingRule("7310", "Insurance and licences", "SHARED_RESTAURANT_COST"),
    AccountMappingRule("8000", "Owner and structural costs", "OWNER_STRUCTURAL_COST"),
)

MANAGEMENT_LINE_MAP = {
    "Net Sales": "NET_SALES",
    "Product Cost": "PRODUCT_COST",
    "Acquisition / Channel Cost": "CHANNEL_COST",
    "Direct Labour": "DIRECT_LABOUR",
    "Other Direct Operating Cost": "OTHER_DIRECT_OPERATING",
    "Shared Restaurant Costs": "SHARED_RESTAURANT_COST",
    "Owner / Structural Costs": "OWNER_STRUCTURAL_COST",
}


class CanonicalFinancialTests(unittest.TestCase):
    def test_amberside_t1_canonicalises_to_account_grain(self) -> None:
        table = parse_source(
            "Amberside_PnL_Jul2026.csv",
            (FIXTURES / "Amberside_PnL_Jul2026.csv").read_bytes(),
        ).tables[0]

        drafts = build_account_grain_financial_drafts(
            table,
            account_rules=ACCOUNT_RULES,
            currency_code="usd",
        )

        self.assertEqual(len(drafts), 15)
        self.assertTrue(all(draft.grain == "account" for draft in drafts))
        self.assertTrue(all(draft.scenario == "actual" for draft in drafts))
        self.assertTrue(all(draft.period == "2026-07" for draft in drafts))
        self.assertTrue(all(draft.currency_code == "USD" for draft in drafts))

        totals: dict[str, Decimal] = defaultdict(Decimal)
        for draft in drafts:
            totals[draft.ladder_line_code] += draft.amount

        self.assertEqual(totals["NET_SALES"], Decimal("228500"))
        self.assertEqual(totals["PRODUCT_COST"], Decimal("70282"))
        self.assertEqual(totals["CHANNEL_COST"], Decimal("3600"))
        self.assertEqual(totals["DIRECT_LABOUR"], Decimal("84317"))
        self.assertEqual(totals["OTHER_DIRECT_OPERATING"], Decimal("2500"))
        self.assertEqual(totals["SHARED_RESTAURANT_COST"], Decimal("14252"))
        self.assertEqual(totals["OWNER_STRUCTURAL_COST"], Decimal("26000"))

    def test_t1_does_not_trust_suggested_management_line(self) -> None:
        table = parse_source(
            "Amberside_PnL_Jul2026.csv",
            (FIXTURES / "Amberside_PnL_Jul2026.csv").read_bytes(),
        ).tables[0]

        only_first = AccountMappingRule("4000", "Food sales (net)", "PRODUCT_COST")
        one_row = table.__class__(
            source_name=table.source_name,
            sheet_name=table.sheet_name,
            file_type=table.file_type,
            encoding=table.encoding,
            header_row=table.header_row,
            headers=table.headers,
            rows=(table.rows[0],),
            orientation=table.orientation,
        )
        draft = build_account_grain_financial_drafts(
            one_row,
            account_rules=(only_first,),
            currency_code="USD",
        )[0]
        self.assertEqual(draft.ladder_line_code, "PRODUCT_COST")

    def test_unmapped_account_blocks_canonicalisation(self) -> None:
        table = parse_source(
            "Amberside_PnL_Jul2026.csv",
            (FIXTURES / "Amberside_PnL_Jul2026.csv").read_bytes(),
        ).tables[0]
        with self.assertRaises(CanonicalisationError):
            build_account_grain_financial_drafts(
                table,
                account_rules=ACCOUNT_RULES[:-1],
                currency_code="USD",
            )

    def test_amberside_t6_stays_ladder_grain_without_synthetic_accounts(self) -> None:
        table = parse_source(
            "Amberside_Budget_Jul2026.csv",
            (FIXTURES / "Amberside_Budget_Jul2026.csv").read_bytes(),
        ).tables[0]

        drafts = build_ladder_grain_comparator_drafts(
            table,
            management_line_map=MANAGEMENT_LINE_MAP,
            currency_code="USD",
            scenario="budget",
        )

        self.assertEqual(len(drafts), 7)
        self.assertTrue(all(draft.grain == "ladder" for draft in drafts))
        self.assertTrue(all(draft.account_code is None for draft in drafts))
        self.assertTrue(all(draft.account_name is None for draft in drafts))
        self.assertTrue(all(draft.period == "2026-07" for draft in drafts))

        totals = {draft.ladder_line_code: draft.amount for draft in drafts}
        self.assertEqual(totals["NET_SALES"], Decimal("232000"))
        self.assertEqual(totals["PRODUCT_COST"], Decimal("66908"))
        self.assertEqual(totals["DIRECT_LABOUR"], Decimal("79112"))
        self.assertEqual(totals["OWNER_STRUCTURAL_COST"], Decimal("26000"))

    def test_ladder_destination_is_not_inferred_from_amount(self) -> None:
        table = parse_source(
            "Amberside_Budget_Jul2026.csv",
            (FIXTURES / "Amberside_Budget_Jul2026.csv").read_bytes(),
        ).tables[0]
        deliberately_wrong = {**MANAGEMENT_LINE_MAP, "Net Sales": "PRODUCT_COST"}
        draft = build_ladder_grain_comparator_drafts(
            table,
            management_line_map=deliberately_wrong,
            currency_code="USD",
            scenario="budget",
        )[0]
        self.assertEqual(draft.ladder_line_code, "PRODUCT_COST")
        self.assertEqual(draft.amount, Decimal("232000"))


if __name__ == "__main__":
    unittest.main()
