# Gap Register

Every gap found in the review, with severity, the decision it needs and where it is resolved.
Severity: **S1** blocks the first vertical slice · **S2** blocks a later slice · **S3** quality debt.

Status: `OPEN` needs a decision · `PROPOSED` a fix ships in this pack awaiting approval ·
`NOTED` recorded, no action in R1.

---

## Database & tenancy

| ID | Severity | Gap | Resolution | Status |
|---|---|---|---|---|
| G-01 | S1 | No RLS policies exist. The architecture's rule "RLS enforced in PostgreSQL, not only in application code" is unimplemented. | Policies + `has_org_access()` / `has_outlet_access()` helpers in `supabase/migrations/0004_rls.sql`. | PROPOSED |
| G-02 | S1 | Tenancy is violable via FKs: `outlet_id` references `outlet(id)` alone, so a row can carry org A's `organisation_id` and org B's `outlet_id`. RLS filtering on `organisation_id` would then leak it. | Composite FKs on `(organisation_id, outlet_id)`, with `unique (organisation_id, id)` on parents. | PROPOSED |
| G-03 | S1 | `account` and `account_mapping` unique constraints include nullable columns; PostgreSQL treats NULLs as distinct, so both are silently unenforced. `account_mapping` is the constraint meant to guarantee "one source account → one ladder line per profile version". | `NULLS NOT DISTINCT` on both. | PROPOSED |
| G-04 | S1 | `calc_result` has no uniqueness — a retried run can duplicate `(run_id, calc_id, grain_key)` into immutable storage. | `unique (run_id, calc_id, grain_key)`. | PROPOSED |
| G-05 | S1 | Immutability is documented but unenforced: no triggers, no revoked privileges, no CHECKs on committed batches, canonical facts, completed calc runs or signed packs. | `BEFORE UPDATE OR DELETE` triggers in `0003_immutability.sql`. | PROPOSED |
| G-06 | S2 | Conditional decision requirements (ACT needs owner+lever+guardrail+metric+due/cadence, etc.) exist only in prose and the `RG` engine. All `action` columns are nullable. | Disposition-keyed CHECK constraints. Slice 4. | PROPOSED |
| G-07 | S1 | `financial_fact.account_id` is `NOT NULL`, but the T6 budget fixture is at ladder grain with no accounts. The comparator cannot be committed as supplied. | Make `account_id` nullable with `CHECK` requiring it for `scenario='actual'`. **Needs product sign-off** — see OD-03. | OPEN |
| G-08 | S2 | No indexes beyond PK/unique. `financial_fact` by `(outlet_id, period_id, scenario)`, `calc_result` by `(run_id, calc_id)`, `staging_row` by `batch_id` are all hot paths. | Indexes ship with each table's migration. | PROPOSED |
| G-09 | S1 | Tables the first slice needs are absent from the draft: `restaurant_context`, `setting`, `materiality_setting`, `column_mapping`, `template_definition`, `calc_definition`, `driver_taxonomy`, `audit_log`, `staff_assignment`. `materiality_setting` feeds `SEQ.FIRST_MATERIAL_MOVEMENT` (slice acceptance #7); `audit_log` is required by the staff-access rule. | Added in `0002_slice1_core.sql`. | PROPOSED |
| G-10 | S3 | Inconsistencies: `template_code` is an enum in the doc, `text` in SQL; `review_issue` missing `ladder_line_id`/`module`; `import_batch.period_id` nullable though commit requires it; no `updated_at` anywhere. | Aligned in proposed migrations. | PROPOSED |
| G-11 | S2 | `membership.outlet_scope uuid[]` cannot be referentially constrained; deleted outlets leave dangling scope entries that silently change access. | Recommend `membership_outlet` join table. **Needs decision** — see OD-04. | OPEN |
| G-12 | S3 | The draft implements 25 of ~60 modelled tables. Deliberate, but the phasing is undocumented. | Phase map in `supabase/migrations/README.md`. | PROPOSED |

---

## Calculation engine

| ID | Severity | Gap | Resolution | Status |
|---|---|---|---|---|
| G-20 | S1 | **`FC.DECISION_PATH` contradicts the methodology.** The prototype branches on the *budget* gap, which the spec itself says "does not prove operating leakage". On the Amberside fixture that routes a 3,070 menu-mix issue into an operating-control hunt over a 943 real gap. | Branch on `FC.ACTUAL_VS_EXPECTED` and its residual; show budget gap as context only. Registry updated. | PROPOSED |
| G-21 | S2 | The prototype has a fifth decision path ("favourable — check standards and data") absent from the spec's four-value enum. It is correct and worth keeping. | Add `FAVOURABLE_VALIDATE_DATA` to the enum. | PROPOSED |
| G-22 | S1 | Division by zero is unspecified for `AVG_SPEND`, `ACTUAL_COST_PCT`, `MIX_PCT`, `EQUAL_SHARE`, `NET_REVENUE_PER_UNIT`. The prototype returns `0`, violating the "missing is not zero" contract. | Central rule: zero/absent denominator → `NOT_CALCULATED` + `explanation_code`. In registry. | PROPOSED |
| G-23 | S1 | No rounding/quantisation policy. "Decimal" alone will not make two implementations agree. | Quantise to currency minor unit, `ROUND_HALF_UP`, at presentation only; never between steps. | PROPOSED |
| G-24 | S2 | The variance decompositions place the interaction term in the rate/spend effect (Laspeyres convention), systematically inflating it. Correct, but undocumented — customers reconciling against another convention will challenge it. | Documented in the registry. | PROPOSED |
| G-25 | S2 | No tolerance constants. The calc spec says "within currency tolerance" with no number. | Defined as settings with defaults in the registry. | PROPOSED |
| G-26 | S2 | Behaviour when the comparator scenario has no committed batch is unspecified. | `PL.VAR.*` → `NOT_CALCULATED`, `explanation_code = COMPARATOR_NOT_COMMITTED`. | PROPOSED |
| G-27 | S3 | `PL.OWNER_RESULT` has no golden value (it is 27,549); golden values exist only for `PL` and `FC`, not `RV`, `LB`, `CT`, `OC`, `MN`, `MAT`. | Extended golden set in the registry and in `tests/golden/`. | PROPOSED |
| G-28 | S1 | Four business rules exist only in prototype JavaScript and are in no spec: `claimCheck` (claim number/wording validation), `decReq` (required fields per decision type), `decEvGate` (evidence-blocked decisions), and the `fcCalc` rule that forces unsupported driver amounts to zero. | Written up in `docs/contracts/calc-registry.md` §7. | PROPOSED |

---

## Import, mapping & validation

| ID | Severity | Gap | Resolution | Status |
|---|---|---|---|---|
| G-30 | S1 | **Demo upload files do not match the blank templates.** The demo P&L is wide (period in the header, `July_2026`); the template is long with a `Period` column. Stock, labour, meal periods and customer source carry no period column at all. | Good news — it forces real profile detection and exercises `unpivot months` + `fixed value`. Do **not** reformat the fixture. Recorded in `fixtures/amberside/README.md`. | NOTED |
| G-31 | S2 | `Amberside_Stock_Jul2026.csv` carries an `Expected_Usage` column. Expected usage is derived (T2 × T4A); importing it makes the two-story bridge circular and unfalsifiable. | Treat as fixture convenience only; never map to a canonical fact. | PROPOSED |
| G-32 | S2 | Labour activity units are not additive across role groups (kitchen/management rows carry total covers, FOH rows carry their own). Summing them is meaningless. | `labour_fact.activity_basis` discriminator marking rows as aggregatable or not. | PROPOSED |
| G-33 | S2 | No fingerprint-collision rule. Two outlets on the same POS will produce identical fingerprints. | Scope fingerprint match to `(organisation_id, outlet_id, template_code)`; collision within that scope → manual resolution. | PROPOSED |
| G-34 | S2 | Confidence bands (0.92 / 0.75) are asserted with no labelled dataset to validate or tune them against. | Build a labelled header-matching corpus during slice 2. | OPEN |
| G-35 | S1 | **No file-safety requirements at all**: no size cap, row limit, upload timeout, content-type verification, XLSX formula-injection or zip-bomb protection, or malware scanning — on a product that accepts arbitrary public uploads. | Baseline controls specified in `docs/contracts/api-contract.md` §6. | PROPOSED |
| G-36 | S2 | `POST /imports/{id}/commit` idempotency is unaddressed; a retry mid-commit can duplicate facts. | Idempotency key + `canonical_commit_hash` precondition. | PROPOSED |
| G-37 | S2 | The API contract covers imports only — nothing for reviews, calc runs, issues, decisions, actions, packs or sign-off. | First draft in `docs/contracts/api-contract.md`. | PROPOSED |

---

## UX, screens & accessibility

| ID | Severity | Gap | Resolution | Status |
|---|---|---|---|---|
| G-40 | S1 | **No screen for creating an organisation/outlet**, yet that is acceptance criterion #1 of the first vertical slice. SC17 only edits existing context. | Design needed before slice 1 UI. | OPEN |
| G-41 | S1 | No auth screens (sign-in, invite accept, password reset, MFA) despite Supabase Auth being the chosen provider. | Design needed before slice 1 UI. | OPEN |
| G-42 | S2 | No genuine empty/first-run states. Every screen assumes Amberside with data loaded. The hardest journey in the product — new customer, no profile, no batch, no calc run — is undesigned. | Design during slice 1. | OPEN |
| G-43 | S3 | No error or permission-denied pages. `STATES` covers component states only. | Slice 1. | PROPOSED |
| G-44 | S2 | Broken ARIA tab pattern: 6 `role="tablist"` with zero `role="tab"`, `aria-selected` or `aria-controls`. Worse than no ARIA. | Fix once in the component library, not per screen. | PROPOSED |
| G-45 | S2 | No keyboard interaction model — zero `keydown` handlers, no arrow navigation, no roving tabindex on composite widgets. | Component library. | PROPOSED |
| G-46 | S2 | 486 `<th>` with zero `scope` and zero `<caption>`, in dense financial tables. | Table primitive emits `scope` and `caption` by construction. | PROPOSED |
| G-47 | S3 | 12 inputs use `placeholder` as their only label; 9 `<label>` elements for 18 static inputs. | Field primitive requires a label. | PROPOSED |
| G-48 | S3 | 162 `title` attributes carry explanatory text — invisible on touch and to keyboard users, in a product whose premise is explanation. | Replace with an accessible disclosure/popover primitive. | PROPOSED |
| G-49 | S3 | `SC23` and `SC24` are unused. Either deliberately retired or lost before v4 — the preservation audit only compares v4 to v4.2 and would not have caught it. | One-line confirmation needed. | OPEN |
| G-50 | S3 | No `@media print`, though the Owner Pack is a signed PDF. | Confirm server-side pack rendering (the schema already models a stored artefact + SHA-256). | OPEN |

---

## Non-functional

| ID | Severity | Gap | Resolution | Status |
|---|---|---|---|---|
| G-60 | S1 | **No background job execution model.** A calc run over 10,500 transaction rows plus pack PDF generation will not reliably finish inside a Vercel serverless request. | **Resolved in PR #25 / `0019_calc_worker.sql`:** dedicated containerised worker, durable Postgres lease queue, immutable retry attempts, heartbeat/claim/complete/fail lifecycle, deterministic PL result persistence. The same queue/worker pattern is the approved basis for later Owner Pack rendering. | RESOLVED |
| G-61 | S1 | Auth lifecycle undesigned: invitations, password reset, MFA, session length, SSO. | Slice 1 prerequisite. | OPEN |
| G-62 | S2 | No observability: logging, tracing, error reporting, alerting. | Baseline in slice 1. | PROPOSED |
| G-63 | S1 | No backup/restore/DR plan, for a product whose entire value is immutable history. | Decision required — see OD-02. | OPEN |
| G-64 | S1 | **No data retention or deletion policy**, in direct tension with immutability. GDPR right-to-erasure versus "signed packs never change" is a genuine conflict needing a real answer. | Decision required — see OD-05. | OPEN |
| G-65 | S2 | No rate limiting or abuse controls. | Slice 2. | PROPOSED |
| G-66 | S3 | No performance budgets. | Slice 3. | PROPOSED |
| G-67 | S3 | One currency per outlet in R1 is a stated decision but is not recorded as a deliberate, revisitable limit. | Recorded in open decisions. | NOTED |

---

## Summary

| Severity | Count | Of which OPEN (need your decision) |
|---|---|---|
| S1 | 16 | 9 |
| S2 | 18 | 2 |
| S3 | 11 | 2 |
| **Total** | **45** | **13** |

The thirteen OPEN items are consolidated as twelve questions in `docs/plan/05-open-decisions.md`.
Nine of them are short answers; three (job runner, DR, GDPR-vs-immutability) are genuinely
architectural and should be settled before slice 1 completes.
