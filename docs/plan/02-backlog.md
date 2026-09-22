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
- [x] Wired into CI.

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
- [ ] Sign-in, invite acceptance, password reset and sign-out work against Neon Managed Better Auth. **Sign-in, app invitation acceptance, registration, sign-out and managed password-reset UI integration are implemented. Password reset still needs one live email-link E2E check against the deployed preview/production auth domain before this combined criterion is closed.**
- [ ] `/auth/context` returns the caller's organisations, outlets, roles and permissions.
- [ ] Session length and MFA policy are configured per the answer to OD-06. **The 12-character password minimum is enforced at the application auth proxy for sign-up/reset/change/set-password. The 12-hour idle / 7-day absolute session policy and required MFA remain open; current Managed Better Auth does not expose the required two-factor plugin.**
- [x] Design contract supplied by `docs/design/v4.3-operational-addendum.md` (G-41 closed for design).

### S1-4 · Organisation and outlet creation · M
- [x] A signed-in user creates an organisation and becomes its `admin`.
- [x] An admin creates an outlet with currency, timezone and fiscal year start.
- [x] An admin creates reporting periods; overlapping periods for one outlet are rejected.
- [x] Design contract supplied by `docs/design/v4.3-operational-addendum.md` (G-40 closed for design).

### S1-5 · Restaurant context (SC17) · M
- [x] Context is **versioned** with `effective_from`/`effective_to`; editing creates a new version.
- [x] Prior versions remain readable and are never mutated (immutability trigger, G-05).
- [ ] A review records which context version it used.

### S1-6 · Settings, materiality and users (SC16) · M
- [x] Outlet settings (comparator, tax basis, sign convention, popularity factor, tolerances) are editable by admins.
- [x] `materiality_setting` is versioned by scope with absolute threshold, percent threshold, recurrence rule and risk override.
- [x] **No universal absolute threshold is hard-coded anywhere.** R1 may propose the OD-10 visible starting rule (≈0.5% of comparator Net Sales + 10% line threshold), but the confirmed values are stored/versioned per outlet and snapshotted into the review.
- [x] Members can be invited, assigned roles and deactivated.

### S1-7 · Audit log · M
- [x] Every staff read of customer data writes actor, org/outlet, action code, object type/id, timestamp and correlation id (G-09). **Generic staff RLS reads require a transaction-local grant created only by `authorize_staff_read(...)`, which writes the audit row first.**
- [x] Staff access without an active, unexpired `staff_assignment` is refused.
- [x] The audit log is append-only, enforced by trigger.

### S1-8 · Component library (`STATES`) · L — **do this first in the slice**
- [x] The design tokens from the wireframe are ported as CSS custom properties, light and dark.
- [x] Every primitive has a documented state matrix: default, hover, focus, active, disabled, loading, empty, error. See `docs/design/component-state-matrix.md`.
- [x] **Tabs implement the full ARIA pattern** — `role="tab"`, `aria-selected`, `aria-controls`, arrow-key navigation, roving tabindex (G-44, G-45).
- [x] **The table primitive emits `scope` on every `<th>` and a `<caption>` by construction** (G-46).
- [x] **The field primitive requires a visible label**; placeholder-as-label is impossible (G-47).
- [x] Explanatory text uses an accessible disclosure, not `title` (G-48).
- [ ] Automated axe pass with zero violations; manual keyboard walkthrough documented. **The axe gate and keyboard checklist are implemented in this branch; close this item after CI records the first zero-violation run.**

### S1-9 · Empty, error and permission-denied states · M
- [x] UX contract defined in `docs/design/v4.3-operational-addendum.md` (G-42/G-43 design closed).
- [x] A new organisation with no data shows a guided first-run path, not a broken dashboard.
- [x] 403, 404 and 500/route error boundaries implement the approved states and correlation-ID recovery pattern.

---

## Slice 2 — Ingestion

### S2-1 · Parsers · M
- [x] CSV and XLSX parse to a uniform intermediate representation.
- [x] Header row detection handles the fixture's wide P&L (`July_2026` as a column header).
- [x] Encoding, BOM and thousands separators handled. **All ten Amberside files parse.**
- [x] No database or network access in `import_engine`.

### S2-2 · Fingerprinting and profile matching · L
- [x] Fingerprint = normalised sheet name + normalised ordered headers + header row number + orientation + key-set hash + column count + template code. **Row count excluded.**
- [x] All four match tiers implemented: exact, new-rows-only, renamed/moved columns, different layout.
- [x] Matching is scoped to `(organisation_id, outlet_id, template_code)`; a collision within that scope requires manual resolution (G-33).
- [x] Confidence bands are settings, not constants.
- [x] Re-uploading the same file matches the existing profile and reports "Mapping reused from profile vN".

### S2-3 · Closed transform list · M
- [x] All thirteen transforms implemented; **no mechanism exists for arbitrary customer code**.
- [x] `unpivot month columns` and `fixed value` handle the fixture's wide files (G-30).
- [x] Each transform is individually unit-tested.

### S2-4 · Mapping · L
- [x] Column, account, item and value mappings persist against an immutable `profile_version`. **Slice 2 item mappings use a stable `canonical_item_key`; Slice 5 will add/backfill `item_id` without rewriting approved history.**
- [x] **One source account maps to one ladder line per profile version — enforced by a constraint that actually works with NULL account codes** (`NULLS NOT DISTINCT`, G-03). Test inserts a duplicate name-only account and expects rejection.
- [x] Mapping never uses amounts.
- [x] An approved `profile_version` cannot be modified; changes create a new version.
- [x] First-run T1/T6 mapping confirmation creates and approves the initial profile version atomically; drift/new-row confirmation creates the next immutable version and reuses prior confirmed identity mappings without rewriting history.
- [x] Mapping confirmation is idempotent and rejects calculated Management P&L lines as source-mapping destinations.
- [x] Controlled header aliases are applied before financial staging so renamed source columns can be reviewed/mapped without ad hoc executable transforms.

### S2-5 · Validation framework · L
- [x] Every rule carries code, severity, scope, actual, expected, message and remediation.
- [x] Cross-file rules: POS↔P&L within 0.5%, T3 purchases↔P&L within 2%, missing totals → `Not Reconciled`.
- [x] Negative activity units and unsupported negative stock block.
- [x] **On the Amberside fixture, the POS↔P&L check passes with a difference of exactly zero** for both food and beverage.
- [x] Unresolved `block` severities prevent commit.

### S2-6 · Atomic, idempotent commit · L
**Status:** implemented for the first vertical T1/T6 path. Source → staging → approved mapping → validation gate → immutable financial facts → checksum → committed batch → readiness → optional durable calc request is one PostgreSQL transaction.
- [x] Commit follows the nine specified steps in one transaction. **The T1/T6 wrapper is `commit_financial_import_batch(...)`; the private helper exists only to fault-inject CI.**
- [x] **A failure at any step commits zero canonical facts.** CI injects a failure after each of the nine steps and verifies both zero facts and the original batch state.
- [x] A retried commit with the same idempotency key does not duplicate facts (G-36).
- [x] A committed batch cannot be updated or deleted, even by the service role (G-05).
- [x] A duplicate outlet/period/scenario/template batch blocks until explicitly superseded; the superseded batch stays queryable.

### S2-7 · Upload and file safety · M
- [ ] Files land in Storage at `org/{org}/outlet/{outlet}/source/{file_id}/{filename}` with SHA-256 recorded.
- [x] Size cap, row limit, upload timeout and content-type verification enforced (G-35). **Detection is content-based; extension/client MIME is not trusted.**
- [ ] XLSX formula-injection and zip-bomb protection; malware scanning. **Formula/macro/external-link rejection, ZIP path/entry/decompressed-size/compression-ratio limits and a ClamAV INSTREAM scanner are implemented. Preview/production uploads fail closed until a real ClamAV endpoint is configured; keep this criterion open until that deployment check is performed.**
- [ ] Signed URLs only; no public bucket access. **The download endpoint only emits 5-minute presigned URLs and the Neon `uploads` bucket is configured private. Keep open until the development storage smoke test proves a direct unsigned fetch fails.**

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
- [x] All eleven ladder `calc_id`s implemented as pure Decimal functions.
- [x] `PL.VAR.*` stores both `raw_delta` and `profit_effect`, with cost lines sign-flipped so favourable is positive.
- [x] Zero/absent denominators return `NOT_CALCULATED` with an `explanation_code` — **never zero** (G-22).
- [x] A missing comparator returns `NOT_CALCULATED` / `COMPARATOR_NOT_COMMITTED` (G-26).
- [x] Quantisation to the currency minor unit, `ROUND_HALF_UP`, at presentation only (G-23).
- [x] No database, clock or randomness in the engine. The standalone calculation-engine CI gate runs without a database or network dependency.

### S3-2 · Golden parity through the real engine · M
- [x] The real PL engine on the Amberside fixture reproduces **all eleven ladder values exactly**.
- [x] The extended golden set matches, including `PL.OWNER_RESULT = 27,549` (G-27), Budget Operating Profit = 68,220 and Operating Profit variance = -14,671.
- [x] Re-running identical committed inputs through a new durable queue request produces a distinct immutable `calc_run` with the same deterministic result hash; CI verifies both runs persist the same 33-result PL snapshot.

### S3-3 · Calc run persistence · M
- [x] `calc_run` records engine version and a settings snapshot; `calc_run_input` links committed source batches/profile versions and snapshots their canonical commit hashes.
- [x] `calc_result` is unique on `(run_id, calc_id, grain_key)` (G-04).
- [x] Results are immutable; terminal runs are also immutable and undeletable (G-05).
- [x] Only committed batches with canonical facts, matching period/profile/scenario and commit hash can feed a run.
- [x] `calc_dependency` records same-run lineage between derived results and their formula inputs.
- [x] OD-01 execution path implemented as a dedicated containerised worker over a Postgres-backed lease queue; expired worker attempts are preserved as failed runs and retries append a new immutable attempt.

### S3-4 · `SEQ.FIRST_MATERIAL_MOVEMENT` · M
- [x] Walks the frozen ladder in order and returns the first material movement with its profit-effect impact, raw movement and the **exact rule** that made it material. The pure-engine suite separately proves amount, percentage, recurrence and risk override paths.
- [x] Materiality comes from the approved `general` materiality version already frozen into `calc_run.settings_snapshot`; the worker does not read live thresholds during calculation.
- [x] **The engine never names an operating cause.** The result schema is restricted to ladder location + materiality evidence, and a regression test rejects cause/driver/diagnosis/root-cause output fields. Recurrence/risk events remain explicit inputs rather than inferred causes.

### S3-5 · Management P&L and reconciliation UI (SC07, SC08) · L
- [x] The ladder renders with actual, comparator, `raw_delta` and `profit_effect` from the immutable completed run.
- [x] `NOT_CALCULATED` is visually distinct from zero (G-22) and shows its `explanation_code`.
- [x] Every displayed result exposes its `calc_result`/input lineage and the run pins batch, source file, source SHA-256 and canonical commit hash.
- [x] Reconciliation status is explicit. Slice 3 proves committed P&L source-line tie-out; later cross-module tests are labelled `not_tested` rather than implied.

---

## Slice 4 — Review loop

### S4-1 · Review and FRAME (SC10) · M
- [x] One active review per outlet/period is enforced by a PostgreSQL partial unique index; review creation is idempotent and returns the existing active review rather than duplicating it.
- [x] FRAME is an explicit one-time draft → in-review confirmation that pins the completed calc run, its comparator, an effective restaurant-context version and the **exact materiality snapshot already frozen into that calc run**. The calc run receives its deferred `review_id` lineage link at the same time.

### S4-2 · Shortlist (SC11) · M
- [x] Issues are created only from calculated Management P&L variance `calc_result` rows in the review's pinned run. Profit effect, movement rate and materiality reason are copied/derived server-side; the client cannot submit authoritative amounts or rates. Below-threshold selections remain possible but are explicitly labelled `management_selection`, not falsely called material.
- [x] Shortlist order is explicit and persisted. The guide's 3–5 range remains soft: six requires a one-line reason and more than six returns a warning rather than a database block.

### S4-3 · Diagnosis and evidence (SC12) · L
- [x] Diagnosis separates *supported* from *hypothesis* from *unknown* and revisions append immutable versions rather than rewriting prior reasoning.
- [x] `driver_evidence` carries controlled taxonomy, evidence status and a nullable quantified impact.
- [x] **Only `supported` or `validated` evidence may enter quantitative reconciliation**; `evidence_required` cannot store a quantified impact and its generated reconciliation impact is zero (G-28). Partly-supported/unreconciled evidence may retain an observed amount but also contributes zero.
- [x] Evidence requests record dataset, minimum fields, owner and due date, and link only to a committed fulfilling batch from the same outlet.

### S4-4 · Decisions with enforced requirements · M
- [x] One disposition is active per shortlisted issue; revisions append immutable history and move only the issue's active-decision pointer.
- [x] **The database rejects an ACT without owner, lever, guardrail, metric and due/cadence**, and enforces the corresponding required fields for INVESTIGATE, MONITOR, ESCALATE and CLOSE (G-06). Each disposition has a direct PostgreSQL rejection test.
- [x] The evidence gate follows SC12 rather than blocking the only valid evidence-seeking path: an `EVIDENCE REQUIRED` issue cannot ACT, MONITOR or CLOSE; it may INVESTIGATE through a same-issue open evidence request, or ESCALATE when the required decision is outside local authority (G-28). ACT additionally requires the latest supported/validated diagnosis to be decision-ready.
- [x] HTTP write/read contracts expose idempotent decision recording and the active disposition plus immutable revision history.

### S4-5 · Action register and verification (SC13) · M
- [x] Actions pin an immutable decision revision and carry owner, lever, guardrail, metric, target/trigger, due date, cadence, forecast effect and current status where applicable. Closing requires closure evidence.
- [x] `action_event` records append-only status history; the action definition itself cannot be rewritten.
- [x] `prior_action_check` supports next-period verification: completed? driver moved? result responded? — with immutable evidence, one check per action/period, and controlled close/reopen outcomes.
- [x] HTTP contracts expose action creation/listing, controlled status history, verification history, and the SC13 prior-period action workspace.

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
