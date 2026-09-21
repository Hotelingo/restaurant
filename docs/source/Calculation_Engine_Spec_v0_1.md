# Restaurant Performance Review — Calculation Engine Specification v0.1

## 1. Engine contract

Every calculation is a pure deterministic function:
- no database query inside the formula function,
- no browser state,
- no random values,
- no implicit current date,
- all settings supplied explicitly,
- all money handled with Decimal,
- every result carries a stable `calc_id`,
- every run records `engine_version` and settings snapshot.

The API layer loads canonical inputs, calls the engine, then persists the immutable result set.

Result object:

```text
calc_id
grain_type
grain_key
value
unit
currency
calculation_status
evidence_status
explanation_code
input_refs
metadata
```

`NOT_CALCULATED` is distinct from numeric zero.

---

## 2. P&L engine — module `PL`

Stable ladder:

1. Net Sales
2. Product Cost
3. Product Margin
4. Acquisition / Channel Cost
5. Direct Labour
6. Other Direct Operating Cost
7. Contribution
8. Shared Restaurant Costs
9. Restaurant Operating Profit
10. Owner / Structural Costs
11. Owner Result

### Core calculation IDs

- `PL.NET_SALES`
- `PL.PRODUCT_COST`
- `PL.PRODUCT_MARGIN`
- `PL.CHANNEL_COST`
- `PL.DIRECT_LABOUR`
- `PL.OTHER_DIRECT_OPERATING`
- `PL.CONTRIBUTION`
- `PL.SHARED_COST`
- `PL.OPERATING_PROFIT`
- `PL.OWNER_STRUCTURAL_COST`
- `PL.OWNER_RESULT`

Formulas:
- `PRODUCT_MARGIN = NET_SALES - PRODUCT_COST`
- `CONTRIBUTION = PRODUCT_MARGIN - CHANNEL_COST - DIRECT_LABOUR - OTHER_DIRECT_OPERATING`
- `OPERATING_PROFIT = CONTRIBUTION - SHARED_COST`
- `OWNER_RESULT = OPERATING_PROFIT - OWNER_STRUCTURAL_COST`

### Variance convention

Store both:
- `raw_delta = actual - comparator`
- `profit_effect`

For revenue/profit lines:
`profit_effect = actual - comparator`

For cost lines:
`profit_effect = comparator - actual`

This makes favourable positive and adverse negative without changing source signs.

Calc ID:
`PL.VAR.<LADDER_CODE>`

### SEQUENCE

`SEQ.FIRST_MATERIAL_MOVEMENT`

Inputs:
- ordered ladder results
- materiality snapshot
- risk/recurrence overrides

Output:
- first material ladder code
- impact
- materiality reason

The engine identifies a candidate location in the economic stairwell; it never names the operating cause.

---

## 3. Revenue engine — module `RV`

Grain: meal period / business format.

- `RV.ACTIVITY_UNITS`
- `RV.AVG_SPEND`
- `RV.REVENUE`
- `RV.VOLUME_EFFECT`
- `RV.SPEND_EFFECT`
- `RV.TOTAL_VARIANCE`

Formulas:
- `AVG_SPEND = revenue / activity_units`
- `VOLUME_EFFECT = (actual_units - comparator_units) × comparator_avg_spend`
- `SPEND_EFFECT = actual_units × (actual_avg_spend - comparator_avg_spend)`
- `TOTAL_VARIANCE = actual_revenue - comparator_revenue`

Control:
`VOLUME_EFFECT + SPEND_EFFECT` must tie to `TOTAL_VARIANCE` within currency tolerance.

Availability/capacity is evidence/context, not automatically a causal formula.

---

## 4. Contribution engine — module `CT`

By business view / meal period / channel where attributable:

`CT.CONTRIBUTION =
NET_SALES
- DIRECT_CHANNEL_OR_ACQUISITION_COST
- PRODUCT_COST
- DIRECT_LABOUR
- OTHER_DIRECT_OPERATING_COST`

Do not allocate shared rent, general management salary or arbitrary overhead merely to fill a "profit" column.

Additional IDs:
- `CT.CONTRIBUTION_PER_ACTIVITY_UNIT`
- `CT.CONTRIBUTION_MARGIN_PCT`

Only calculate when denominators and directly attributable costs are supported.

---

## 5. Food & Beverage Cost engine — module `FC`

All IDs carry product-group grain (`food`, `beverage`, or configured group).

### Actual consumption

`FC.ACTUAL_CONSUMPTION =
OPENING_INVENTORY
+ PURCHASES
- CLOSING_INVENTORY`

If the review boundary legitimately includes external transfers/non-revenue adjustments, those are explicit inputs with separate result lines; internal transfers inside the same inventory boundary do not change total consumption.

`FC.ACTUAL_COST_PCT = ACTUAL_CONSUMPTION / PRODUCT_REVENUE`

### Budget benchmark

`FC.BUDGET_BENCHMARK = PRODUCT_REVENUE × comparator_cost_pct`

`FC.BUDGET_GAP = ACTUAL_CONSUMPTION - BUDGET_BENCHMARK`

This is a percentage benchmark only; it does not prove operating leakage.

### Expected / theoretical usage

Preferred item-cost path:
`FC.EXPECTED_USAGE = Σ(item_units_sold × approved_item_cost_per_unit)`

Ingredient path:
`expected ingredient usage = units sold × approved recipe qty × UOM conversion / approved yield`
then multiply by approved ingredient cost.

Recipe version must be effective for the reviewed period.

`FC.EXPECTED_COST_PCT = EXPECTED_USAGE / PRODUCT_REVENUE`

### Two-story bridge

`FC.MENU_MIX_EFFECT = EXPECTED_USAGE - BUDGET_BENCHMARK`

`FC.ACTUAL_VS_EXPECTED = ACTUAL_CONSUMPTION - EXPECTED_USAGE`

The engine must never describe `MENU_MIX_EFFECT` as leakage.

### Driver evidence

Stable IDs:
- `FC.DRIVER.PRICE_SPEC`
- `FC.DRIVER.YIELD`
- `FC.DRIVER.PORTION`
- `FC.DRIVER.PRODUCTION`
- `FC.DRIVER.WASTE`
- `FC.DRIVER.TRANSFER_NONREVENUE`
- `FC.DRIVER.INVENTORY_DATA`
- `FC.DRIVER.OTHER_SUPPORTED`

Only evidence with `supported` or `validated` status may enter the quantitative driver reconciliation.

`FC.SUPPORTED_DRIVER_TOTAL = Σ supported driver impacts`

`FC.RESIDUAL = FC.ACTUAL_VS_EXPECTED - FC.SUPPORTED_DRIVER_TOTAL`

Residual may be zero, positive or negative. It remains visible.

### Branch result

`FC.DECISION_PATH` returns one of:
- `VALIDATE_FIRST`
- `OPERATING_CONTROL_INVESTIGATION`
- `MENU_ECONOMIC_HANDOFF`
- `NO_MATERIAL_GAP`

The thresholds come from versioned materiality settings.

---

## 6. C02 diagnostic calculations

These calculations are optional and run only when the selected test has valid evidence.

### Yield
- theoretical usable qty = AP quantity × approved yield
- observed usable qty
- usable shortfall
- impact = shortfall × approved usable unit cost

### Portion
- excess qty per portion = observed avg portion - approved portion
- supported excess usage = excess qty × representative portions
- impact = excess usage × approved usable unit cost

### Production / buffet
Based on explicitly supplied production, served and closing/waste quantities.
Do not infer hidden production from P&L amounts.

### Waste
Reason-coded quantity × approved/actual unit cost according to the chosen basis.

### Transfers / non-revenue
Only externally-boundary or properly classified product movement enters the bridge.

### Anti-double-counting
Every supported driver evidence record has a `coverage_key`.
Two active driver amounts with overlapping `coverage_key` cannot both enter the same reconciliation without reviewer override.

---

## 7. Labour engine — module `LB`

Inputs:
- actual paid hours
- comparator hours
- actual labour cost
- comparator labour cost
- activity units
- overtime hours
- optional scheduled hours

Derived rates:
- `actual_rate = actual_cost / actual_hours`
- `comparator_rate = comparator_cost / comparator_hours`

Effects:
- `LB.HOURS_EFFECT_RAW = (actual_hours - comparator_hours) × comparator_rate`
- `LB.RATE_EFFECT_RAW = actual_hours × (actual_rate - comparator_rate)`
- raw cost variance = actual cost - comparator cost

For profit-effect display, multiply adverse cost effects by `-1`.

Other IDs:
- `LB.HOURS_PER_ACTIVITY`
- `LB.COST_PER_ACTIVITY`
- `LB.OVERTIME_HOURS`
- `LB.OVERTIME_RATE_EFFECT` where data supports it

Guardrail:
The engine must not output `OVERSTAFFED` from Labour % alone.

---

## 8. Other Cost engine — module `OC`

For a material cost with quantity/rate evidence:

- `OC.QUANTITY_EFFECT = (actual_qty - comparator_qty) × comparator_rate`
- `OC.RATE_EFFECT = actual_qty × (actual_rate - comparator_rate)`
- `OC.TOTAL_VARIANCE = actual_cost - comparator_cost`

Cost behaviour and controllability remain management/evidence classifications, not inferred causal truths.

---

## 9. Menu SCREEN engine — module `MN`

Population-level controls are mandatory.

### Core IDs

- `MN.UNITS`
- `MN.MIX_PCT`
- `MN.EQUAL_SHARE`
- `MN.POPULARITY_THRESHOLD`
- `MN.NET_REVENUE_PER_UNIT`
- `MN.PRODUCT_COST_PER_UNIT`
- `MN.CLASSIC_CM_PER_UNIT`
- `MN.CM_WEIGHTED_BENCHMARK`
- `MN.SCREEN_CLASS`

Formulas:
- `MIX_PCT = item_units / population_units`
- `EQUAL_SHARE = 1 / eligible_item_count`
- `POPULARITY_THRESHOLD = EQUAL_SHARE × popularity_factor`
- `NET_REVENUE_PER_UNIT = item_net_revenue / item_units`
- `CLASSIC_CM_PER_UNIT = NET_REVENUE_PER_UNIT - PRODUCT_COST_PER_UNIT`
- `CM_WEIGHTED_BENCHMARK = Σ(item_units × item_CM) / Σ(item_units)`

Class:
- high popularity + high CM = Star
- high popularity + low CM = Plowhorse
- low popularity + high CM = Puzzle
- low popularity + low CM = Dog

The engine output is a screen/label only. No action is generated from class.

---

## 10. TRAIL calculations / evidence states

### T — Trend & Target
The engine may summarize classification history and availability:
- `stable`
- `moving`
- `distorted`
- `evidence_required`

Target remains a human/configured input.

### R — Retained Economics
`MN.RETAINED_CM_PER_UNIT =
NET_REVENUE_PER_UNIT
- PRODUCT_COST_PER_UNIT
- SUPPORTED_DIRECT_DECISION_COST_PER_UNIT`

No shared overhead allocation.

### A — Activity & Capacity
Only calculate `CM_PER_CONSTRAINED_MINUTE` when:
- resource is explicitly confirmed as a genuine constraint,
- supported minutes are available.

Otherwise result is `NOT_CALCULATED`.

### I — Interactions
Transaction-derived association metrics may be calculated.
Output must be labelled association, not causation.

### L — Line-up Role
Human-entered strategic role; no automated decision.

---

## 11. Menu TEST engine

Baseline and test window are locked at test start.

Calculate:
- units movement
- net revenue/unit movement
- retained CM/unit movement
- total retained contribution movement
- named substitute/complement association movement
- system check
- guardrail metrics

The engine returns observed movements only.

Human outcome:
- KEEP / EXTEND
- MODIFY / CONTINUE TEST
- REVERSE
- EVIDENCE REQUIRED

---

## 12. Materiality engine — module `MAT`

No universal hard-coded threshold.

Inputs are frozen per run:
- absolute amount
- percentage threshold
- recurrence indicator
- risk override

Suggested logic:
`material = amount_test OR percentage_test OR recurrence_override OR risk_override`

Every issue records the exact rule that made it material.

---

## 13. Review gate engine — module `RG`

A review can move to sign-off only when:

- FRAME is complete.
- Reconciliation status is explicit.
- Every shortlisted issue has one valid disposition.
- ACT: owner + lever + guardrail + metric + date/cadence.
- MONITOR: owner + trigger + cadence.
- INVESTIGATE: exact evidence + owner + due date.
- ESCALATE: decision required + escalation owner + consequence + deadline.
- CLOSE: supported reason.
- Evidence Required remains visible.
- Reviewer comments are resolved.
- Claim validation has no rejected/unresolved blocking claim.
- Pack points to a completed locked calculation run.

The engine returns gate failures; it does not override them.