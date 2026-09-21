# Amberside golden fixture

The deterministic test pack for Amberside Bistro, July 2026. Carried forward unchanged from the
v4.1 demo pack and used as the single fixture for parity testing.

**Do not modify these files.** They are the oracle. `tests/golden/test_amberside_parity.py` asserts
their shape as well as their values, so an accidental edit fails CI — which is the intent.

## Verification status

Every value frozen in the Engineering Freeze reconciles **exactly** from these raw files, and every
cross-file tie-out is zero. Verified 2026-09-21; enforced by `tests/golden/` (13 tests, all green).

```
PL.NET_SALES        228,500     PL.CONTRIBUTION        67,801
PL.PRODUCT_COST      70,282     PL.OPERATING_PROFIT    53,549
PL.PRODUCT_MARGIN   158,218     PL.OWNER_RESULT        27,549     (not yet in the frozen set)
Budget operating profit 68,220      Variance  −14,671

FC.ACTUAL_CONSUMPTION food 61,343   FC.EXPECTED_USAGE food 60,400   gap 943
FC.BUDGET_BENCHMARK   food 57,330   FC.MENU_MIX_EFFECT     3,070   FC.BUDGET_GAP 4,013

Cross-file: POS food 191,100 = P&L food sales · POS bev 27,400 = P&L bev sales
            meal periods 228,500 = net sales · labour 84,317 = P&L payroll
```

The bridge closes exactly: `3,070 + 943 = 4,013`.

## Files

### `upload_files/` — what a customer would actually send

Realistic exports. Use these for ingestion testing.

| File | Template | Rows | Notes |
|---|---|---|---|
| `Amberside_PnL_Jul2026.csv` | T1 | 15 | **Wide** — period is the column header `July_2026` |
| `Amberside_Budget_Jul2026.csv` | T6 | 7 | **Ladder grain**, not account grain — see G-07 |
| `Amberside_MealPeriods_Jul2026.csv` | T1B | 6 | Comparator columns inline; no period column |
| `Amberside_POS_ItemSales_Jul2026.csv` | T2 | 12 | Ties to P&L exactly |
| `Amberside_Stock_Jul2026.csv` | T3 | 2 | Carries derived columns — see below |
| `Amberside_RecipeCosts.csv` | T4A | 12 | Approved cost per unit |
| `Amberside_Labour_Jul2026.csv` | T5 | 5 | Activity units **not additive** — see G-32 |
| `Amberside_CustomerSource_Jul2026.csv` | T7 | 9 | Includes an "Not attributed" row with `Evidence Required` |
| `Amberside_Transactions_Jul2026.csv` | T8 | 10,500 | Volume and performance test |
| `Amberside_MenuHistory_JanAug2026.csv` | M1 | 96 | Eight months for TRAIL trend |
| `Amberside_PriorActions_Aug2026.csv` | — | 5 | Prior-action verification scenario |

### `templates/` — blank fallback templates

The canonical long-form templates. Note that they do **not** match the upload files above. That is
deliberate — see below.

### `Amberside_Demo_Data_v1.xlsx`

The same data as a twelve-sheet workbook, including a `Mapping_Example` sheet.

## Three traps, all intentional

### 1. The upload files are wide; the templates are long (G-30)

`Amberside_PnL_Jul2026.csv` puts the period in the column header (`July_2026`).
`templates/Template_PnL.csv` has a `Period` column. Stock, labour, meal-period and customer-source
files carry **no period column at all**.

This is not a fixture defect. It forces the import engine to exercise `unpivot month columns` and
`fixed value`, and to do real profile detection rather than a happy-path parse — which is exactly
what a real customer export will demand.

**Do not reformat these files to make a parser's life easier.**
`test_fixture_files_are_wide_not_long` fails if anyone tries.

### 2. `Amberside_Stock_Jul2026.csv` carries derived columns (G-31)

It has `Revenue`, `Budget_Cost_Pct` and `Expected_Usage`. Expected usage is **derived** — T2 units ×
T4A approved cost — and is recomputed in the golden test to 60,400 independently.

**Never map `Expected_Usage` to a canonical fact.** Importing it makes `FC.ACTUAL_VS_EXPECTED`
circular: it would compare a number against itself, and the two-story bridge would become
unfalsifiable. These columns are fixture convenience only.

### 3. Labour activity units are not additive (G-32)

"Kitchen prep" and "Management / shared" both carry 5,650 — total outlet covers — while FOH rows
carry their own period covers. Summing `Covers_or_Orders` across role groups is meaningless.

`labour_fact` needs an explicit `activity_basis` discriminator so the engine knows which rows may
be aggregated. `test_labour_activity_units_are_not_additive` asserts the trap so it stays visible.

## Known conflict — G-07 / OD-03

`Amberside_Budget_Jul2026.csv` is keyed by `Management_Line`, but the import spec says T6 has "the
same canonical structure as T1" (account grain) and `financial_fact.account_id` is `NOT NULL`.

**The comparator cannot be committed as supplied** without inventing synthetic accounts, which would
corrupt the account dimension. The fixture is almost certainly right — restaurants budget at
management-line level, not by account. The schema should accommodate it. Pending OD-03.

## Adding golden values

`tests/golden/test_amberside_parity.py` currently covers `PL` and `FC`. The fixture also supports
`RV` (meal-period actual and budget), `LB` (hours, cost, activity), `CT`, `OC` and `MN` (item units,
prices, costs, eight months of history). Derive and freeze those during slices 6, 7 and 9, following
the same pattern.

Keep the golden test **independent of application code**. It validates the fixture as an oracle; a
test that computes expected values using the code under test proves only that the code agrees with
itself.
