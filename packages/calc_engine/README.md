# Calculation engine

Pure Python calculation functions.

Non-negotiable properties:
- Decimal-based money arithmetic;
- stable calc IDs;
- no database access;
- no HTTP/network access;
- no browser dependency;
- no clock or randomness;
- all settings supplied explicitly;
- missing is never silently converted to zero.

This package must run its unit tests with no database and no network available.

## Management P&L (PL)

calculate_pl_ladder(...) implements the eleven frozen Management P&L calc IDs from the Calculation Engine Specification. It accepts canonical, non-calculated ladder inputs and returns results in the stable ladder order. Missing source values return NOT_CALCULATED; dependent subtotals propagate that state rather than manufacturing zeroes.

calculate_pl_variances(...) emits PL.VAR.<LADDER_CODE> results. Every calculated variance stores both raw_delta = actual - comparator and profit_effect; cost-line profit effects reverse the raw sign so favourable is positive. A wholly missing comparator returns NOT_CALCULATED / COMPARATOR_NOT_COMMITTED.

No formula rounds. quantize_money_for_presentation(...) is an explicit presentation-boundary helper using ROUND_HALF_UP and a caller-supplied currency minor unit.

The Amberside engine parity tests aggregate fixture rows through explicit account-code mappings, not through source amounts, then prove all eleven ladder values plus the frozen Budget Operating Profit and Operating Profit variance.


Canonical grain keys use the PostgreSQL `ladder_line.code` values. In particular, the database
code is `SHARED_RESTAURANT_COST` while its stable calculation id remains `PL.SHARED_COST`.
Variance ids follow the contract `PL.VAR.<LADDER_CODE>`, so the corresponding variance id is
`PL.VAR.SHARED_RESTAURANT_COST`.


## First material movement

`first_material_movement(...)` walks the frozen Management P&L ladder in order and applies the
confirmed run-level general materiality snapshot. A movement is material when any of these explicit
tests is true: `amount_test`, `percentage_test`, `recurrence_override`, or `risk_override`.
The percentage denominator is the absolute comparator value for that individual ladder line; a zero
comparator cannot satisfy the percentage test.

The calculation returns the first selected ladder code as a categorical result and records the
profit-effect impact, raw movement, thresholds, ratio, primary materiality reason, and every matched
rule in metadata. `NO_MATERIAL_MOVEMENT` is a valid calculated state. Missing/unconfirmed
materiality or a missing comparator is `NOT_CALCULATED`, never a false zero/no-movement result.

This calculation identifies only a location in the economic stairwell. Its result contract has no
cause, driver, diagnosis, or root-cause output.


## Food cost (FC)

`calculate_expected_usage(...)` implements the preferred T2 × T4A path and deliberately has no
input for T3 `Expected_Usage`; expected usage is derived, never imported. Missing or ineffective
approved item costs return an explicit `NOT_CALCULATED` result.

`calculate_food_cost_bridge(...)` returns the eight stable product-group calculations:
`FC.ACTUAL_CONSUMPTION`, `FC.ACTUAL_COST_PCT`, `FC.BUDGET_BENCHMARK`,
`FC.BUDGET_GAP`, `FC.EXPECTED_USAGE`, `FC.EXPECTED_COST_PCT`,
`FC.MENU_MIX_EFFECT`, and `FC.ACTUAL_VS_EXPECTED`. The bridge is exact:
`MENU_MIX_EFFECT + ACTUAL_VS_EXPECTED = BUDGET_GAP`. Budget gap is context and
`MENU_MIX_EFFECT` is explicitly menu economics, never labelled leakage.

`calculate_supported_driver_total(...)` includes only supported/validated evidence, rejects a
non-zero amount on unsupported evidence, and rejects duplicate `coverage_key` values unless an
explicit reviewer-override reference is supplied. `FC.RESIDUAL` remains calculated and visible
whether positive, zero, or negative.

`calculate_decision_path(...)` implements corrected G-20/G-21. It branches on
`FC.ACTUAL_VS_EXPECTED`, not `FC.BUDGET_GAP`, using the frozen materiality snapshot. The five
stable values are `VALIDATE_FIRST`, `OPERATING_CONTROL_INVESTIGATION`,
`FAVOURABLE_VALIDATE_DATA`, `MENU_ECONOMIC_HANDOFF`, and `NO_MATERIAL_GAP`.
