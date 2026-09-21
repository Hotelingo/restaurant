# Agent Work Packages

Self-contained briefs for handing work to development agents. Each is scoped so an agent can
complete it without needing to interview anyone, and so its output can be reviewed without reading
the whole codebase.

---

## How to run agents on this project

**One work package per agent, one branch per package, one PR per branch.** Do not give an agent
"build slice 2" — that is a fortnight of work with a dozen decisions in it, and you will get a
plausible-looking result you cannot review. Give it WP-04.

**Every agent brief must include this preamble:**

> Read `docs/plan/01-development-plan.md` §2 before writing code. Four rules are not negotiable:
> the browser never computes an authoritative number; clients never write canonical facts or
> calculation results; `calc_engine` and `import_engine` have no database or browser dependency;
> and missing is never zero — a zero or absent denominator returns `NOT_CALCULATED` with an
> `explanation_code`. If your work requires breaking one of these, stop and raise it instead.
>
> Do not port arithmetic from `wireframe/restaurant-review-wireframe-v4.2.html`. Its JavaScript uses
> `parseFloat` and is a UX reference only. It is, however, the **behavioural** reference: where it
> and the written spec disagree, check `docs/review/02-gap-register.md` before assuming either is
> right.
>
> If a golden value changes, your PR must either update the fixture with justification or state
> explicitly "no expected-value change". A silent change is a failed review.

**Review each PR against:** the acceptance criteria in `02-backlog.md`, the definition of done in
`04-definition-of-done.md`, and whether the tests would actually fail if the code were wrong.

**Sequencing.** WP-01 to WP-03 can run in parallel. WP-04 onward are ordered — do not start one
until its dependency has merged.

---

## WP-01 · Golden parity in CI
**Depends on:** nothing · **Size:** S · **Story:** S0-4

The parity test already exists and passes. Wire it into CI so it gates every PR.

- Add a workflow running `tests/golden/` on every PR and on `main`.
- Standard library only — no dependency on application code.
- Verify the gate works by opening a throwaway PR that perturbs a fixture value and confirming CI
  goes red.

**Done:** a PR changing a golden value cannot merge.

---

## WP-02 · Monorepo skeleton and boundary enforcement
**Depends on:** nothing · **Size:** M · **Stories:** S0-1, S0-3

Create the layout in the development plan. The valuable part is **enforcement**, not the folders.

- Lint rules that fail the build when `apps/web` imports `calc_engine` or `import_engine`, and when
  `calc_engine` imports any database or HTTP library.
- Three environments with separate Supabase projects for dev/preview and production.
- Prove the production guard: attempt to run a migration against production from CI and show it is
  refused.
- `README.md` with local setup for each package.

**Done:** a deliberate boundary violation fails CI.

---

## WP-03 · Component library from the wireframe (`STATES`)
**Depends on:** nothing · **Size:** L · **Story:** S1-8

Port the wireframe's design system into audited React primitives. **This is the highest-leverage
work package in the project** — the accessibility defects are cheap to fix once here and expensive
to fix across 45 screens later.

Source of truth: the `:root` token block and the `STATES` screen in
`wireframe/restaurant-review-wireframe-v4.2.html`.

- Port tokens as CSS custom properties: light, `prefers-color-scheme: dark`, and explicit
  `[data-theme]` override. The palette is already WCAG AA verified — **do not re-pick colours.**
- Primitives: button, segmented control, chip/status badge, field, select, table, tabs, card,
  disclosure, toast, empty state, skeleton.
- Each has a documented state matrix: default, hover, focus, active, disabled, loading, empty, error.

Four defects to fix **by construction**, so they cannot recur:

| Gap | Requirement |
|---|---|
| G-44 | Tabs implement the full ARIA pattern: `role="tab"`, `aria-selected`, `aria-controls`. A `tablist` with no tabs is worse than no ARIA. |
| G-45 | Arrow-key navigation and roving tabindex on every composite widget. There are currently zero `keydown` handlers in the prototype. |
| G-46 | The table primitive emits `scope` on every `<th>` and requires a `<caption>`. 486 `<th>` with no `scope` is not navigable by screen reader. |
| G-47 | The field primitive requires a visible label. Placeholder-as-label must be impossible to express. |
| G-48 | Explanatory text uses an accessible disclosure/popover, never `title`. Tooltips are invisible on touch. |

- Preserve the four responsive breakpoints (1240 / 900 / 820 / 700) and `prefers-reduced-motion`.
- Automated axe pass with zero violations; a documented manual keyboard walkthrough.

**Done:** every primitive is keyboard-operable and screen-reader-correct, and the axe suite is green
in CI.

---

## WP-04 · Tenancy schema and RLS
**Depends on:** WP-02 · **Size:** L · **Stories:** S1-1, S1-2

Implement the proposed slice-1 migrations, **after** they have been accepted (see
`05-open-decisions.md`). Start from `supabase/migrations/`, not from
`docs/source/Supabase_Schema_Draft_v0_1.sql` — the draft has eleven known defects.

The hard requirement, and the one most likely to be got wrong:

> **A cross-tenant row must be unrepresentable, not merely unlikely.** A row carrying org A's
> `organisation_id` and org B's `outlet_id` must be rejected by the database. Composite foreign keys
> on `(organisation_id, outlet_id)` with `unique (organisation_id, id)` on parents. RLS alone is not
> sufficient — it filters on `organisation_id` and would happily expose a mislinked row.

- RLS on every tenant table, with `security definer` helper functions.
- Immutability triggers on versioned and committed records.
- Indexes ship with the tables.
- An RLS test suite running against real PostgreSQL, not a mock, covering: cross-org reads, outlet
  scoping, anonymous access, and client writes to `financial_fact` and `calc_result` (which must
  fail under every role).

**Done:** the RLS suite passes and a deliberate cross-tenant insert is rejected by the database.

---

## WP-05 · Import engine — parsers, fingerprinting, transforms
**Depends on:** WP-02 · **Size:** L · **Stories:** S2-1, S2-2, S2-3

Pure `packages/import_engine`. **No database, no network.** Tests run with no database available.

- CSV and XLSX to a uniform intermediate representation; header detection, encoding, BOM,
  thousands separators.
- Fingerprint per the spec — **row count excluded** — scoped to
  `(organisation_id, outlet_id, template_code)` with an explicit collision path (G-33).
- All four match tiers; confidence bands as settings, not constants.
- All thirteen transforms, each unit-tested. **No mechanism for arbitrary customer code.**

The fixture is the acceptance test and it is deliberately awkward:

> `fixtures/amberside/upload_files/Amberside_PnL_Jul2026.csv` is **wide** — the period is the column
> header `July_2026` — while `fixtures/amberside/templates/Template_PnL.csv` is **long** with a
> `Period` column. Stock, labour, meal-period and customer-source files carry no period column at
> all. This is intentional (G-30): it forces `unpivot month columns` and `fixed value` and real
> profile detection. **Do not reformat the fixture to make your parser's life easier.** If you find
> yourself editing a file under `fixtures/`, stop.

**Done:** all ten Amberside files parse to canonical DTOs; re-parsing matches the existing profile.

---

## WP-06 · Import persistence, validation and atomic commit
**Depends on:** WP-04, WP-05 · **Size:** L · **Stories:** S2-4, S2-5, S2-6, S2-7

The staging, validation and commit layer, plus upload safety.

- Mapping tables against immutable profile versions. **Use `NULLS NOT DISTINCT`** — the draft
  schema's unique constraints are silently unenforced when `account_code` is NULL, which the import
  spec explicitly supports (G-03). Test: insert a duplicate name-only account mapping and expect
  rejection.
- Validation framework with rule code, severity, scope, actual, expected, message, remediation.
  Cross-file rules at 0.5% and 2%. On the Amberside fixture the POS↔P&L check must pass with a
  difference of **exactly zero**.
- Nine-step atomic commit. Test with an injected failure at **each** step and assert zero canonical
  facts committed. Idempotent under retry (G-36).
- File safety (G-35): size cap, row limit, timeout, content-type verification, XLSX
  formula-injection and zip-bomb protection, malware scanning. Signed URLs only — prove an
  unauthenticated fetch fails.
- **Never map `Amberside_Stock_Jul2026.csv`'s `Expected_Usage` column to a canonical fact** (G-31).
  Expected usage is derived from T2 × T4A; importing it makes the two-story bridge circular and
  unfalsifiable.

**Done:** all ten fixture files commit atomically; every injected failure leaves zero facts; a
committed batch cannot be edited even by the service role.

---

## WP-07 · Calculation engine — `PL`, `PL.VAR`, `SEQ`
**Depends on:** WP-02 · **Size:** L · **Stories:** S3-1, S3-2, S3-4

Pure `packages/calc_engine`. **No database, no clock, no randomness.** Read
`docs/contracts/calc-registry.md` first — it is the contract, and it corrects the spec in two places.

- Eleven ladder `calc_id`s, `PL.VAR.*` with both `raw_delta` and `profit_effect` (cost lines
  sign-flipped so favourable is positive), and `SEQ.FIRST_MATERIAL_MOVEMENT`.
- Decimal throughout. Quantise to the currency minor unit with `ROUND_HALF_UP` **at presentation
  only, never between intermediate steps** (G-23).
- Every zero or absent denominator returns `NOT_CALCULATED` with an `explanation_code` (G-22). A
  missing comparator returns `COMPARATOR_NOT_COMMITTED` (G-26).
- `SEQ` returns the first material movement, its impact and the **exact rule** that made it
  material — and **never names an operating cause.**

Golden targets, all verified against the raw fixture:

```
PL.NET_SALES        228,500     PL.CONTRIBUTION        67,801
PL.PRODUCT_COST      70,282     PL.OPERATING_PROFIT    53,549
PL.PRODUCT_MARGIN   158,218     PL.OWNER_RESULT        27,549
Budget operating profit  68,220     Variance  −14,671
```

**Done:** unit tests pass with no database available; all golden values reproduce exactly.

---

## WP-08 · Calc run persistence and P&L screens
**Depends on:** WP-06, WP-07 · **Size:** L · **Stories:** S3-3, S3-5

- `calc_run`, `calc_run_input`, `calc_result`, `calc_dependency`. **`unique (run_id, calc_id,
  grain_key)`** — without it a retried run duplicates immutable results with no natural repair
  (G-04). Results immutable once the run completes.
- Only committed batches may feed a run.
- SC07 and SC08 built on WP-03's primitives.
- **`NOT_CALCULATED` must be a designed visual state, distinct from zero** — not a dash that reads
  as "nothing happened".
- Every figure traceable to its `calc_result`, then to batch and source file.

**Done:** a run on the Amberside fixture reproduces all eleven golden values through the real
stack; re-running yields an identical result set under a new run id.

---

## WP-09 · Review loop and gates
**Depends on:** WP-08 · **Size:** XL — **split before assigning**

Suggested split: (a) review/FRAME/shortlist, (b) diagnosis and evidence, (c) decisions and actions,
(d) pack, claims and sign-off, (e) the twelve-step acceptance test.

The part most likely to be got wrong, and the part that matters most:

> **Write down the four rules that currently exist only in the prototype's JavaScript** (G-28), then
> implement them **server-side**:
> - `claimCheck` — every number in claim prose must appear in the engine's output set; banned
>   wording (`theft`, `steal`, `fraud`, `guarantee`, `always`, `never`) blocks acceptance. This is
>   one of the best ideas in the product and it is in no specification document.
> - `decReq` — the required-field matrix per decision type, enforced by **database CHECK
>   constraints** keyed off the disposition, not only by the gate engine (G-06).
> - `decEvGate` — decisions blocked while evidence status is `EVIDENCE REQUIRED`.
> - Unsupported driver evidence forces its amount to zero and disables the input.

**Done:** the freeze's twelve-step acceptance test runs green against a brand-new test organisation,
with lineage asserted at every hop.

---

## WP-10 · Food cost engine
**Depends on:** WP-09 · **Size:** L · **Slice 5**

**Read gap G-20 before writing any code.**

> The prototype's `fcCalc` branches to "OPERATING / CONTROL GAP" on the **budget gap**
> (`consumption − benchmark`). The written spec says the budget benchmark "does not prove operating
> leakage", and it is right. On the Amberside fixture the budget gap is 4,013, of which 3,070 is
> menu mix and only 943 is a genuine actual-vs-expected gap — so the prototype's logic sends users
> hunting for leakage that mostly is not there.
>
> **Branch on `FC.ACTUAL_VS_EXPECTED` and its residual. Show the budget gap as context only.**
> Add the fifth branch `FAVOURABLE_VALIDATE_DATA` (G-21) — a favourable variance deserving a data
> check is correct and is missing from the spec's four-value enum.

Golden targets:

```
FC.ACTUAL_CONSUMPTION  food 61,343   bev  6,439
FC.EXPECTED_USAGE      food 60,400   bev  6,180
FC.ACTUAL_VS_EXPECTED  food    943   bev    259
FC.BUDGET_BENCHMARK    food 57,330   FC.BUDGET_GAP food 4,013
FC.MENU_MIX_EFFECT     food  3,070   FC.ACTUAL_COST_PCT food 32.10%
```

The bridge closes exactly: `MENU_MIX_EFFECT + ACTUAL_VS_EXPECTED = BUDGET_GAP`
(3,070 + 943 = 4,013).

Also: only `supported` or `validated` evidence enters `FC.SUPPORTED_DRIVER_TOTAL`; `FC.RESIDUAL`
stays visible whether positive, negative or zero; and two drivers with overlapping `coverage_key`
cannot both enter one reconciliation without reviewer override.

**Done:** all food-cost golden values reproduce, and the decision path routes the Amberside case to
a menu-economic handoff rather than a leakage hunt.

---

## Later packages

WP-11 revenue (`RV`, `CT`) · WP-12 labour and other costs (`LB`, `OC` — note that labour activity
units are **not additive** across role groups in the fixture, G-32) · WP-13 C02 detail ·
WP-14 menu SCREEN/TRAIL/TEST · WP-15 advanced transactions.

Decompose these only once slices 1–4 have shipped. Their shape will change based on what those
slices teach, and decomposing now would be false precision.
