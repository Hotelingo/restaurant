# Calculation Registry

The implementation contract for `packages/calc_engine`. Where this disagrees with
`docs/source/Calculation_Engine_Spec_v0_1.md`, the disagreement is deliberate, marked, and
cross-referenced to a gap. Everything else is the spec restated with the ambiguities closed.

**Not yet accepted.** Sign off before slice 3.

---

## 1. Universal rules

Every calculation is a pure deterministic function: no database query, no browser state, no random
values, no implicit current date, all settings supplied explicitly, all money as `Decimal`.

Result object:

```
calc_id · grain_type · grain_key · value · unit · currency
calculation_status · evidence_status · explanation_code
input_refs · metadata
```

### 1.1 Zero and absent denominators — G-22

**Every** division returns `NOT_CALCULATED` when the denominator is zero, absent or `NOT_CALCULATED`.
Never `0`. This applies to `AVG_SPEND`, `ACTUAL_COST_PCT`, `EXPECTED_COST_PCT`, `MIX_PCT`,
`EQUAL_SHARE`, `NET_REVENUE_PER_UNIT`, `CONTRIBUTION_MARGIN_PCT`, `CM_PER_CONSTRAINED_MINUTE` and
every derived rate.

`explanation_code` values:

| Code | Meaning |
|---|---|
| `DENOMINATOR_ZERO` | Denominator present and equal to zero |
| `DENOMINATOR_ABSENT` | Denominator not supplied |
| `INPUT_NOT_CALCULATED` | An upstream input is itself `NOT_CALCULATED` |
| `COMPARATOR_NOT_COMMITTED` | No committed batch for the comparator scenario (G-26) |
| `EVIDENCE_REQUIRED` | Calculable, but evidence status forbids use |
| `CONSTRAINT_NOT_CONFIRMED` | Capacity metric where no constraint is confirmed |
| `RECIPE_VERSION_NOT_EFFECTIVE` | No approved recipe effective for the period |

> The prototype returns `0` here (`var pct = sales ? cons/sales : 0`). That is a wireframe
> convenience and must not be reproduced — it silently converts "we don't know" into "it's zero",
> which is the exact failure mode this product exists to prevent.

### 1.2 Decimal and rounding — G-23

- All money and rate arithmetic in `Decimal`. Never float.
- **Never quantise between intermediate steps.** Full precision throughout the chain.
- Quantise **only at presentation**, to the currency's minor unit, `ROUND_HALF_UP`.
- Percentages carried at full precision; displayed to the configured precision (default 1 dp).
- Persist `value_numeric` as `numeric(20,4)` — unquantised, four decimal places.

### 1.3 Variance convention

Store both:

```
raw_delta     = actual − comparator
profit_effect = actual − comparator      (revenue and profit lines)
profit_effect = comparator − actual      (cost lines)
```

Favourable is positive without altering source signs. Calc id: `PL.VAR.<LADDER_CODE>`.

### 1.4 The Laspeyres convention — G-24, **must be documented customer-facing**

All variance decompositions place the interaction term in the **second** effect (rate/spend), not in
a separate interaction line:

```
first_effect  = (actual_qty − comparator_qty) × comparator_rate
second_effect = actual_qty × (actual_rate − comparator_rate)
```

This makes the decomposition close exactly, with **zero residual**:

```
first + second = Qa·Rc − Qc·Rc + Qa·Ra − Qa·Rc = Qa·Ra − Qc·Rc = total variance
```

The consequence: **the rate/spend effect is systematically inflated by the interaction term**
(`(Qa − Qc) × (Ra − Rc)`). This is a legitimate and common choice, but it is a material accounting
decision. A customer's finance team reconciling against a mid-point or three-way decomposition will
get different numbers and will ask why. State it in the methodology notes shown in the product, not
only here.

Because the decomposition is algebraically exact, a failing tie-out check **cannot** be a rounding
artefact — it is always a data problem, and the user-facing message must say so.

### 1.5 Tolerances — G-25, pending OD-11

| Check | Proposed default |
|---|---|
| Variance decomposition tie-out | 0.01 currency minor units |
| POS item revenue ↔ P&L | 0.5% |
| T3 purchases ↔ P&L purchases | 2% |
| Opening inventory ↔ prior closing | 0.5% (warn), 2% (block) |

Stored as settings, versioned per outlet. Not constants.

---

## 2. `PL` — Management P&L

| `calc_id` | Formula | Unit |
|---|---|---|
| `PL.NET_SALES` | Σ facts mapped to `NET_SALES` | currency |
| `PL.PRODUCT_COST` | Σ facts mapped to `PRODUCT_COST` | currency |
| `PL.PRODUCT_MARGIN` | `NET_SALES − PRODUCT_COST` | currency |
| `PL.CHANNEL_COST` | Σ `CHANNEL_COST` | currency |
| `PL.DIRECT_LABOUR` | Σ `DIRECT_LABOUR` | currency |
| `PL.OTHER_DIRECT_OPERATING` | Σ `OTHER_DIRECT_OPERATING` | currency |
| `PL.CONTRIBUTION` | `PRODUCT_MARGIN − CHANNEL_COST − DIRECT_LABOUR − OTHER_DIRECT_OPERATING` | currency |
| `PL.SHARED_COST` | Σ `SHARED_RESTAURANT_COST` | currency |
| `PL.OPERATING_PROFIT` | `CONTRIBUTION − SHARED_COST` | currency |
| `PL.OWNER_STRUCTURAL_COST` | Σ `OWNER_STRUCTURAL_COST` | currency |
| `PL.OWNER_RESULT` | `OPERATING_PROFIT − OWNER_STRUCTURAL_COST` | currency |

Grain: `outlet × period × scenario`.

### `SEQ.FIRST_MATERIAL_MOVEMENT`

Inputs: ordered ladder results, materiality snapshot, risk/recurrence overrides.
Output: first material ladder code, impact, materiality reason.

**The engine identifies a location in the economic stairwell. It never names an operating cause.**

---

## 3. `RV` — Revenue · grain: meal period / business format

```
AVG_SPEND      = revenue / activity_units          → NOT_CALCULATED if units = 0
VOLUME_EFFECT  = (Ua − Uc) × Sc
SPEND_EFFECT   = Ua × (Sa − Sc)
TOTAL_VARIANCE = Ra − Rc
```

Control: `VOLUME_EFFECT + SPEND_EFFECT = TOTAL_VARIANCE`, exactly (§1.4).
Availability and capacity are evidence and context, never automatically causal.

## 4. `CT` — Contribution

```
CT.CONTRIBUTION = NET_SALES − DIRECT_CHANNEL_COST − PRODUCT_COST
                            − DIRECT_LABOUR − OTHER_DIRECT_OPERATING_COST
CT.CONTRIBUTION_PER_ACTIVITY_UNIT = CONTRIBUTION / activity_units
CT.CONTRIBUTION_MARGIN_PCT        = CONTRIBUTION / NET_SALES
```

**Never allocate shared rent, general management salary or arbitrary overhead to fill a profit
column.** Calculate only when denominators and directly attributable costs are supported.

## 5. `LB` — Labour

```
actual_rate     = actual_cost / actual_hours       → NOT_CALCULATED if hours = 0
comparator_rate = comparator_cost / comparator_hours
LB.HOURS_EFFECT_RAW = (Ha − Hc) × Rc
LB.RATE_EFFECT_RAW  = Ha × (Ra − Rc)
```

Also `LB.HOURS_PER_ACTIVITY`, `LB.COST_PER_ACTIVITY`, `LB.OVERTIME_HOURS`,
`LB.OVERTIME_RATE_EFFECT`. Adverse cost effects are multiplied by −1 for profit-effect display.

**Guardrail: the engine must never output `OVERSTAFFED` from Labour % alone.**

> **Activity units are not additive across role groups — G-32.** In the Amberside fixture, "Kitchen
> prep" and "Management / shared" both carry 5,650 (total covers) while FOH rows carry their own
> period covers. Summing them is meaningless. `labour_fact` needs an explicit `activity_basis`
> discriminator so the engine knows which rows may be aggregated.

## 6. `OC` — Other costs

```
OC.QUANTITY_EFFECT = (Qa − Qc) × Rc
OC.RATE_EFFECT     = Qa × (Ra − Rc)
OC.TOTAL_VARIANCE  = Ca − Cc
```

Cost behaviour and controllability remain management classifications, never inferred causal truths.

---

## 7. `FC` — Food and beverage cost

Grain: product group (`food`, `beverage`, or configured group).

```
FC.ACTUAL_CONSUMPTION = OPENING + PURCHASES − CLOSING
FC.ACTUAL_COST_PCT    = ACTUAL_CONSUMPTION / PRODUCT_REVENUE
FC.BUDGET_BENCHMARK   = PRODUCT_REVENUE × comparator_cost_pct
FC.BUDGET_GAP         = ACTUAL_CONSUMPTION − BUDGET_BENCHMARK
FC.EXPECTED_USAGE     = Σ(item_units_sold × approved_item_cost_per_unit)
FC.EXPECTED_COST_PCT  = EXPECTED_USAGE / PRODUCT_REVENUE
FC.MENU_MIX_EFFECT    = EXPECTED_USAGE − BUDGET_BENCHMARK
FC.ACTUAL_VS_EXPECTED = ACTUAL_CONSUMPTION − EXPECTED_USAGE
```

The bridge closes exactly:
`MENU_MIX_EFFECT + ACTUAL_VS_EXPECTED = BUDGET_GAP`.

Ingredient path, where recipes rather than item costs are supplied:
`expected usage = units sold × approved recipe qty × UOM conversion / approved yield`, then
× approved ingredient cost. The recipe version must be effective for the reviewed period, else
`NOT_CALCULATED` / `RECIPE_VERSION_NOT_EFFECTIVE`.

> **Expected usage is always derived, never imported — G-31.**
> `Amberside_Stock_Jul2026.csv` has an `Expected_Usage` column. It is fixture convenience. Mapping
> it to a canonical fact makes `FC.ACTUAL_VS_EXPECTED` circular and unfalsifiable.

**The engine must never describe `MENU_MIX_EFFECT` as leakage.**

### 7.1 Drivers

`FC.DRIVER.PRICE_SPEC` · `YIELD` · `PORTION` · `PRODUCTION` · `WASTE` ·
`TRANSFER_NONREVENUE` · `INVENTORY_DATA` · `OTHER_SUPPORTED`

```
FC.SUPPORTED_DRIVER_TOTAL = Σ supported driver impacts
FC.RESIDUAL               = FC.ACTUAL_VS_EXPECTED − FC.SUPPORTED_DRIVER_TOTAL
```

- Only `supported` or `validated` evidence may enter the quantitative reconciliation.
- **Evidence with status `evidence_required` contributes zero and its input is disabled** — the
  amount cannot be entered at all, rather than being entered and ignored. (From the prototype's
  `fcCalc`; see §9.)
- `FC.RESIDUAL` may be positive, negative or zero. **It remains visible in every case.**
- Two active driver amounts with overlapping `coverage_key` cannot both enter one reconciliation
  without an explicit reviewer override.

### 7.2 `FC.DECISION_PATH` — **corrected, G-20 and G-21**

> **This is a deliberate departure from the prototype.**
>
> The prototype's `fcCalc` branches to "OPERATING / CONTROL GAP" on the **budget gap**
> (`consumption − benchmark`). The written spec states that the budget benchmark "is a percentage
> benchmark only; it does not prove operating leakage" — and the spec is right. Only
> `ACTUAL_VS_EXPECTED` can indicate operating control loss; `MENU_MIX_EFFECT` is a menu-economics
> question.
>
> On the Amberside fixture the budget gap is **4,013**, of which **3,070 is menu mix** and only
> **943** is a genuine actual-vs-expected gap. The prototype's logic therefore sends the user
> hunting for leakage that is mostly not there — the precise error the two-story bridge exists to
> prevent.

Branch on `ACTUAL_VS_EXPECTED`, with thresholds from the versioned materiality snapshot:

| Return | Condition |
|---|---|
| `VALIDATE_FIRST` | Inventory/data evidence status is not `validated`, or materiality is unset |
| `OPERATING_CONTROL_INVESTIGATION` | `ACTUAL_VS_EXPECTED > threshold` |
| `FAVOURABLE_VALIDATE_DATA` | `ACTUAL_VS_EXPECTED < −threshold` — check counts, standards and cut-off before calling it a saving (G-21, absent from the spec's four-value enum but present and correct in the prototype) |
| `MENU_ECONOMIC_HANDOFF` | `ACTUAL_VS_EXPECTED` within threshold **and** `MENU_MIX_EFFECT` material |
| `NO_MATERIAL_GAP` | Neither material |

`FC.BUDGET_GAP` is displayed as context throughout. It never drives the branch.

---

## 8. `MN`, `MAT`, `RG`

`MN` (menu SCREEN/TRAIL/TEST), `MAT` (materiality) and `RG` (review gates) follow
`docs/source/Calculation_Engine_Spec_v0_1.md` §9–13 unchanged, subject to the universal rules in §1.

Three points worth restating because they are easy to erode under delivery pressure:

- **`MN.SCREEN_CLASS` is a label, not an action.** No action is generated from a class.
- **Interaction metrics are association, never causation**, and must be labelled as such.
- **`MAT` records the exact rule that made each issue material** — `amount_test`,
  `percentage_test`, `recurrence_override` or `risk_override`. No universal hard-coded threshold
  exists anywhere in the codebase.

---

## 9. Rules recovered from the prototype — G-28

These four rules exist **only** in the wireframe's JavaScript and in no specification document.
They are among the best ideas in the product. Written down here so they are not lost.

### 9.1 `claimCheck` — Owner Pack claim validation

For each claim in a pack:

1. Extract every number from the claim prose (`/\d[\d,]*(?:\.\d+)?/g`, commas stripped).
2. **Every extracted number must appear in the engine's output set for that claim's citations.** Any
   number that does not is reported by value alongside the engine's actual value.
3. Reject banned wording, case-insensitive, whole word:
   `theft` · `steal` · `stealing` · `fraud` · `guarantee` · `always` · `never`
   — accusations and absolute claims have no place in a signed pack.
4. A failing claim **cannot be accepted**: the accept action is disabled, and a previously accepted
   claim that later fails is automatically un-accepted.
5. The pack cannot be signed while any claim fails.

**Must be enforced server-side.** In the prototype it is client-side only.

### 9.2 `decReq` — required fields by decision type

The gate engine requires, per disposition: hypothesis, intervention, guardrail, owner, verification
metric, and a due date (except where the decision is to protect the status quo). Evidence-collection
decisions require intervention, owner and due date only. Replacement decisions additionally require
the identified gap.

**Enforce in the database with disposition-keyed CHECK constraints** (G-06), not only in the engine
— the constraint is the product's core discipline and should not depend on a code path being called.

### 9.3 `decEvGate` — evidence-blocked decisions

Decision types that depend on quantified evidence are blocked while the issue's evidence status is
`EVIDENCE REQUIRED`. The block is explicit and visible, not a silently disabled button.

### 9.4 Unsupported driver amounts

See §7.1: `evidence_required` forces the amount to zero **and disables the input**. Anti-double-
counting is enforced by making the unsupported number impossible to enter, not by filtering it later.

---

## 10. Golden values — Amberside, July 2026

All verified by recomputation from the raw CSVs in `fixtures/amberside/upload_files/`.
Enforced by `tests/golden/test_amberside_parity.py`.

### Frozen set (from the Engineering Freeze) — all confirmed

```
PL.NET_SALES                    228,500
PL.PRODUCT_COST                  70,282
PL.PRODUCT_MARGIN               158,218
PL.CONTRIBUTION                  67,801
PL.OPERATING_PROFIT              53,549
Budget operating profit          68,220
Operating profit variance       −14,671
Food sales                      191,100
FC.ACTUAL_CONSUMPTION   food     61,343
FC.EXPECTED_USAGE       food     60,400
FC.ACTUAL_VS_EXPECTED   food        943
```

### Extension — recommended additions (G-27)

```
PL.CHANNEL_COST                   3,600
PL.DIRECT_LABOUR                 84,317
PL.OTHER_DIRECT_OPERATING         2,500
PL.SHARED_COST                   14,252
PL.OWNER_STRUCTURAL_COST         26,000
PL.OWNER_RESULT                  27,549

FC.ACTUAL_COST_PCT      food     32.10%
FC.BUDGET_BENCHMARK     food     57,330
FC.BUDGET_GAP           food      4,013
FC.MENU_MIX_EFFECT      food      3,070
FC.EXPECTED_COST_PCT    food     31.61%

FC.ACTUAL_CONSUMPTION   bev       6,439
FC.EXPECTED_USAGE       bev       6,180
FC.ACTUAL_VS_EXPECTED   bev         259
FC.BUDGET_BENCHMARK     bev       6,028
FC.BUDGET_GAP           bev         411
FC.MENU_MIX_EFFECT      bev         152
FC.ACTUAL_COST_PCT      bev      23.50%
```

### Cross-file reconciliation — all exact, difference of zero

```
POS food revenue        191,100  =  P&L food sales
POS beverage revenue     27,400  =  P&L beverage sales
Meal-period revenue     228,500  =  PL.NET_SALES
Meal-period budget      232,000  =  budget net sales
Labour cost              84,317  =  P&L payroll
Labour budget cost       79,112  =  T6 direct labour
```

### Still needed

No golden values yet exist for `RV`, `LB`, `CT`, `OC`, `MN` or `MAT`. The fixture supports all of
them — meal-period actual and budget columns, labour hours and rates, item-level units and costs.
Derive and freeze them as part of slices 6, 7 and 9, following the pattern in
`tests/golden/test_amberside_parity.py`.
