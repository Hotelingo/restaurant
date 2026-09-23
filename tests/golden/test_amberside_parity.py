"""Amberside golden parity tests.

Recomputes every frozen value from the raw CSV fixtures and asserts it matches
the Engineering Freeze. Deliberately depends on nothing but the standard
library, so it can gate CI from day one, before any application code exists.

Once ``packages/calc_engine`` is real, add a parallel module that drives the
same assertions through the engine. Keep this one: it validates the *fixture*
independently of the code, which is what makes it a trustworthy oracle. A test
that computes expected values using the code under test proves only that the
code agrees with itself.

Run with pytest, or directly::

    python3 tests/golden/test_amberside_parity.py
"""

from __future__ import annotations

import csv
from decimal import Decimal
from pathlib import Path

FIXTURES = Path(__file__).resolve().parents[2] / "fixtures" / "amberside" / "upload_files"

# Beverage items are coded B*, food items F*. The fixture has no explicit
# product-group column on the item files.
BEVERAGE_PREFIX = "B"


def _read(name: str) -> list[dict[str, str]]:
    # utf-8-sig: every fixture file carries a BOM.
    with open(FIXTURES / name, encoding="utf-8-sig", newline="") as fh:
        return list(csv.DictReader(fh))


def _d(value: str) -> Decimal:
    return Decimal(value.strip())


# --------------------------------------------------------------------- ladder


def pnl_by_line() -> dict[str, Decimal]:
    """Aggregate the T1 P&L to management ladder lines."""
    totals: dict[str, Decimal] = {}
    for row in _read("Amberside_PnL_Jul2026.csv"):
        line = row["Suggested_Management_Line"]
        totals[line] = totals.get(line, Decimal(0)) + _d(row["July_2026"])
    return totals


def ladder(totals: dict[str, Decimal]) -> dict[str, Decimal]:
    """Apply the PL module's formulas to aggregated ladder lines."""
    get = lambda k: totals.get(k, Decimal(0))  # noqa: E731

    net_sales = get("Net Sales")
    product_cost = get("Product Cost")
    product_margin = net_sales - product_cost
    contribution = (
        product_margin
        - get("Acquisition / Channel Cost")
        - get("Direct Labour")
        - get("Other Direct Operating Cost")
    )
    operating_profit = contribution - get("Shared Restaurant Costs")

    return {
        "PL.NET_SALES": net_sales,
        "PL.PRODUCT_COST": product_cost,
        "PL.PRODUCT_MARGIN": product_margin,
        "PL.CHANNEL_COST": get("Acquisition / Channel Cost"),
        "PL.DIRECT_LABOUR": get("Direct Labour"),
        "PL.OTHER_DIRECT_OPERATING": get("Other Direct Operating Cost"),
        "PL.CONTRIBUTION": contribution,
        "PL.SHARED_COST": get("Shared Restaurant Costs"),
        "PL.OPERATING_PROFIT": operating_profit,
        "PL.OWNER_STRUCTURAL_COST": get("Owner / Structural Costs"),
        "PL.OWNER_RESULT": operating_profit - get("Owner / Structural Costs"),
    }


def budget_ladder() -> dict[str, Decimal]:
    """T6 comparator.

    Note the grain: this file is keyed by ``Management_Line``, not by account,
    while the spec says T6 has 'the same canonical structure as T1'. See gap
    G-07 and open decision OD-03 -- ``financial_fact.account_id`` is currently
    NOT NULL, so this comparator cannot be committed as supplied.
    """
    rows = {r["Management_Line"]: _d(r["Budget_July_2026"]) for r in _read("Amberside_Budget_Jul2026.csv")}
    operating_profit = (
        rows["Net Sales"]
        - rows["Product Cost"]
        - rows["Acquisition / Channel Cost"]
        - rows["Direct Labour"]
        - rows["Other Direct Operating Cost"]
        - rows["Shared Restaurant Costs"]
    )
    return {"PL.NET_SALES": rows["Net Sales"], "PL.OPERATING_PROFIT": operating_profit}


# ------------------------------------------------------------------ food cost


def expected_usage() -> dict[str, Decimal]:
    """FC.EXPECTED_USAGE = sum(units sold x approved item cost per unit).

    Always derived from T2 x T4A. The T3 fixture also carries an
    ``Expected_Usage`` column, which must never be mapped to a canonical fact
    (gap G-31) -- importing it would make FC.ACTUAL_VS_EXPECTED circular and
    therefore unfalsifiable.
    """
    costs = {r["Item_Code"]: _d(r["Approved_Cost_per_Unit"]) for r in _read("Amberside_RecipeCosts.csv")}
    totals: dict[str, Decimal] = {}
    for row in _read("Amberside_POS_ItemSales_Jul2026.csv"):
        code = row["Item_Code"]
        group = "Beverage" if code.startswith(BEVERAGE_PREFIX) else "Food"
        totals[group] = totals.get(group, Decimal(0)) + _d(row["Units"]) * costs[code]
    return totals


def pos_revenue() -> dict[str, Decimal]:
    totals: dict[str, Decimal] = {}
    for row in _read("Amberside_POS_ItemSales_Jul2026.csv"):
        group = "Beverage" if row["Item_Code"].startswith(BEVERAGE_PREFIX) else "Food"
        totals[group] = totals.get(group, Decimal(0)) + _d(row["Net_Revenue"])
    return totals


def food_cost_bridge() -> dict[str, dict[str, Decimal]]:
    """The two-story bridge, per product group."""
    derived = expected_usage()
    out: dict[str, dict[str, Decimal]] = {}

    for row in _read("Amberside_Stock_Jul2026.csv"):
        group = row["Product_Group"]
        consumption = _d(row["Opening_Inventory"]) + _d(row["Purchases"]) - _d(row["Closing_Inventory"])
        revenue = _d(row["Revenue"])
        benchmark = revenue * _d(row["Budget_Cost_Pct"])
        expected = derived[group]

        out[group] = {
            "FC.ACTUAL_CONSUMPTION": consumption,
            "FC.ACTUAL_COST_PCT": consumption / revenue,
            "FC.BUDGET_BENCHMARK": benchmark,
            "FC.BUDGET_GAP": consumption - benchmark,
            "FC.EXPECTED_USAGE": expected,
            "FC.EXPECTED_COST_PCT": expected / revenue,
            "FC.MENU_MIX_EFFECT": expected - benchmark,
            "FC.ACTUAL_VS_EXPECTED": consumption - expected,
        }
    return out


# ----------------------------------------------------------------- the frozen set


def test_frozen_ladder_values() -> None:
    """The eleven values frozen in the Engineering Freeze."""
    actual = ladder(pnl_by_line())

    assert actual["PL.NET_SALES"] == Decimal(228500)
    assert actual["PL.PRODUCT_COST"] == Decimal(70282)
    assert actual["PL.PRODUCT_MARGIN"] == Decimal(158218)
    assert actual["PL.CONTRIBUTION"] == Decimal(67801)
    assert actual["PL.OPERATING_PROFIT"] == Decimal(53549)


def test_frozen_budget_and_variance() -> None:
    budget = budget_ladder()
    actual = ladder(pnl_by_line())

    assert budget["PL.OPERATING_PROFIT"] == Decimal(68220)
    assert actual["PL.OPERATING_PROFIT"] - budget["PL.OPERATING_PROFIT"] == Decimal(-14671)


def test_frozen_food_sales() -> None:
    rows = {r["Account_Name"]: _d(r["July_2026"]) for r in _read("Amberside_PnL_Jul2026.csv")}
    assert rows["Food sales (net)"] == Decimal(191100)


def test_frozen_food_cost_bridge() -> None:
    food = food_cost_bridge()["Food"]

    assert food["FC.ACTUAL_CONSUMPTION"] == Decimal(61343)
    assert food["FC.EXPECTED_USAGE"] == Decimal(60400)
    assert food["FC.ACTUAL_VS_EXPECTED"] == Decimal(943)


# ------------------------------------------------------- recommended extensions
# Gap G-27: these are not in the frozen set but are derivable from the fixture
# and should be added to it.


def test_extended_ladder_values() -> None:
    actual = ladder(pnl_by_line())

    assert actual["PL.CHANNEL_COST"] == Decimal(3600)
    assert actual["PL.DIRECT_LABOUR"] == Decimal(84317)
    assert actual["PL.OTHER_DIRECT_OPERATING"] == Decimal(2500)
    assert actual["PL.SHARED_COST"] == Decimal(14252)
    assert actual["PL.OWNER_STRUCTURAL_COST"] == Decimal(26000)
    assert actual["PL.OWNER_RESULT"] == Decimal(27549)


def test_extended_food_cost_values() -> None:
    food = food_cost_bridge()["Food"]

    assert food["FC.BUDGET_BENCHMARK"] == Decimal(57330)
    assert food["FC.BUDGET_GAP"] == Decimal(4013)
    assert food["FC.MENU_MIX_EFFECT"] == Decimal(3070)
    assert round(food["FC.ACTUAL_COST_PCT"] * 100, 2) == Decimal("32.10")


def test_beverage_bridge() -> None:
    bev = food_cost_bridge()["Beverage"]

    assert bev["FC.ACTUAL_CONSUMPTION"] == Decimal(6439)
    assert bev["FC.EXPECTED_USAGE"] == Decimal(6180)
    assert bev["FC.ACTUAL_VS_EXPECTED"] == Decimal(259)
    assert bev["FC.MENU_MIX_EFFECT"] == Decimal(152)


# ------------------------------------------------------------------ invariants


def test_bridge_closes_exactly() -> None:
    """MENU_MIX_EFFECT + ACTUAL_VS_EXPECTED = BUDGET_GAP, with no residual.

    This is algebraic, not empirical -- it holds for any input. A failure means
    the implementation has departed from the specified formulas, not that the
    data is unusual.
    """
    for group, values in food_cost_bridge().items():
        assert (
            values["FC.MENU_MIX_EFFECT"] + values["FC.ACTUAL_VS_EXPECTED"] == values["FC.BUDGET_GAP"]
        ), f"bridge failed to close for {group}"


def test_pos_reconciles_to_pnl() -> None:
    """Cross-file validation rule: POS item revenue vs P&L, tolerance 0.5%.

    On this fixture the difference is exactly zero, so the assertion is exact.
    Tighter than the production rule on purpose: any drift here means the
    fixture changed, which should be a deliberate, reviewed act.
    """
    pos = pos_revenue()
    pnl = {r["Account_Name"]: _d(r["July_2026"]) for r in _read("Amberside_PnL_Jul2026.csv")}

    assert pos["Food"] == pnl["Food sales (net)"] == Decimal(191100)
    assert pos["Beverage"] == pnl["Beverage sales"] == Decimal(27400)


def test_meal_periods_reconcile_to_net_sales() -> None:
    rows = _read("Amberside_MealPeriods_Jul2026.csv")

    assert sum(_d(r["Revenue"]) for r in rows) == Decimal(228500)
    assert sum(_d(r["Budget_Revenue"]) for r in rows) == Decimal(232000)


def test_labour_reconciles_to_pnl() -> None:
    rows = _read("Amberside_Labour_Jul2026.csv")

    assert sum(_d(r["Labour_Cost"]) for r in rows) == Decimal(84317)
    assert sum(_d(r["Budget_Labour_Cost"]) for r in rows) == Decimal(79112)


def test_labour_activity_units_are_not_additive() -> None:
    """Gap G-32, asserted so the trap is visible rather than latent.

    'Kitchen prep' and 'Management / shared' carry total covers (5,650) while
    FOH rows carry their own period covers. Summing activity units across role
    groups is meaningless, and any engine that does so is wrong. labour_fact
    needs an explicit activity_basis discriminator.
    """
    rows = {r["Area"]: _d(r["Covers_or_Orders"]) for r in _read("Amberside_Labour_Jul2026.csv")}
    period_covers = rows["Dinner FOH"] + rows["Lunch FOH"]

    assert rows["Kitchen prep"] == rows["Management / shared"]
    assert rows["Kitchen prep"] > period_covers, "kitchen rows should carry a whole-outlet basis"


def test_fixture_files_are_wide_not_long() -> None:
    """Gap G-30, asserted so nobody 'fixes' the fixture.

    The demo P&L is wide -- the period is the column header 'July_2026' --
    while the blank template is long with a 'Period' column. This is
    intentional: it forces the import engine to exercise 'unpivot month
    columns' and 'fixed value' rather than taking a happy path. If this test
    starts failing, someone reformatted the fixture and made ingestion
    coverage weaker.
    """
    with open(FIXTURES / "Amberside_PnL_Jul2026.csv", encoding="utf-8-sig") as fh:
        header = fh.readline()

    assert "July_2026" in header
    assert "Period" not in header


if __name__ == "__main__":
    passed = failed = 0
    for name, fn in sorted(globals().items()):
        if not name.startswith("test_") or not callable(fn):
            continue
        try:
            fn()
        except AssertionError as exc:
            failed += 1
            print(f"FAIL  {name}\n      {exc}")
        else:
            passed += 1
            print(f"PASS  {name}")

    print(f"\n{passed} passed, {failed} failed")
    raise SystemExit(1 if failed else 0)
