# Development Plan — Restaurant Performance Review R1

**Status:** proposed, awaiting sign-off
**Baseline:** v4.2 wireframe + R1 Engineering Freeze v0.1 (`docs/source/`)
**Review that informed it:** `docs/review/01-plan-review.md`

---

## 1. What we are building

A multi-tenant web application that takes a restaurant's own monthly reports, maps them once,
turns them into a reconciled Management P&L, and then drives a disciplined review loop that ends in
a signed Owner Pack — with every number traceable back to the file it came from.

The product's defensible claim is **traceability**: *raw file → staging row → canonical fact →
immutable calculation snapshot → signed pack*, where nothing upstream is ever rewritten. Every
technical decision in this plan serves that claim. If a shortcut would break it, the shortcut is
not available.

**Non-goals for R1:** billing, multi-currency per outlet, mobile apps, POS connectors, AI narrative
generation, anything that bypasses the traceability chain.

---

## 2. Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│  apps/web            Next.js + TypeScript, deployed on Vercel     │
│                      Presentation only. Never computes money.     │
│                      Never writes canonical facts.                │
└───────────────────────────┬──────────────────────────────────────┘
                            │  typed contracts (packages/contracts)
┌───────────────────────────▼──────────────────────────────────────┐
│  api                 FastAPI + Python                             │
│                      Auth/context checks · upload orchestration   │
│                      Import commits · calc runs · review gates    │
│                      Pack generation · signed URLs                │
└──────┬──────────────────────────────────────┬────────────────────┘
       │                                      │
┌──────▼───────────────────┐   ┌──────────────▼────────────────────┐
│ packages/import_engine   │   │ packages/calc_engine              │
│ parse · fingerprint      │   │ pure Decimal functions            │
│ map · validate           │   │ stable calc_ids                   │
│ → canonical DTOs         │   │ no DB, no clock, no randomness    │
└──────────────────────────┘   └───────────────────────────────────┘
                            │
┌───────────────────────────▼──────────────────────────────────────┐
│  Supabase   PostgreSQL (RLS) · Auth · Storage                     │
└──────────────────────────────────────────────────────────────────┘
```

### The four rules that are not negotiable

1. **The browser never computes an authoritative number.** Anything displayed as a financial value
   comes from a `calc_result` row produced by a server-side run. The prototype's JavaScript uses
   `parseFloat`; none of it may be ported.
2. **Clients never write canonical facts or calculation results.** Those paths run through the API's
   service credentials or tightly-scoped security-definer RPCs. RLS enforces this at the database,
   not only in application code.
3. **`packages/calc_engine` and `packages/import_engine` have no database and no browser
   dependency.** They are pure functions over explicit inputs. This is what makes the golden tests
   meaningful and the calculations auditable.
4. **Missing is not zero.** `NOT_CALCULATED` is a distinct state carrying an `explanation_code`.
   Any division whose denominator is zero or absent returns it.

### Repository layout

```
apps/web/                 Next.js UI
api/                      FastAPI service
packages/contracts/       shared/generated API schemas
packages/calc_engine/     pure calculation functions
packages/import_engine/   parsing, fingerprinting, mapping, validation
supabase/migrations/      SQL migrations (reviewed in PR)
supabase/seed/            reference data + Amberside fixture
tests/golden/             deterministic fixture parity tests
docs/                     this pack
wireframe/                the v4.2 prototype, kept as the UX contract
fixtures/amberside/       the golden fixture, unmodified
```

---

## 3. Slice plan

Each slice is a **vertical** slice: database → engine → API → UI → tests, shippable and
demonstrable. The order follows the freeze's engineering order and is not rearrangeable — slice 3
depends on slice 2's committed facts, slice 4 on slice 3's calc run, and so on.

| # | Slice | Delivers | Depends on |
|---|---|---|---|
| 0 | Groundwork | Repo, CI, environments, golden test running against fixtures with no app code | — |
| 1 | Foundation | Auth, tenancy, outlet, context, periods, settings, materiality, RLS, audit log | 0 |
| 2 | Ingestion | Storage → source file → profile → staging → validation → atomic commit | 1 |
| 3 | P&L | Canonical financial facts → calc run → management ladder → reconciliation → SEQUENCE | 2 |
| 4 | Review loop | FRAME → shortlist → diagnosis → dispositions → actions → Owner Pack → sign-off | 3 |
| 5 | Food cost | T3 actual consumption → budget benchmark → expected usage → two-story bridge → C02 | 4 |
| 6 | Revenue | Meal-period volume/spend decomposition and contribution | 4 |
| 7 | Labour & other costs | `LB` and `OC` engines and screens | 4 |
| 8 | Expected usage & C02 detail | Detailed yield/portion/production/waste tests | 5 |
| 9 | Menu | SCREEN → TRAIL → decision → TEST | 5, 6 |
| 10 | Advanced | Transactions, interactions, connectors | 9 |

**Slices 0–4 are the product.** Everything from 5 onward is analytical depth on top of a working
traceability spine. If time runs short, cut from the end, never from the middle.

---

## 4. Slice 0 — Groundwork

*No application code. The point is to make correctness measurable before there is anything to get
wrong.*

- Monorepo skeleton with the layout above; package boundaries enforced by lint rules
  (`apps/web` may not import `calc_engine`).
- Three environments (`local`, `preview`, `production`) with **separate Supabase projects** for
  dev/preview and production. Preview deployments use preview variables only. No migration or seed
  job may ever point at production.
- CI on every PR: lint, typecheck, unit tests, **golden parity tests**, migration dry-run against a
  throwaway database.
- Protected `main`; short-lived feature branches; migrations reviewed in PR.
- `tests/golden/test_amberside_parity.py` green. **This already works today** — it validates the
  fixture arithmetic directly and needs no application code.

**Done when:** a PR that changes a golden value fails CI.

---

## 5. Slice 1 — Foundation

### Database
Tables: `organisation`, `outlet`, `membership`, `staff_assignment`, `reporting_period`,
`restaurant_context`, `setting`, `materiality_setting`, `audit_log`, plus the platform reference
tables `ladder_framework`, `ladder_line`, `calc_definition`, `driver_taxonomy`,
`template_definition`.

Applying the review's findings:
- Composite tenancy foreign keys so cross-tenant rows are **unrepresentable** (G-02).
- RLS enabled on every tenant table with `has_org_access()` / `has_outlet_access()` helpers (G-01).
- Staff access requires an active, unexpired `staff_assignment` and writes to `audit_log` (G-09).
- Immutability triggers on versioned records (G-05).
- Indexes with the tables, not later (G-08).

### API
`/auth/context`, `/organisations`, `/outlets`, `/outlets/{id}/context`, `/periods`, `/settings`,
`/materiality`.

### UI
Auth journey (sign-in, invite accept, password reset — **needs design**, G-41), organisation/outlet
creation (**needs design**, G-40), SC17 context card, SC16 settings and users, and the `STATES`
component library.

> **Build `STATES` first.** It is the component library's visual contract and the single place to
> fix the accessibility defects G-44 to G-48 — complete the ARIA tab pattern, add a keyboard
> interaction model, make the table primitive emit `scope` and `<caption>` by construction, require
> a label on every field, and replace `title` tooltips with an accessible disclosure. Fixing these
> once in primitives costs days; fixing them across 45 screens costs weeks.

**Done when:** a new user is invited, signs in, creates an organisation, an outlet, a context
version and a period; a user from another organisation provably cannot read any of it (RLS test);
and every staff read is in `audit_log`.

---

## 6. Slice 2 — Ingestion

### Engine (`packages/import_engine`)
CSV/XLSX parsers · fingerprinting · the four-tier matching hierarchy · the closed transform list ·
the validation framework · deterministic canonical DTOs. No database access.

### Database
`source_file`, `source_profile`, `profile_version`, `column_mapping`, `account_mapping`,
`item_mapping`, `value_mapping`, `transform_rule`, `import_batch`, `staging_row`,
`validation_result`.

Applying the review's findings:
- `NULLS NOT DISTINCT` on `account_mapping` and `account` so the "one source account → one ladder
  line" invariant is actually enforced (G-03).
- Fingerprint matching scoped to `(organisation_id, outlet_id, template_code)` with an explicit
  collision path (G-33).
- Commit is atomic and **idempotent** under retry (G-36).

### API
The import endpoints from the spec, plus file-safety controls that are currently unspecified (G-35):
size cap, row limit, upload timeout, content-type verification, XLSX formula-injection and
zip-bomb protection, malware scanning.

### UI
SC03 upload centre, SC04 mapping wizard, SC05 import result, SC06 data readiness, ST01–ST04 staff
tools.

### The fixture is the acceptance test — and it is deliberately awkward
`Amberside_PnL_Jul2026.csv` is **wide** (the period is the column header `July_2026`) while
`Template_PnL.csv` is **long** with a `Period` column. Stock, labour, meal-period and customer-source
files carry no period column at all. This is not a fixture defect (G-30) — it forces the
`unpivot month columns` and `fixed value` transforms and real profile detection rather than a
happy-path parse. **Do not reformat the fixture to make ingestion easier.**

Also: never map `Amberside_Stock_Jul2026.csv`'s `Expected_Usage` column to a canonical fact (G-31).
Expected usage is derived from T2 × T4A; importing it makes the two-story bridge circular.

**Done when:** all ten Amberside files parse, map (reusing a profile on the second run), validate,
and commit atomically; a mid-commit failure leaves zero canonical facts; a duplicate batch blocks
until explicitly superseded; and a committed batch cannot be edited even by the service role.

---

## 7. Slice 3 — P&L

### Engine (`packages/calc_engine`)
The `PL` module, `PL.VAR.*`, and `SEQ.FIRST_MATERIAL_MOVEMENT`. Pure Decimal functions with a
stable `calc_id` per result.

Applying the review's findings:
- Quantise to the currency's minor unit with `ROUND_HALF_UP` **at presentation only**, never
  between intermediate steps (G-23).
- Every zero/absent denominator returns `NOT_CALCULATED` with an `explanation_code` (G-22).
- A missing comparator returns `NOT_CALCULATED` with `COMPARATOR_NOT_COMMITTED`, never zero (G-26).
- Document the Laspeyres convention — the interaction term sits in the rate/spend effect, which
  systematically inflates it. Customers *will* reconcile against another convention (G-24).

### Database
`account`, `financial_fact`, `calc_run`, `calc_run_input`, `calc_result`, `calc_dependency`.

- `unique (run_id, calc_id, grain_key)` on `calc_result` (G-04).
- Immutability triggers on committed facts and completed runs (G-05).
- **Resolve G-07 first:** the T6 budget fixture is at ladder grain but `financial_fact.account_id`
  is `NOT NULL`. See OD-03.

### API
`POST /calc-runs`, `GET /calc-runs/{id}/results`, `GET /periods/{id}/reconciliation`.

### UI
SC07 Management P&L with SEQUENCE, SC08 reconciliation.

**Done when:** a calc run on the Amberside fixture reproduces all eleven golden values exactly;
re-running produces an identical result set under a new `calc_run` id; the run is immutable once
complete; and `SEQ.FIRST_MATERIAL_MOVEMENT` identifies the first material ladder movement with the
exact materiality rule that made it material.

---

## 8. Slice 4 — Review loop

This slice completes the **first vertical slice acceptance test** from the freeze and is the point
at which the product is demonstrable end to end.

### Database
`review`, `review_issue`, `diagnosis`, `driver_evidence`, `evidence_request`, `decision`, `action`,
`action_event`, `prior_action_check`, `review_comment`, `pack_version`, `claim`, `claim_citation`,
`signoff`.

- Disposition-keyed CHECK constraints so ACT/INVESTIGATE/MONITOR/ESCALATE requirements are enforced
  by the database, not only by the gate engine (G-06).
- Signed packs immutable; any edit creates the next `pack_version` (G-05).

### Engine
The `RG` review-gate module and the `MAT` materiality module. Plus the four rules that currently
exist **only in the prototype's JavaScript** and must be written down before they are lost (G-28):
- `claimCheck` — every number in claim prose must appear in the engine's output set; banned wording
  (`theft`, `steal`, `fraud`, `guarantee`, `always`, `never`) blocks acceptance.
- `decReq` — the required-field matrix per decision type.
- `decEvGate` — decisions blocked while evidence status is `EVIDENCE REQUIRED`.
- The `fcCalc` rule forcing unsupported driver amounts to zero.

### UI
SC10 frame, SC11 shortlist, SC12 diagnose and decide, SC13 action register, SC14 Owner Pack,
SC15 reviewer workbench, SC26 packs and history, SC25 outlook.

**Done when the freeze's twelve-step acceptance test passes end to end** on a brand-new test
organisation: create outlet/context → upload T1 and T6 → reuse a profile and resolve one new account
→ validate and commit atomically → reconciled Management P&L → immutable calc run → first material
movement → shortlist one issue → valid disposition → action and evidence request → Owner Pack v1 →
reviewer requests changes or signs → all lineage preserved.

**No Food Cost or Menu functionality may bypass this path.**

---

## 9. Slices 5–10 — analytical depth

Built on the completed spine, in the freeze's order. Each follows the same pattern: engine module
with golden values → tables → API → screens → tests.

| Slice | Engine | Key risk |
|---|---|---|
| 5 · Food cost | `FC` | **G-20 must be fixed:** `FC.DECISION_PATH` must branch on `ACTUAL_VS_EXPECTED`, not the budget gap. On the Amberside fixture the budget gap is 4,013 of which 3,070 is menu mix and only 943 is a real actual-vs-expected gap — the prototype's logic sends users hunting for leakage that mostly is not there. Add the fifth `FAVOURABLE_VALIDATE_DATA` branch (G-21). |
| 6 · Revenue | `RV`, `CT` | The volume/spend decomposition is algebraically exact, so the control check cannot fail arithmetically — a failure means a data problem, and the message should say so. |
| 7 · Labour & other | `LB`, `OC` | Labour activity units are **not additive** across role groups in the fixture (G-32). Needs an `activity_basis` discriminator. The engine must never output `OVERSTAFFED` from Labour % alone. |
| 8 · Expected usage & C02 | `FC.DRIVER.*` | The `coverage_key` anti-double-counting rule is the hard part. Two active drivers with overlapping coverage cannot both enter a reconciliation without reviewer override. |
| 9 · Menu | `MN` | The SCREEN class is a **label, not an action**. Interaction metrics are association, never causation. `CM_PER_CONSTRAINED_MINUTE` is `NOT_CALCULATED` unless a constraint is explicitly confirmed. |
| 10 · Advanced | — | The transaction fixture is 10,500 rows; treat it as a performance test, not a correctness test. |

---

## 10. Cross-cutting work

These are not a slice. They are threaded through every slice and are the most commonly skipped work
in projects of this shape.

| Concern | When | Note |
|---|---|---|
| **Background job runner** | **Decide before slice 3** | A calc run over 10,500 rows plus pack PDF generation will not reliably finish inside a Vercel serverless request. This is an architectural decision, not an optimisation — see OD-01 (G-60). |
| Observability | Slice 1 onward | Structured logging with a correlation id per request, error reporting, alerting on failed calc runs and commits. |
| Backup / restore / DR | Slice 1 | The product's value *is* immutable history. Losing it is existential — see OD-02 (G-63). |
| Data retention / GDPR | **Decide before slice 4** | Right-to-erasure versus "signed packs never change" is a genuine conflict needing a real answer, not a policy sentence — see OD-05 (G-64). |
| File safety | Slice 2 | Size caps, row limits, content-type verification, formula-injection and zip-bomb protection, malware scanning (G-35). |
| Rate limiting | Slice 2 | |
| Performance budgets | Slice 3 | P&L render, calc run duration, import commit for a 10,500-row batch. |
| Accessibility | Slice 1, in primitives | G-44 to G-48. Once, in `STATES`. |

---

## 11. Testing strategy

| Layer | What | Where |
|---|---|---|
| Golden parity | The eleven frozen values plus the extensions in the calc registry, recomputed from raw fixtures | `tests/golden/` — **already green today** |
| Engine unit | Every `calc_id`, including `NOT_CALCULATED` paths and zero denominators | `packages/calc_engine/tests/` |
| Import | Each template, each transform, fingerprint matching, each validation severity | `packages/import_engine/tests/` |
| RLS | Cross-tenant read/write attempts must fail **at the database**, with the service role and without | `supabase/tests/` |
| Immutability | Update/delete attempts on committed batches, facts, completed runs, signed packs must all fail | `supabase/tests/` |
| Integration | The twelve-step acceptance path, end to end | `tests/integration/` |
| E2E | The same path through the browser | `apps/web/e2e/` |
| Accessibility | Automated axe pass on every route, plus manual keyboard and screen-reader walkthrough of SC07 and SC14 | CI + manual |

**Calculation changes require a test-fixture update or an explicit "no expected-value change"
statement in the PR.** This is the freeze's rule and it is the main thing standing between this
product and silent numerical drift.

---

## 12. Sequencing summary

```
Slice 0  Groundwork          ── golden tests green, CI gating, environments split
Slice 1  Foundation          ── auth, tenancy, RLS, context, settings, STATES library
Slice 2  Ingestion           ── the Amberside files land as canonical facts, atomically
Slice 3  P&L                 ── eleven golden values reproduced by a real calc run
Slice 4  Review loop         ── ★ twelve-step acceptance test passes end to end
─────────────────────────────── the product exists here ───────────────────────────────
Slice 5  Food cost           ── two-story bridge (fix FC.DECISION_PATH first)
Slice 6  Revenue             ── volume/spend, contribution
Slice 7  Labour & other      ── LB, OC
Slice 8  C02 detail          ── driver tests, coverage_key
Slice 9  Menu                ── SCREEN, TRAIL, decision, TEST
Slice 10 Advanced            ── transactions, interactions, connectors
```

---

## 13. Before any application code is written

Per the freeze's *definition of ready-to-code*, and in this order:

1. **Answer the twelve questions in `05-open-decisions.md`.** Nine are short; three are
   architectural and gate slices 3 and 4.
2. **Accept or amend the proposed slice-1 migrations** in `supabase/migrations/`.
3. **Accept the calc registry** in `docs/contracts/calc-registry.md`, including the `FC.DECISION_PATH`
   correction and the extended golden set.
4. **Design the four missing journeys**: auth, organisation/outlet creation, empty states, error
   states.
5. **Confirm the schema names, import template fields, validation severities, mapping rules and the
   RLS/role matrix** — the freeze's own preconditions.

Work packages ready to hand to development agents are in `03-agent-workpackages.md`.
