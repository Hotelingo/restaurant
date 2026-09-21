from __future__ import annotations

import csv
from decimal import Decimal
from pathlib import Path
import unittest

from packages.calc_engine import calculate_pl_ladder, calculate_pl_variances, results_by_code

ROOT = Path(__file__).resolve().parents[3]
FIXTURES = ROOT / "fixtures" / "amberside" / "upload_files"

ACCOUNT_TO_LINE = {
    "4000": "NET_SALES",
    "4100": "NET_SALES",
    "4200": "NET_SALES",
    "5000": "PRODUCT_COST",
    "5100": "PRODUCT_COST",
    "5200": "PRODUCT_COST",
    "5500": "CHANNEL_COST",
    "6000": "DIRECT_LABOUR",
    "6100": "OTHER_DIRECT_OPERATING",
    "6120": "SHARED_COST",
    "7100": "SHARED_COST",
    "7200": "SHARED_COST",
    "7300": "SHARED_COST",
    "7310": "SHARED_COST",
    "8000": "OWNER_STRUCTURAL_COST",
}

BUDGET_LINE_TO_CODE = {
    "Net Sales": "NET_SALES",
    "Product Cost": "PRODUCT_COST",
    "Acquisition / Channel Cost": "CHANNEL_COST",
    "Direct Labour": "DIRECT_LABOUR",
    "Other Direct Operating Cost": "OTHER_DIRECT_OPERATING",
    "Shared Restaurant Costs": "SHARED_COST",
    "Owner / Structural Costs": "OWNER_STRUCTURAL_COST",
}


def _read(name: str) -> list[dict[str, str]]:
    with open(FIXTURES / name, encoding="utf-8-sig", newline="") as handle:
        return list(csv.DictReader(handle))


def _actual_sources() -> dict[str, Decimal]:
    totals: dict[str, Decimal] = {}
    for row in _read("Amberside_PnL_Jul2026.csv"):
        code = ACCOUNT_TO_LINE[row["Account_Code"]]
        totals[code] = totals.get(code, Decimal("0")) + Decimal(row["July_2026"])
    return totals


def _budget_sources() -> dict[str, Decimal]:
    return {
        BUDGET_LINE_TO_CODE[row["Management_Line"]]: Decimal(row["Budget_July_2026"])
        for row in _read("Amberside_Budget_Jul2026.csv")
    }


class AmbersidePLEngineParityTests(unittest.TestCase):
    def test_all_eleven_actual_ladder_values_match_fixture_oracle(self) -> None:
        actual = results_by_code(calculate_pl_ladder(_actual_sources(), currency="USD"))
        expected = {
            "NET_SALES": Decimal("228500"),
            "PRODUCT_COST": Decimal("70282"),
            "PRODUCT_MARGIN": Decimal("158218"),
            "CHANNEL_COST": Decimal("3600"),
            "DIRECT_LABOUR": Decimal("84317"),
            "OTHER_DIRECT_OPERATING": Decimal("2500"),
            "CONTRIBUTION": Decimal("67801"),
            "SHARED_COST": Decimal("14252"),
            "OPERATING_PROFIT": Decimal("53549"),
            "OWNER_STRUCTURAL_COST": Decimal("26000"),
            "OWNER_RESULT": Decimal("27549"),
        }
        self.assertEqual(set(actual), set(expected))
        for code, value in expected.items():
            with self.subTest(code=code):
                self.assertEqual(actual[code].value, value)

    def test_budget_operating_profit_and_variance_match_frozen_values(self) -> None:
        actual = calculate_pl_ladder(_actual_sources(), currency="USD")
        budget = calculate_pl_ladder(_budget_sources(), currency="USD")
        budget_by_code = results_by_code(budget)
        variance = results_by_code(calculate_pl_variances(actual, budget, currency="USD"))

        self.assertEqual(budget_by_code["OPERATING_PROFIT"].value, Decimal("68220"))
        self.assertEqual(variance["OPERATING_PROFIT"].raw_delta, Decimal("-14671"))
        self.assertEqual(variance["OPERATING_PROFIT"].profit_effect, Decimal("-14671"))

    def test_repeated_runs_are_value_deterministic(self) -> None:
        first = calculate_pl_ladder(_actual_sources(), currency="USD")
        second = calculate_pl_ladder(_actual_sources(), currency="USD")
        self.assertEqual(first, second)


if __name__ == "__main__":
    unittest.main()
