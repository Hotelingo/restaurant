# Backlog — Slices 0 to 4

Stories for the work that makes the product exist. Slices 5–10 are deliberately not decomposed yet:
their shape depends on what slices 1–4 teach us, and decomposing them now would be false precision.

Each story has **acceptance criteria written as verifiable statements**. If a criterion cannot be
turned into a test, it is not a criterion.

Estimates: **S** ≈ 1 day · **M** ≈ 2–3 days · **L** ≈ 4–5 days · **XL** — split it.

---

## Slice 0 — Groundwork

### S0-1 · Monorepo skeleton · M
Create the layout from the development plan.
- [ ] `apps/web`, `api`, `packages/contracts`, `packages/calc_engine`, `packages/import_engine`, `supabase`, `tests`, `docs`, `fixtures` all exist and build.
- [ ] A lint rule fails the build if `apps/web` imports from `calc_engine` or `import_engine`.
- [ ] A lint rule fails the build if `calc_engine` imports any database or HTTP library.
- [ ] `README.md` explains how to run each package locally.

### S0-2 · CI pipeline · M
- [ ] Every PR runs lint, typecheck, unit tests, golden parity tests and a migration dry-run.
- [ ] Migration dry-run applies all migrations to a throwaway database and fails on error.
- [ ] `main` is protected; PRs require a green build.
- [ ] A PR that changes a golden value **fails** unless it also updates the fixture or states "no expected-value change".

### S0-3 · Environments · M
- [ ] `local`, `preview` and `production` are defined, with **separate Supabase projects** for dev/preview and production.
- [ ] Vercel preview deployments read preview variables only.
- [ ] No migration or seed job can target production from CI. Verified by attempting it.

### S0-4 · Golden parity harness · S — **already delivered**
- [x] `tests/golden/test_amberside_parity.py` recomputes all eleven frozen values from raw CSVs and passes.
- [x] It asserts cross-file reconciliation (POS↔P&L, meal periods↔net sales, labour↔payroll).
- [ ] Wired into CI.

---

## Slice 1 — Foundation

### S1-1 · Tenancy schema with enforced isolation · L
- [ ] `organisation`, `outlet`, `membership`, `staff_assignment`, `reporting_period` exist with composite tenancy foreign keys (G-02).
- [ ] **A row carrying org A's `organisation_id` and org B's `outlet_id` is rejected by the database.** Test proves it.
- [ ] Every tenant table has RLS enabled and a policy (G-01).
- [ ] `has_org_access()` and `has_outlet_access()` helpers exist and are `security definer`.
- [ ] Indexes ship with the tables (G-08).

### S1-2 · RLS test suite · M
- [ ] A user in org A reads zero rows from org B on every tenant table.
- [ ] An `all_outlets` member reads all permitted outlets; a `selected_outlets` member reads only join-table scope; selected scope with zero rows grants zero access.
- [ ] An anonymous client reads nothing.
- [ ] A client **cannot** insert or update `financial_fact` or `calc_result` under any role.
- [ ] Tests run in CI against a real PostgreSQL instance, not a mock.

### S1-3 · Auth journey · L
- [ ] Sign-in, invite acceptance, password reset and sign-out work against Supabase Auth.
- [ ] `/auth/context` returns the caller's organisations, outlets, roles and permissions.
- [ ] Session length and MFA policy are configured per the answer to OD-06.
- [x] Design contract supplied by `docs/design/v4.3-operational-addendum.md` (G-41 closed for design; implementation pending).

### S1-4 · Organisation and outlet creation · M
- [ ] A signed-in user creates an organisation and becomes its `admin`.
- [ ] An admin creates an outlet with currency, timezone and fiscal year start.
- [ ] An admin creates reporting periods; overlapping periods for one outlet are rejected.
- [x] Design contract supplied by `docs/design/v4.3-operational-addendum.md` (G-40 closed for design; implementation pending).

### S1-5 · Restaurant context (SC17) · M
- [ ] Context is **versioned** with `effective_from`/`effective_to`; editing creates a new version.
- [ ] Prior versions remain readable and are never mutated (immutability trigger, G-05).
- [ ] A review records which context version it used.

### S1-6 · Settings, materiality and users (SC16) · M
- [ ] Outlet settings (comparator, tax basis, sign convention, popularity factor, tolerances) are editable by admins.
- [ ] `materiality_setting` is versioned by scope with absolute threshold, percent threshold, recurrence rule and risk override.
- [ ] **No universal absolute threshold is hard-coded anywhere.** R1 may propose the OD-10 visible starting rule (≈0.5% of comparator Net Sales + 10% line threshold), but the confirmed values are stored/versioned per outlet and snapshotted into the review.
- [ ] Members can be invited, assigned roles and deactivated.

### S1-7 · Audit log · M
- [ ] Every staff read of customer data writes actor, org/outlet, action code, object type/id, timestamp and correlation id (G-09).
- [ ] Staff access without an active, unexpired `staff_assignment` is refused.
- [ ] The audit log is append-only, enforced by trigger.

### S1-8 · Component library (`STATES`) · L — **do this first in the slice**
- [ ] The design tokens from the wireframe are ported as CSS custom properties, light and dark.
- [ ] Every primitive has a documented state matrix: default, hover, focus, active, disabled, loading, empty, error.
- [ ] **Tabs implement the full ARIA pattern** — `role="tab"`, `aria-selected`, `aria-controls`, arrow-key navigation, roving tabindex (G-44, G-45).
- [ ] **The table primitive emits `scope` on every `<th>` and a `<caption>` by construction** (G-46).
- [ ] **The field primitive requires a visible label**; placeholder-as-label is impossible (G-47).
- [ ] Explanatory text uses an accessible disclosure, not `title` (G-48).
- [ ] Automated axe pass with zero violations; manual keyboard walkthrough documented.

### S1-9 · Empty, error and permission-denied states · M
- [x] UX contract defined in `docs/design/v4.3-operational-addendum.md` (G-42/G-43 design closed).
- [ ] A new organisation with no data shows a guided first-run path, not a broken dashboard.
- [ ] 403, 404 and 500/route error boundaries implement the approved states and correlation-ID recovery pattern.

---

## Slice 2 — Ingestion

### S2-1 · Parsers · M
- [ ] CSV and XLSX parse to a uniform intermediate representation.
- [ ] Header row detection handles the fixture's wide P&L (`July_2026` as a column header).
- [ ] Encoding, BOM and thousands separators handled. **All ten Amberside files parse.**
- [ ] No database or network access in `import_engine`.

### S2-2 · Fingerprinting and profile matching · L
- [ ] Fingerprint = normalised sheet name + normalised ordered headers + header row number + orientation + key-set hash + column count + template code. **Row count excluded.**
- [ ] All four match tiers implemented: exact, new-rows-only, renamed/moved columns, different layout.
- [ ] Matching is scoped to `(organisation_id, outlet_id, template_code)`; a collision within that scope requires manual resolution (G-33).
- [ ] Confidence bands are settings, not constants.
- [ ] Re-uploading the same file matches the existing profile and reports "Mapping reused from profile vN".

### S2-3 · Closed transform list · M
- [ ] All thirteen transforms implemented; **no mechanism exists for arbitrary customer code**.
- [ ] `unpivot month columns` and `fixed value` handle the fixture's wide files (G-30).
- [ ] Each transform is individually unit-tested.

### S2-4 · Mapping · L
- [ ] Column, account, item and value mappings persist against an immutable `profile_version`.
- [ ] **One source account maps to one ladder line per profile version — enforced by a constraint that actually works with NULL account codes** (`NULLS NOT DISTINCT`, G-03). Test inserts a duplicate name-only account and expects rejection.
- [ ] Mapping never uses amounts.
- [ ] An approved `profile_version` cannot be modified; changes create a new version.

### S2-5 · Validation framework · L
- [ ] Every rule carries code, severity, scope, actual, expected, message and remediation.
- [ ] Cross-file rules: POS↔P&L within 0.5%, T3 purchases↔P&L within 2%, missing totals → `Not Reconciled`.
- [ ] Negative activity units and unsupported negative stock block.
- [ ] **On the Amberside fixture, the POS↔P&L check passes with a difference of exactly zero** for both food and beverage.
- [ ] Unresolved `block` severities prevent commit.

### S2-6 · Atomic, idempotent commit · L
- [ ] Commit follows the nine specified steps in one transaction.
- [ ] **A failure at any step commits zero canonical facts.** Test proves it with an injected failure at each step.
- [ ] A retried commit with the same idempotency key does not duplicate facts (G-36).
- [ ] A committed batch cannot be updated or deleted, even by the service role (G-05).
- [ ] A duplicate outlet/period/scenario/template batch blocks until explicitly superseded; the superseded batch stays queryable.

### S2-7 · Upload and file safety · M
- [ ] Files land in Storage at `org/{org}/outlet/{outlet}/source/{file_id}/{filename}` with SHA-256 recorded.
- [ ] Size cap, row limit, upload timeout and content-type verification enforced (G-35).
- [ ] XLSX formula-injection and zip-bomb protection; malware scanning.
- [ ] Signed URLs only; no public bucket access. Test proves an unauthenticated fetch fails.

### S2-8 · Ingestion UI (SC03–SC06) · L
- [ ] Upload centre, mapping wizard, import result with exception queue, data readiness.
- [ ] Readiness shows per-capability status including `Not Reconciled`.
- [ ] Every blocking validation is actionable — it says what to fix, not just what failed.

### S2-9 · Staff tools (ST01–ST04) · M
- [ ] Setup workspace, profile builder, drift queue, time and service log.
- [ ] All reads audited; all require an active `staff_assignment`.

---

## Slice 3 — P&L

### S3-1 · `PL` engine · L
- [ ] All eleven ladder `calc_id`s implemented as pure Decimal functions.
- [ ] `PL.VAR.*` stores both `raw_delta` and `profit_effect`, with cost lines sign-flipped so favourable is positive.
- [ ] Zero/absent denominators return `NOT_CALCULATED` with an `explanation_code` — **never zero** (G-22).
- [ ] A missing comparator returns `NOT_CALCULATED` / `COMPARATOR_NOT_COMMITTED` (G-26).
- [ ] Quantisation to the currency minor unit, `ROUND_HALF_UP`, at presentation only (G-23).
- [ ] No database, clock or randomness in the engine. Tests run with no database available.

### S3-2 · Golden parity through the real engine · M
- [ ] A calc run on the Amberside fixture reproduces **all eleven frozen values exactly**.
- [ ] The extended golden set in the calc registry also matches, including `PL.OWNER_RESULT = 27,549` (G-27).
- [ ] Re-running produces an identical result set under a new `calc_run` id.

### S3-3 · Calc run persistence · M
- [ ] `calc_run` records engine version and a settings snapshot; `calc_run_input` links every batch used.
- [ ] `calc_result` is unique on `(run_id, calc_id, grain_key)` (G-04).
- [ ] Results are immutable once the run completes — update and delete both fail (G-05).
- [ ] Only committed batches can feed a run.
- [ ] `calc_dependency` records lineage between subtotals.

### S3-4 · `SEQ.FIRST_MATERIAL_MOVEMENT` · M
- [ ] Walks the ladder in order and returns the first material movement with its impact and the **exact rule** that made it material.
- [ ] Materiality comes from a versioned snapshot frozen into the run.
- [ ] **The engine never names an operating cause.** Reviewed by hand.

### S3-5 · Management P&L and reconciliation UI (SC07, SC08) · L
- [ ] The ladder renders with actual, comparator, `raw_delta` and `profit_effect`.
- [ ] `NOT_CALCULATED` is visually distinct from zero (G-22) — a designed state, not a dash.
- [ ] Every figure is traceable to its `calc_result` and onward to batch and source file.
- [ ] Reconciliation status is explicit, never implied.

---

## Slice 4 — Review loop

### S4-1 · Review and FRAME (SC10) · M
- [ ] One active review per outlet/period, enforced by constraint.
- [ ] FRAME captures comparator, context version and materiality snapshot; the review pins one active calc run.

### S4-2 · Shortlist (SC11) · M
- [ ] Issues are created from `calc_result` rows with movement amount, rate and materiality reason.
- [ ] Shortlist order is explicit and persisted.

### S4-3 · Diagnosis and evidence (SC12) · L
- [ ] Diagnosis separates *supported* from *hypothesis* from *unknown*.
- [ ] `driver_evidence` carries taxonomy, status and a nullable quantified impact.
- [ ] **Only `supported` or `validated` evidence may enter quantitative reconciliation**; `evidence_required` forces the amount to zero and disables the input (G-28).
- [ ] Evidence requests record dataset, minimum fields, owner and due date, and link to the fulfilling batch.

### S4-4 · Decisions with enforced requirements · M
- [ ] One disposition per shortlisted issue.
- [ ] **The database rejects an ACT without owner, lever, guardrail, metric and due/cadence**, and the equivalent for INVESTIGATE, MONITOR, ESCALATE and CLOSE (G-06). Tested per disposition.
- [ ] Decisions blocked while evidence status is `EVIDENCE REQUIRED` (G-28).

### S4-5 · Action register and verification (SC13) · M
- [ ] Actions carry owner, lever, guardrail, metric, target/trigger, due date, cadence and status.
- [ ] `action_event` records history.
- [ ] `prior_action_check` supports next-period verification: completed? driver moved? result responded? — with close/reopen.

### S4-6 · Owner Pack and claim validation (SC14) · L
- [ ] A pack pins exactly one **completed** calc run.
- [ ] `claim_citation` links every claim to the `calc_result` behind it.
- [ ] **`claimCheck` enforced server-side**: every number in claim prose must exist in the engine's output set, and banned wording blocks acceptance (G-28).
- [ ] A signed pack is immutable; edits create the next version (G-05).
- [ ] Pack artefacts are stored with a SHA-256 and served by signed URL.

### S4-7 · Review gate engine (`RG`) · M
- [ ] All eleven gate conditions from the spec implemented.
- [ ] **The engine returns failures and cannot be overridden.** Test attempts an override and expects refusal.
- [ ] Gate failures are actionable — each names what to do.

### S4-8 · Reviewer workbench and history (SC15, SC26) · L
- [ ] Threaded comments with role and resolution status.
- [ ] Sign or request-changes recorded against a pack version with a caveat field.
- [ ] History shows every pack version, its calc run and its sign-off.

### S4-9 · Twelve-step acceptance test · L
- [ ] The freeze's full acceptance path runs green in CI against a **brand-new** test organisation.
- [ ] Lineage is asserted at every hop: pack → calc run → batch → staging row → source file.

---

## Definition of done

Every story must additionally satisfy `04-definition-of-done.md`.
