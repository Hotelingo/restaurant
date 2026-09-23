# Plan Review — Restaurant Performance Review

**Reviewer role:** full-stack engineering review of the v4.2 wireframe and the R1 Engineering Freeze
**Date:** 2026-09-21
**Inputs reviewed:** `docs/source/*`, `wireframe/restaurant-review-wireframe-v4.2.html`, `fixtures/amberside/*`
**Verdict:** **Approved to build, with conditions.** The plan is materially stronger than a typical
pre-build package. The conditions are listed in `02-gap-register.md` and are almost all schema-level
and mechanical, not conceptual.

---

## 1. Executive summary

| Area | Assessment | Confidence |
|---|---|---|
| Product methodology | Strong. Genuinely differentiated. | High |
| Screen coverage | Complete for R1 and beyond. 45 screens, no orphans. | High |
| Visual design system | Professional, accessible, dark-mode complete. | High |
| Accessibility | Good foundations, four concrete defects to fix in the real build. | High |
| Calculation specification | Algebraically sound. Verified by hand. Edge cases under-specified. | High |
| Golden fixture | **Excellent.** Every stated value reconciles exactly. | High |
| Data model (document) | Comprehensive and well-reasoned. | High |
| SQL schema draft | **Weakest artefact.** ~40% of the modelled tables, zero RLS, five integrity defects. | High |
| Import/mapping spec | Strong design. Fixture files do not match the spec's own templates. | High |
| Non-functional scope | **Largely absent.** Auth lifecycle, observability, retention, file safety. | High |

The single most important finding: **the plan's analytical core is correct and provable.** I
recomputed every golden value in the freeze from the raw CSV fixtures and all eleven tie exactly
(see §5). That is rare and it substantially de-risks the build. The risk in this project is not
"will the numbers be right" — it is schema integrity, tenancy isolation and the unglamorous
non-functional work that has not yet been specified.

---

## 2. The wireframe as a design artefact

### 2.1 What it actually is

This is not a static mock. It is a **working prototype**: 715 KB of HTML containing 246 KB of
JavaScript and 35 KB of CSS, rendering 45 screens with live calculation, state persistence, role
switching, and gate enforcement. The counts in the preservation audit (431 inputs, 117 selects,
76 tables) are mostly JS-generated at runtime, not static markup — which is why a naive grep of
the file finds only 18 `<input>` elements. This matters for handover: **the prototype's JavaScript
is a behavioural specification**, and several business rules exist there and nowhere in the written
specs. Those rules are extracted in §4.3 and must not be lost.

### 2.2 Visual design — good, and measurably so

The design system is coherent and deliberate:

- **Token-driven.** A full custom-property palette on `:root`, redefined for
  `prefers-color-scheme: dark` *and* for an explicit `[data-theme="dark"]` override. This is the
  correct pattern; most hand-built prototypes get one or the other.
- **Typographic discipline.** IBM Plex Sans for prose, IBM Plex Mono for figures. Correct choice —
  tabular figures matter in a financial ladder.
- **Restraint.** Navy/gold/neutral with semantic status colours (green/amber/red/blue/purple).
  No decoration for its own sake. It reads as an audit tool, which is what it is.

I measured WCAG contrast on every foreground/background token pair:

| Pair | Ratio | Result |
|---|---|---|
| `--ink` on `--surface` (light) | 15.53 | Pass AA/AAA |
| `--ink2` on `--surface` | 8.09 | Pass AA/AAA |
| `--mute` on `--surface` | 5.68 | Pass AA |
| `--mute` on `--surface2` | 5.30 | Pass AA |
| `--green` on `--greenbg` | 4.71 | Pass AA |
| `--red` on `--redbg` | 5.74 | Pass AA |
| `--amber` on `--amberbg` | 5.02 | Pass AA |
| `--accent` on `--accentbg` | 5.77 | Pass AA |
| `--gold` on `--navy` | 5.41 | Pass AA |
| `--ink` on `--surface` (dark) | 14.08 | Pass AA/AAA |
| `--mute` on `--surface` (dark) | 5.96 | Pass AA |

Every text pair passes WCAG AA in both themes. `--gold` at 2.63 against white would fail, but it is
used only as a border/underline accent (`border-bottom-color`), never as text on a light surface, so
there is no defect. This palette can be carried into the production app essentially unchanged — a
real saving.

### 2.3 Responsiveness — present and considered

Four layout breakpoints (1240 / 900 / 820 / 700 px) with sensible degradation: the three-column
review chrome collapses the notes rail first, then the nav rail becomes a disclosure, then the
menu board switches to sticky-first-column scrolling. `prefers-reduced-motion` is honoured.
`viewport-fit=cover` and `env(safe-area-inset-top)` are handled. This is more care than most
production apps get.

### 2.4 User-friendliness — the v4.2 refactor is the right call

The core UX decision — collapsing a 45-screen analyst tool behind six customer areas (Home, Data
Centre, Analysis, Review & Actions, Reports & History, Settings) while preserving a "Full v4
detail / review mode" — is correct and well executed. It solves the real problem: the analytical
depth is the product's value, but it is also what makes it unusable for a restaurant manager on a
Tuesday morning. Progressive disclosure with an escape hatch to the full tool is the right shape.

Two UX observations for the production build:

- **The prototype has no genuine "home" state for a first-time, empty organisation.** SC01/SC02
  assume Amberside exists with data loaded. The hardest UX problem in this product is the empty
  state — a new customer with no mapping profile, no committed batch and no calc run. That journey
  needs designing before build, not during.
- **The `title` attribute is used 162 times** to carry explanatory text. Tooltips are invisible on
  touch devices and to keyboard users. In an application whose whole premise is *explaining* why a
  number means what it means, hover-only explanation is a product problem, not just an a11y one.

### 2.5 Accessibility — four concrete defects

Good foundations: 485 `aria-label`s, visible `:focus-visible` rings, an `.sr` utility, semantic
`<button>` elements throughout, no inline `onclick`, `role="status"` on the toast, `localStorage`
access wrapped in `try/catch`. But:

1. **Broken ARIA tab pattern.** `role="tablist"` appears 6 times with **zero** `role="tab"`, zero
   `aria-selected`, zero `aria-controls`. A tablist containing no tabs is worse than no ARIA at all —
   it tells a screen reader to expect a widget that is not there. Either complete the pattern or
   remove `role="tablist"`.
2. **No keyboard interaction model.** There are no `keydown` handlers anywhere. Tabs are not
   arrow-navigable; there is no roving tabindex. Native buttons keep everything *reachable*, but the
   composite widgets do not behave as their roles promise.
3. **486 `<th>` elements, zero `scope`, zero `<caption>`.** In dense multi-header financial tables
   this makes screen-reader navigation effectively impossible. `scope="col"`/`scope="row"` is a
   one-line fix per table and should be non-negotiable for a finance product.
4. **12 inputs use `placeholder` as their only label**, and there are only 9 `<label>` elements for
   18 static inputs (most inputs being JS-generated without labels). Placeholder-as-label fails on
   focus and fails translation.

None of these are hard. All should be fixed *in the component library*, once, rather than screen by
screen — which is an argument for building the production UI from a small set of audited primitives
rather than porting the prototype's markup.

### 2.6 Prototype-only concerns that do not carry forward

- All money arithmetic uses `parseFloat`. Correct for a prototype; the freeze already mandates
  server-side `Decimal`, so this is not a defect, but it confirms **no calculation may be ported
  from the JS as-is**.
- `44 <h1>` elements (one per screen section). Acceptable in a single-document SPA where one section
  is visible; in the Next.js build each route must have exactly one `<h1>`.
- No `@media print`. The Owner Pack is a signed PDF deliverable, and the schema already models it as
  a stored artefact with a SHA-256. Pack rendering should be **server-side**, not browser print —
  so this is a design decision to confirm rather than a bug.

---

## 3. Screen coverage — is anything missing?

45 screens, IDs `SC01`–`SC28` (with `SC23`/`SC24` unused), `ST01`–`ST04`, `MN01`–`MN12`, plus `MAP`,
`STATES` and `COVER`. The full inventory with proposed routes, owning API surface and backing tables
is in `03-screen-inventory.md`.

**Coverage against the build contract** (Review → Issues → Evidence → Diagnosis → Decision →
Action/Test → Verification): complete. Every stage has at least one screen, and the traceability
chain (Raw file → Staging → Canonical facts → Calc snapshot → Review/pack) has a screen at every
layer: SC03 upload, SC04 mapping, SC05 import result, SC06 readiness, SC07 P&L, SC08 reconciliation,
SC14 pack, SC15 reviewer, SC26 history.

**Genuinely missing screens** for R1 — none analytically, but five operational screens are absent:

| Missing | Why it matters |
|---|---|
| Organisation/outlet creation & onboarding | Acceptance criterion #1 of the first vertical slice is "create outlet/context". There is no screen for it. SC17 edits context that already exists. |
| Auth screens (sign-in, invite accept, password reset, MFA) | Supabase Auth is chosen but no auth journey is designed. |
| Empty/first-run states | See §2.4. |
| Error and permission-denied states | `STATES` covers component states, not failure pages. |
| Billing / subscription | Out of R1 scope, but worth an explicit "not in R1" decision. |

`SC23` and `SC24` being unused is worth one sentence of confirmation — either they were deliberately
retired, or two screens were lost in an earlier revision. The preservation audit compares v4 to v4.2
and would not have caught a loss that predates v4.

---

## 4. Calculation engines

### 4.1 Algebraic verification — the decompositions are exact

I verified the variance decompositions symbolically. All three close with **zero residual**, which
means the specified control checks cannot fail for arithmetic reasons:

**Revenue (`RV`):**
```
VOLUME_EFFECT + SPEND_EFFECT
  = (Ua − Uc)·Sc + Ua·(Sa − Sc)
  = Ua·Sc − Uc·Sc + Ua·Sa − Ua·Sc
  = Ua·Sa − Uc·Sc
  = TOTAL_VARIANCE                              ✓ exact
```

**Labour (`LB`):**
```
HOURS_EFFECT_RAW + RATE_EFFECT_RAW
  = (Ha − Hc)·Rc + Ha·(Ra − Rc)
  = Ha·Ra − Hc·Rc
  = actual cost − comparator cost               ✓ exact
```

**Other cost (`OC`):** identical structure. ✓ exact

**Food cost two-story bridge (`FC`):**
```
MENU_MIX_EFFECT + ACTUAL_VS_EXPECTED
  = (EXPECTED − BENCHMARK) + (ACTUAL − EXPECTED)
  = ACTUAL − BENCHMARK
  = BUDGET_GAP                                  ✓ exact
```

All four use the *Laspeyres-with-residual-in-the-second-term* convention (the interaction term is
absorbed into the rate/spend effect). That is a legitimate and common choice, but it is a **material
accounting decision that the spec never states**. The rate effect is systematically inflated by the
interaction term. It must be documented in the calc registry, because a customer's own finance team
will eventually reconcile against a different convention and ask why.

### 4.2 Where the spec is under-determined

These are not errors — they are places where two engineers would write different code:

- **Division by zero is unspecified everywhere.** `AVG_SPEND = revenue / activity_units`,
  `ACTUAL_COST_PCT = consumption / revenue`, `MIX_PCT = item_units / population_units`,
  `EQUAL_SHARE = 1 / eligible_item_count`, `NET_REVENUE_PER_UNIT = revenue / units`. The engine
  contract says `NOT_CALCULATED` is distinct from zero — so every one of these must return
  `NOT_CALCULATED` with an `explanation_code`, never `0`. The prototype currently returns `0`
  (`var pct = sales ? cons/sales : 0`). State the rule once, centrally.
- **No rounding or quantisation policy.** "All money handled with Decimal" is not enough. Specify:
  quantise to the currency's minor unit, `ROUND_HALF_UP`, at *presentation* only, never between
  intermediate steps. Without this, two correct implementations will disagree by cents and the
  golden tests will become flaky.
- **No tolerance constants.** The import spec names 0.5% and 2% tolerances; the calc spec says
  "within currency tolerance" without a number.
- **Missing comparator handling.** What does `PL.VAR.*` return when the comparator scenario has no
  committed batch? `NOT_CALCULATED`, presumably — but it is not stated.
- **`OWNER_RESULT` has no golden value.** Ten of the eleven ladder lines have one. From the fixture
  it is **27,549**. Add it.
- **The golden set covers only `PL` and `FC`.** There are no golden values for `RV`, `LB`, `CT`,
  `OC`, `MN` or `MAT`, yet those engines are all specified. Proposed additions are in
  `docs/contracts/calc-registry.md`.

### 4.3 Rules that exist only in the prototype's JavaScript

These must be captured as written specifications or they will be lost:

- **`claimCheck`** — Owner Pack claim validation. Extracts every number from claim prose and rejects
  the claim if any number is not in the engine's output set; separately rejects banned wording
  (`theft`, `steal`, `fraud`, `guarantee`, `always`, `never`). A failed claim disables the accept
  button. This is one of the most valuable ideas in the whole product and it is **not in any spec
  document.**
- **`decReq(type)`** — the required-field matrix per decision type, and `decEvGate` — decisions that
  are blocked while evidence status is `EVIDENCE REQUIRED`.
- **`fcCalc` driver rows** — a driver row with status `Evidence required` has its amount forced to
  `0` and the input disabled, so unsupported amounts cannot enter the reconciliation. This is the
  anti-double-counting rule made concrete.
- **`matCalc`** — the materiality screen's `amount OR percentage` test.

### 4.4 One substantive methodological contradiction

`FC.DECISION_PATH` in the spec branches to `OPERATING_CONTROL_INVESTIGATION` / `MENU_ECONOMIC_HANDOFF`
/ `VALIDATE_FIRST` / `NO_MATERIAL_GAP`. The prototype's `fcCalc` branches on **`gap = consumption −
budget_benchmark`** — the *budget* gap — to decide whether to show "OPERATING / CONTROL GAP".

But the spec is explicit that the budget benchmark "is a percentage benchmark only; it does not
prove operating leakage", and the whole point of the two-story bridge is that only
`FC.ACTUAL_VS_EXPECTED` (actual versus theoretical usage) can indicate operating control loss —
`FC.MENU_MIX_EFFECT` is a menu-economics question, not a leakage question.

**The prototype routes a menu-mix problem to an operating-control investigation.** On the Amberside
fixture the budget gap is 4,013 of which 3,070 is menu mix and only 943 is actual-vs-expected — so
with a materiality threshold below 4,013 the prototype sends the user to hunt for leakage that is
mostly not there. The written spec is right; the prototype is wrong. The production engine must
branch on `ACTUAL_VS_EXPECTED` (and its residual), with the budget gap shown as context.

The prototype also has a fifth branch ("FAVOURABLE: CHECK STANDARDS AND DATA") that is absent from
the spec's four-value enum. It is a *good* branch — a favourable variance deserving a data check is
exactly right — so add it to the enum rather than dropping it.

---

## 5. Golden fixture verification — all eleven values reconcile

I recomputed every value in the freeze's parity list directly from the raw CSVs. This is the
strongest signal in the package.

| Assertion | Expected | Recomputed | |
|---|---|---|---|
| `PL.NET_SALES` | 228,500 | 228,500 | ✓ |
| `PL.PRODUCT_COST` | 70,282 | 70,282 | ✓ |
| `PL.PRODUCT_MARGIN` | 158,218 | 158,218 | ✓ |
| `PL.CONTRIBUTION` | 67,801 | 67,801 | ✓ |
| `PL.OPERATING_PROFIT` | 53,549 | 53,549 | ✓ |
| Budget operating profit | 68,220 | 68,220 | ✓ |
| Operating profit variance | −14,671 | −14,671 | ✓ |
| Food sales | 191,100 | 191,100 | ✓ |
| `FC.ACTUAL_CONSUMPTION` (food) | 61,343 | 61,343 | ✓ |
| `FC.EXPECTED_USAGE` (food) | 60,400 | 60,400 | ✓ |
| `FC.ACTUAL_VS_EXPECTED` (food) | 943 | 943 | ✓ |

Cross-file reconciliation is also exact — POS item revenue ties to the P&L to the penny for both
food (191,100) and beverage (27,400); meal-period revenue sums to net sales (228,500) and budget
(232,000); labour cost ties to the P&L payroll line (84,317) and to the T6 comparator (79,112).
Expected usage recomputed independently as `Σ(units × approved_cost_per_unit)` from T2 × T4A
reproduces 60,400 exactly.

Derived values not currently in the golden list, all recomputed from the fixture and recommended
for addition:

```
PL.OWNER_RESULT                  27,549
FC.ACTUAL_COST_PCT      (food)   32.10%
FC.BUDGET_BENCHMARK     (food)   57,330
FC.BUDGET_GAP           (food)    4,013
FC.MENU_MIX_EFFECT      (food)    3,070
FC.ACTUAL_CONSUMPTION   (bev)     6,439
FC.EXPECTED_USAGE       (bev)     6,180
FC.ACTUAL_VS_EXPECTED   (bev)       259
```

A runnable version of this verification ships in `tests/golden/test_amberside_parity.py` so it can
be wired into CI on day one, before any application code exists.

### 5.1 Fixture caveats that will bite during ingestion

- **The demo upload files do not match the blank templates.** `Amberside_PnL_Jul2026.csv` is *wide*
  — the period is a column header (`July_2026`) — while `Template_PnL.csv` is *long* with a `Period`
  column. Same for stock, labour, meal periods and customer source, none of which carry a period
  column at all. This is genuinely good news: the fixture exercises the `unpivot month columns` and
  `fixed value` transforms and forces real profile detection rather than a happy-path parse. It must
  be called out explicitly so nobody "fixes" the fixture by reformatting it.
- **The budget file is at ladder grain, not account grain.** `Amberside_Budget_Jul2026.csv` is keyed
  by `Management_Line`, but the spec says T6 has "the same canonical structure as T1" (account
  grain) and `financial_fact.account_id` is `NOT NULL`. As it stands the comparator cannot be
  committed without inventing synthetic accounts. This is a real schema/spec conflict — see gap
  **G-07**.
- **`Amberside_Stock_Jul2026.csv` carries `Revenue`, `Budget_Cost_Pct` and `Expected_Usage`
  columns.** Expected usage is a *derived* value (T2 × T4A) and must be computed, never imported, or
  the two-story bridge becomes circular and unfalsifiable. These columns should be treated as
  fixture convenience only.
- **Labour activity units are not additive.** In `Amberside_Labour_Jul2026.csv`, "Kitchen prep" and
  "Management / shared" both carry 5,650 (total covers) while FOH rows carry their own period
  covers. Summing `covers_or_orders` across role groups is meaningless. The `labour_fact` model
  needs an explicit `activity_basis` discriminator so the engine knows which rows may be aggregated.
- **`Amberside_Transactions_Jul2026.csv` is 10,500 rows** — a useful, realistic volume test for the
  T8 path and for staging-row storage cost.

---

## 6. Data model

### 6.1 The architecture document is strong

The five-layer immutability chain, the separation of `calculation_status` from `evidence_status`,
the "missing is not zero" rule, profile versions as immutable mapping snapshots, correction-by-
supersession rather than mutation, and packs pinned to exactly one locked calc run — this is a
well-designed audit-grade model. The closed transform list ("no customer-specific executable code")
is a mature decision that will save real pain. The repository boundary (`apps/web`, `api`,
`packages/calc_engine`, `packages/import_engine`) is correct and enforces the server-authoritative
rule structurally rather than by convention.

### 6.2 The SQL draft is the weakest artefact in the package

The draft implements **25 tables against roughly 60 described** in the architecture document, and
its own closing comment acknowledges this. That is a reasonable scoping decision. The problems are
in what it *does* implement:

**G-01 — No row-level security at all.** Zero `create policy` statements and a single commented-out
hint. The architecture document's rule 3 is "RLS is enforced in PostgreSQL, not only in application
code". Right now that rule is unimplemented. This is the highest-severity gap in the package.

**G-02 — Tenancy can be violated through foreign keys.** Every table carries `organisation_id`, but
`outlet_id` references `outlet(id)` alone. Nothing prevents a row with organisation A's
`organisation_id` and organisation B's `outlet_id`. RLS filtering on `organisation_id` would then
happily expose it. The fix is composite foreign keys — add `unique (organisation_id, id)` to parent
tables and reference `(organisation_id, outlet_id)` — so the database makes cross-tenant rows
unrepresentable rather than merely unlikely.

**G-03 — Two unique constraints are silently unenforced.** PostgreSQL treats `NULL`s as distinct in
unique constraints:
- `account`: `unique (outlet_id, account_code, account_name)` — `account_code` is nullable, and the
  import spec explicitly supports mapping by name when no code exists. Every such account can be
  inserted an unlimited number of times.
- `account_mapping`: `unique (profile_version_id, source_account_code, source_account_name)` — same
  defect, and this one is the constraint that is supposed to guarantee the architecture document's
  invariant "one source account maps to one ladder line per profile version". **It does not.**

Fix with `NULLS NOT DISTINCT` (PostgreSQL 15+, which Supabase provides) or a unique index on
`coalesce(account_code, '')`.

**G-04 — `calc_result` has no uniqueness.** Nothing stops the same `(run_id, calc_id, grain_key)`
being inserted twice. A retried or partially-failed run would produce duplicate results, and since
results are meant to be immutable there is no natural repair. Add
`unique (run_id, calc_id, grain_key)`.

**G-05 — Immutability is documented but not enforced.** "Committed facts never mutate", "calc
results are immutable after run completion", "a signed pack never changes" are stated as invariants
with no triggers, no revoked privileges and no `CHECK`s. Under RLS with a service role, application
bugs will silently rewrite history — which destroys the product's entire value proposition.
Immutability must be enforced by `BEFORE UPDATE OR DELETE` triggers.

**G-06 — Conditional decision requirements are unenforced.** The architecture document lists five
(ACT requires owner + lever + guardrail + metric + due/cadence; INVESTIGATE requires evidence
request + owner + due date; and so on). In the draft, every column on `action` is nullable. These
are exactly the rules the product exists to enforce; they belong in `CHECK` constraints keyed off
the disposition, not only in the `RG` gate engine.

**G-07 — `financial_fact.account_id` is `NOT NULL`**, but the T6 comparator fixture is at ladder
grain with no accounts. Either the fixture is wrong, or budgets need a ladder-grain path. I
recommend the latter: make `account_id` nullable with a `CHECK` that it is present for
`scenario = 'actual'` and optional otherwise, and record `ladder_line_id` regardless.

**G-08 — No indexes.** Not one non-constraint index. `financial_fact` will be queried by
`(outlet_id, period_id, scenario)` on every P&L render; `calc_result` by `(run_id, calc_id)`;
`staging_row` by `batch_id` across 10,500-row batches. Add them with the first migration, not after
the first performance complaint.

**G-09 — Missing tables the first vertical slice actually needs.** The slice requires context,
settings, materiality, column mappings and validation-driven readiness, but the draft omits
`restaurant_context`, `setting`, `materiality_setting`, `column_mapping`, `template_definition`,
`calc_definition`, `driver_taxonomy`, `audit_log` and `staff_assignment`. Of these,
`materiality_setting` and `audit_log` are non-negotiable for slice 1: materiality is an input to
`SEQ.FIRST_MATERIAL_MOVEMENT` (slice acceptance criterion #7) and the audit log is required by the
architecture's own staff-access rule.

**G-10 — Type and naming inconsistencies.** The architecture document defines a `template_code`
enum; the SQL uses `text`. `review_issue` is missing the `ladder_line_id` / `module` columns the
document specifies. `import_batch.period_id` is nullable but no batch can be committed without one.
There is no `updated_at` anywhere.

**G-11 — `membership.outlet_scope uuid[]`** cannot be referentially constrained. An array of UUIDs
with no foreign key means deleted outlets leave dangling scope entries that silently widen or
narrow access. A `membership_outlet` join table is the conventional fix; if the array is kept for
RLS performance, it needs a trigger-based integrity check and a documented rationale.

### 6.3 What I have done about it

`supabase/migrations/` contains a **proposed** corrected migration set covering the first vertical
slice only, addressing G-01 through G-11 for the tables that slice touches. It is explicitly a
proposal awaiting the sign-offs the freeze requires — the original draft is preserved untouched at
`docs/source/Supabase_Schema_Draft_v0_1.sql`. Every deviation is itemised in
`supabase/migrations/README.md`.

---

## 7. Import, mapping and validation

Strong specification. The fingerprint design correctly excludes volatile row counts; the four-tier
matching hierarchy (exact / new rows only / renamed columns / new layout) maps well to how
restaurant exports actually drift; the confidence bands are sensibly labelled "product defaults, not
accounting truths"; and "never map by amount" is exactly the right prohibition.

Gaps:

- **No collision rule.** What happens when two active profile versions produce the same fingerprint?
  It is possible — two outlets exporting from the same POS with identical headers.
- **The confidence bands have no golden test.** 0.92 and 0.75 are asserted without a labelled
  dataset to validate them against. They will need tuning; there is currently no way to measure it.
- **No file-safety requirements.** Nothing on maximum file size, row limits, upload timeouts,
  content-type verification, zip-bomb or formula-injection protection on XLSX, or malware scanning.
  This is a product that accepts arbitrary uploaded spreadsheets from the public internet.
- **The API contract covers imports only.** No endpoints are specified for reviews, calc runs,
  issues, decisions, actions, packs or sign-off — the majority of the application. A first draft is
  in `docs/contracts/api-contract.md`.
- **Idempotency is unaddressed.** `POST /imports/{id}/commit` must be idempotent under retry, or a
  network blip during the atomic commit produces duplicate facts.

---

## 8. Non-functional scope — the largest untouched area

Almost nothing in the package addresses these, and several are prerequisites rather than
nice-to-haves:

| Area | Status |
|---|---|
| Auth lifecycle (invite, reset, MFA, session length, SSO) | Not specified. Supabase Auth chosen, journeys undesigned. |
| Observability (logging, tracing, error reporting, alerting) | Not specified. |
| Backup / restore / disaster recovery | Not specified. Critical — the product's value is immutable history. |
| Data retention & deletion (GDPR, right to erasure) | Not specified, and in direct tension with immutability. Needs a real answer. |
| Rate limiting & abuse | Not specified. |
| Performance budgets | Not specified. |
| Background job execution (calc runs, pack generation) | Not specified. Both are long-running; Vercel function timeouts will be hit. |
| CI/CD, environments, migration gating | Partially specified in the freeze. Needs implementation. |
| Localisation / multi-currency | One currency per outlet in R1 — a stated decision, worth recording as a deliberate limit. |

The background-job point deserves emphasis: a calc run over a 10,500-row transaction fixture plus
pack PDF generation will not reliably complete inside a serverless request. The architecture needs a
job runner decision **before** slice 3, not after.

---

## 9. Conclusion and recommended sequence

The methodology, the screen design and the numbers are sound. I would not re-open any of them — and
the freeze's instruction "do not redesign the analytical scope again" is the right discipline.

What needs to happen before the first line of application code, in order:

1. **Answer the twelve open decisions** in `docs/plan/05-open-decisions.md`. Most are ten-minute
   answers; three are genuinely architectural (job runner, GDPR-vs-immutability, budget grain).
2. **Accept or amend the corrected slice-1 migrations** in `supabase/migrations/`.
3. **Fix `FC.DECISION_PATH`** to branch on actual-vs-expected, and add the favourable branch.
4. **Write down the rules that currently exist only in the prototype's JavaScript** (§4.3).
5. **Wire `tests/golden/test_amberside_parity.py` into CI** so parity is protected from commit one.

Then build the vertical slices in the freeze's stated order. The slice plan, backlog and
agent-ready work packages are in `docs/plan/`.
