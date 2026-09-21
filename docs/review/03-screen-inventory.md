# Screen Inventory

All 45 wireframe screens mapped to proposed routes, owning API surface, backing tables, calculation
modules and build slice. Use this as the traceability sheet: no screen should be built without an
owning slice, and no table should exist without a screen or engine that needs it.

Slice numbering follows the freeze's engineering order (§ *Engineering order*).

Open the prototype at `wireframe/restaurant-review-wireframe-v4.2.html` to see any screen.

---

## v4.3 operational addendum

The analytical inventory below remains the v4.2 contract. OD-07 adds operational screens/states in
`docs/design/v4.3-operational-addendum.md` under separate namespaces so historical IDs are not
renumbered:

- `AUTH01`–`AUTH05`: sign-in, magic link, invite acceptance, password reset, MFA.
- `SETUP01`–`SETUP05`: organisation/outlet bootstrap, context, first period, completion.
- `STATE01`–`STATE05`: first-run/empty, permission, error/recovery and neutral not-found states.

These close the operational design gaps G-40–G-43 without changing any existing SC/MN/ST analytical
screen.

---

## Customer navigation map (v4.2 six-area shell)

```
Home ............... SC01, SC02
Data Centre ........ SC03, SC04, SC05, SC06
Analysis ........... SC07, SC08                          (Management P&L / SEQUENCE, Reconciliation)
                     SC18, SC19, SC20                    (Revenue → meal period, source, contribution)
                     SC09, SC27, SC28                    (F&B cost → expected usage → C02 tests)
                     SC21, SC22                          (Labour, Other costs)
                     MN01–MN12                           (Menu & product)
Review & Actions ... SC10, SC11, SC12, SC13, SC25, SC15
Reports & History .. SC14, SC26
Settings ........... SC17, SC16, ST01–ST04, MAP, STATES, COVER
```

---

## 1 · Foundation and context — slice 1

| ID | Screen | Proposed route | API | Tables | Calc |
|---|---|---|---|---|---|
| SC01 | Amberside Bistro (home / outlet overview) | `/o/[org]/outlet/[outlet]` | `GET /outlets/{id}/overview` | `outlet`, `reporting_period`, `review` | read-only summary of latest `calc_run` |
| SC02 | Amberside Bistro (period home) | `/o/[org]/outlet/[outlet]/period/[period]` | `GET /periods/{id}/home` | `reporting_period`, `review`, `import_batch` | — |
| SC17 | Restaurant context card | `/o/[org]/outlet/[outlet]/context` | `GET/POST /outlets/{id}/context` | `restaurant_context` (versioned) | — |
| SC16 | Settings and users | `/o/[org]/settings` | `GET/POST /organisations/{id}/settings`, `/members` | `setting`, `materiality_setting`, `membership` | `MAT` inputs |

> **Missing from the wireframe** (G-40, G-41): organisation/outlet creation, auth sign-in, invite
> acceptance, password reset. These are slice-1 prerequisites with no design yet.

## 2 · Ingestion — slice 2

| ID | Screen | Proposed route | API | Tables | Calc |
|---|---|---|---|---|---|
| SC03 | Upload centre | `…/data/upload` | `POST /imports/upload` | `source_file`, `import_batch` | — |
| SC04 | Mapping wizard | `…/data/batch/[batch]/mapping` | `POST /imports/{id}/parse`, `/mapping/confirm` | `source_profile`, `profile_version`, `column_mapping`, `account_mapping`, `item_mapping`, `value_mapping`, `transform_rule` | — |
| SC05 | Import result | `…/data/batch/[batch]/result` | `POST /imports/{id}/validate`, `GET /exceptions` | `staging_row`, `validation_result` | — |
| SC06 | Data readiness | `…/data/readiness` | `GET /periods/{id}/readiness` | `import_batch`, `validation_result`, `template_definition` | readiness is derived, not a calc result |
| ST02 | Profile builder (staff) | `/staff/profiles/[profile]` | `GET/POST /staff/profiles` | `profile_version`, `transform_rule` | — |
| ST03 | Drift queue (staff) | `/staff/drift` | `GET /staff/drift` | `profile_version`, `import_batch` | — |

## 3 · P&L and reconciliation — slice 3

| ID | Screen | Proposed route | API | Tables | Calc |
|---|---|---|---|---|---|
| SC07 | Management P&L | `…/analysis/pnl` | `GET /calc-runs/{id}/results?module=PL` | `financial_fact`, `ladder_line`, `calc_result` | `PL.*`, `PL.VAR.*`, `SEQ.FIRST_MATERIAL_MOVEMENT` |
| SC08 | Reconciliation | `…/analysis/reconciliation` | `GET /periods/{id}/reconciliation` | `financial_fact`, `validation_result`, `calc_run_input` | cross-file tie-outs |

## 4 · Review loop — slice 4

| ID | Screen | Proposed route | API | Tables | Calc |
|---|---|---|---|---|---|
| SC10 | Review: Frame | `…/review/frame` | `GET/POST /reviews/{id}/frame` | `review`, `materiality_setting`, `restaurant_context` | `MAT.*` |
| SC11 | Review: Shortlist | `…/review/shortlist` | `GET/POST /reviews/{id}/issues` | `review_issue` | `MAT.*`, `SEQ.*` |
| SC12 | Issue: Diagnose and decide | `…/review/issue/[issue]` | `POST /issues/{id}/diagnosis`, `/decision` | `diagnosis`, `driver_evidence`, `evidence_request`, `decision` | `RG.*` gates, `decReq` matrix |
| SC13 | Action register | `…/review/actions` | `GET/POST /reviews/{id}/actions` | `action`, `action_event`, `prior_action_check` | — |
| SC14 | Owner Pack | `…/reports/pack/[version]` | `POST /reviews/{id}/packs`, `GET /packs/{id}` | `pack_version`, `claim`, `claim_citation` | `claimCheck` validation |
| SC15 | Reviewer workbench | `…/review/reviewer` | `POST /packs/{id}/signoff`, `/comments` | `signoff`, `review_comment` | `RG.*` gate results |
| SC26 | Packs and history | `…/reports/history` | `GET /reviews?outlet=…` | `pack_version`, `signoff`, `calc_run` | — |
| SC25 | Outlook: Budget and forecast | `…/review/outlook` | `GET /periods/{id}/outlook` | `financial_fact` (budget/forecast scenarios) | `PL.VAR.*` forward view |

## 5 · Food & beverage cost — slice 5

| ID | Screen | Proposed route | API | Tables | Calc |
|---|---|---|---|---|---|
| SC09 | Food and beverage cost | `…/analysis/fb-cost` | `GET /calc-runs/{id}/results?module=FC` | `stock_fact`, `item_sales_fact` | `FC.ACTUAL_CONSUMPTION`, `FC.BUDGET_BENCHMARK`, `FC.BUDGET_GAP`, `FC.MENU_MIX_EFFECT`, `FC.ACTUAL_VS_EXPECTED`, `FC.DECISION_PATH` |
| SC27 | Expected usage builder | `…/analysis/fb-cost/expected-usage` | `GET /periods/{id}/expected-usage` | `item_sales_fact`, `item_cost_snapshot`, `recipe_version`, `recipe_line` | `FC.EXPECTED_USAGE`, `FC.EXPECTED_COST_PCT` |
| SC28 | Investigation path and test sheets (C02) | `…/analysis/fb-cost/investigation` | `POST /issues/{id}/driver-evidence` | `driver_evidence`, `driver_taxonomy` | `FC.DRIVER.*`, `FC.SUPPORTED_DRIVER_TOTAL`, `FC.RESIDUAL`, C02 yield/portion/production/waste tests |

## 6 · Revenue — slice 6

| ID | Screen | Proposed route | API | Tables | Calc |
|---|---|---|---|---|---|
| SC18 | Meal-period revenue | `…/analysis/revenue/meal-periods` | `GET /calc-runs/{id}/results?module=RV` | `meal_period_fact` | `RV.ACTIVITY_UNITS`, `RV.AVG_SPEND`, `RV.VOLUME_EFFECT`, `RV.SPEND_EFFECT`, `RV.TOTAL_VARIANCE` |
| SC19 | Customer source | `…/analysis/revenue/sources` | `GET /calc-runs/{id}/results?grain=source` | `customer_source_fact` | `RV.*` at source grain |
| SC20 | Contribution | `…/analysis/revenue/contribution` | `GET /calc-runs/{id}/results?module=CT` | `meal_period_fact`, `customer_source_fact`, `financial_fact` | `CT.CONTRIBUTION`, `CT.CONTRIBUTION_PER_ACTIVITY_UNIT`, `CT.CONTRIBUTION_MARGIN_PCT` |

## 7 · Labour and other costs — slice 7

| ID | Screen | Proposed route | API | Tables | Calc |
|---|---|---|---|---|---|
| SC21 | Labour and activity | `…/analysis/labour` | `GET /calc-runs/{id}/results?module=LB` | `labour_fact` | `LB.HOURS_EFFECT_RAW`, `LB.RATE_EFFECT_RAW`, `LB.HOURS_PER_ACTIVITY`, `LB.COST_PER_ACTIVITY`, `LB.OVERTIME_*` |
| SC22 | Other restaurant costs | `…/analysis/other-costs` | `GET /calc-runs/{id}/results?module=OC` | `financial_fact` | `OC.QUANTITY_EFFECT`, `OC.RATE_EFFECT`, `OC.TOTAL_VARIANCE` |

## 8 · Menu & product (SCREEN / TRAIL / TEST) — slice 9

| ID | Screen | Proposed route | API | Tables | Calc |
|---|---|---|---|---|---|
| MN01 | Menu review home | `…/menu` | `GET /menu/home` | `menu_population`, `item_period_metric` | — |
| MN02 | Menu data readiness | `…/menu/readiness` | `GET /menu/readiness` | `item_sales_fact`, `item_cost_snapshot`, `recipe_version` | — |
| MN03 | SCREEN: Classic SCREEN | `…/menu/screen` | `GET /menu/screen` | `item_period_metric` | `MN.UNITS`, `MN.MIX_PCT`, `MN.EQUAL_SHARE`, `MN.POPULARITY_THRESHOLD`, `MN.CLASSIC_CM_PER_UNIT`, `MN.CM_WEIGHTED_BENCHMARK`, `MN.SCREEN_CLASS` |
| MN04 | T · Trend and target | `…/menu/trail/trend` | `GET /menu/trail/t` | `item_period_metric`, `change_event`, `item_availability` | trend classification (`stable`/`moving`/`distorted`/`evidence_required`) |
| MN05 | R · Retained economics | `…/menu/trail/retained` | `GET /menu/trail/r` | `item_period_metric` | `MN.RETAINED_CM_PER_UNIT` |
| MN06 | A · Activity and capacity | `…/menu/trail/activity` | `GET /menu/trail/a` | `activity_evidence` | `CM_PER_CONSTRAINED_MINUTE` (only when constraint confirmed, else `NOT_CALCULATED`) |
| MN07 | I · Interactions | `…/menu/trail/interactions` | `GET /menu/trail/i` | `interaction_evidence`, `transaction_fact` | association metrics — **labelled association, never causation** |
| MN08 | L · Line-up role | `…/menu/trail/lineup` | `GET/POST /menu/trail/l` | `lineup_role` | human input only |
| MN09 | TRAIL Board | `…/menu/trail/board` | `GET /menu/trail/board` | all TRAIL tables | aggregation only |
| MN10 | Menu decision | `…/menu/decision/[item]` | `POST /menu/decisions` | `menu_decision` | `decReq`/`decEvGate` equivalents |
| MN11 | TEST workspace | `…/menu/test/[test]` | `POST /menu/tests`, `/results` | `menu_test`, `menu_test_result` | baseline/test window locked at start |
| MN12 | History and reports | `…/menu/history` | `GET /menu/history` | `change_event`, `menu_test_result` | — |

## 9 · Staff, internal and reference

| ID | Screen | Proposed route | Slice | Notes |
|---|---|---|---|---|
| ST01 | Setup workspace | `/staff` | 2 | Requires active `staff_assignment`; every read audited to `audit_log`. |
| ST02 | Profile builder | `/staff/profiles/[id]` | 2 | See ingestion. |
| ST03 | Drift queue | `/staff/drift` | 2 | See ingestion. |
| ST04 | Time and service log | `/staff/service-log` | 2 | Setup-service effort tracking. |
| MAP | Review map | `/internal/map` | 1 | Internal reference; keep behind a flag or staff role. |
| STATES | States and components | `/internal/states` | 1 | **Build this first** — it is the component library's visual contract, and the natural home for the a11y fixes G-44 to G-48. |
| COVER | Coverage of analysis views (99-view audit) | `/internal/coverage` | 1 | Internal traceability audit. |

---

## Coverage check against the build contract

| Contract stage | Screens | Complete? |
|---|---|---|
| Review | SC10, SC11 | Yes |
| Issues | SC11, SC12 | Yes |
| Evidence | SC28, SC12, SC06 | Yes |
| Diagnosis | SC12, SC09, SC18–SC22 | Yes |
| Decision | SC12, MN10 | Yes |
| Action / Test | SC13, MN11 | Yes |
| Verification | SC13 (prior-action check), SC15, SC26 | Yes |

| Traceability layer | Screen | Complete? |
|---|---|---|
| Raw file | SC03 | Yes |
| Staging | SC05 | Yes |
| Canonical facts | SC06, SC08 | Yes |
| Calc snapshot | SC07, SC26 | Yes |
| Review / signed pack | SC14, SC15, SC26 | Yes |

**Conclusion:** analytically complete. The gaps are operational (onboarding, auth, empty states,
errors) and are tracked as G-40 to G-43.
