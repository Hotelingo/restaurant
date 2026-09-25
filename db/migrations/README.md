# Neon database migrations

These are the Neon-native Slice 1 migrations for Restaurant Performance Review.

They adapt the previously accepted PostgreSQL domain model to Managed Better Auth and a
server-authoritative FastAPI access model.

## Runtime identity

FastAPI verifies the Neon Auth JWT. For every database transaction it executes:

```sql
select set_config('app.user_id', '<verified JWT sub>', true);
```

RLS resolves identity through `current_app_user_id()`.

The application connects as the non-owner PostgreSQL role `restaurant_app`; application traffic
must never connect as `neondb_owner`, otherwise table ownership can bypass ordinary RLS behavior.

## Apply order

1. 0001_reference.sql
2. 0002_tenancy.sql
3. 0003_context_controls.sql
4. 0004_immutability.sql
5. 0005_rls.sql
6. 0006_bootstrap.sql

Use a direct/unpooled connection for migrations. Use the pooled application connection for normal
API traffic.

## Environments

Develop against Neon branch `slice1-neon-foundation` (or another feature branch), never directly
against `production`.

No secrets belong in this directory.


## Slice 2 additions

- 0011_import_mapping.sql — source profiles, immutable profile versions and mapping tables.
- 0012_ingestion_persistence.sql — immutable source-file metadata, import-batch lifecycle,
  immutable staging rows, structured validation results and explicit supersede semantics.
- 0013_source_file_safety.sql — accepted file type/size/row caps plus required malware-scan and
  inspection metadata for every persisted raw source file.

The full canonical commit transaction remains a later step because canonical financial facts are
introduced with Slice 3. Do not mark S2-6 complete merely because the batch lifecycle exists.


## Slice 3 canonical finance prerequisite

- 0014_financial_facts.sql — seeds the v1 Management P&L ladder and adds the immutable
  account/financial_fact canonical model. Actuals require account grain. Budget, forecast and
  prior-year comparators may be account-grain or ladder-grain; ladder-grain rows never require
  synthetic accounts.

Canonical tables are SELECT-only to restaurant_app. The server-side atomic import-commit function
is the only planned writer.


## Atomic T1/T6 commit

- 0015_atomic_financial_commit.sql — single-transaction T1/T6 commit, idempotency response,
  deterministic canonical checksum, Management P&L readiness state and optional durable calculation
  request. A private fault-injection helper is EXECUTE-revoked from public/application roles and
  exists only so PostgreSQL CI can prove rollback after each of the nine commit steps.


## Import orchestration metadata

- 0016_import_orchestration.sql — persists parse/fingerprint/profile-match evidence on each
  import batch and stores the fingerprint confidence bands plus header alias map as outlet settings.
  Existing outlets are backfilled with visible product defaults (0.92 high / 0.75 review);
  future outlets receive the same settings through an outlet insert trigger.


## Financial mapping confirmation

- 0017_mapping_confirmation.sql — provides atomic first-run and drift mapping confirmation for
  T1/T6. It creates a new immutable profile version, rebuilds current-layout column/transform
  rules, clones reusable identity/value mappings from an approved base profile when available,
  overlays explicit user confirmations, verifies complete staged-identity coverage, approves the
  new version, and advances the batch to validation. Destination selection never uses financial
  amounts, and calculated Management P&L subtotal/profit lines cannot be source-mapping targets.


## Calculation run persistence

- 0018_calc_run_persistence.sql — adds immutable `calc_run`, `calc_run_input`,
  `calc_result` and `calc_dependency` tables for Slice 3. Inputs must reference committed
  canonical batches in the same outlet/period context; results are unique on
  `(run_id, calc_id, grain_key)`; result/input/dependency rows are append-only; and terminal runs
  cannot be changed or deleted. Customer application sessions receive SELECT only. The migration
  also seeds the accepted PL v1 ladder and variance calculation definitions.
- `review_id` is intentionally deferred until the Slice 4 `review` table exists so it can be
  introduced with a real foreign key rather than an unconstrained UUID.


## Durable calculation worker

- 0019_calc_worker.sql — implements the OD-01 Postgres-backed worker queue contract. It adds
  lease/heartbeat/claim metadata, crash-safe immutable run attempts, worker claim/complete/fail
  functions, direct calc-result input_refs, and persisted raw_delta / profit_effect.
  Permanent one-request-per-source-batch uniqueness is removed so an explicit rerun can create a new
  request and immutable run against the same committed inputs. The worker remains the only trusted
  writer; no queue mutation function is granted to restaurant_app.


## First material movement

- 0020_first_material_movement.sql — registers the stable
  `SEQ.FIRST_MATERIAL_MOVEMENT` v1 calculation definition. The result uses the existing
  categorical `calc_result.value_text` contract; the selected ladder code and exact materiality
  rule remain part of the immutable calculation snapshot.


## Review and FRAME foundation

- 0021_review_frame.sql — introduces the Slice 4 `review` aggregate and the confirmed FRAME
  contract. PostgreSQL enforces one non-closed review per outlet/period. FRAME confirmation pins a
  completed calculation run, the run's exact comparator, an effective restaurant-context version,
  and the run's frozen materiality snapshot; it then binds that calc run to the review through the
  `review_id` relationship deferred from 0018. Confirmed FRAME fields cannot be rewritten.


## Review shortlist

- 0022_review_shortlist.sql — adds `review_issue` for SC11. An issue must point to a
  calculated Management P&L variance in the review's pinned calc run. Profit effect, movement
  rate and materiality evidence are derived server-side from immutable calc results plus the
  review's frozen materiality snapshot; clients cannot supply authoritative financial values.
  Shortlist order is persisted explicitly. Three to five is guidance, not a hard limit: a sixth
  item requires a one-line reason and larger lists return a warning rather than being blocked.


## Diagnosis and evidence

- 0023_diagnosis_evidence.sql — adds the SC12 diagnosis/evidence foundation. Diagnosis revisions
  are append-only versions and explicitly separate supported conclusions, hypotheses and unknowns.
  Driver evidence is taxonomy-linked and immutable; only supported/validated evidence contributes
  to generated `reconciliation_impact`, while evidence-required input cannot store a quantified
  impact. Evidence requests persist dataset, minimum fields, owner and due date and can be fulfilled
  only by a committed batch from the same outlet.


## Decision discipline

- 0024_decisions.sql — adds immutable, versioned SC12 decisions with one active decision pointer
  per shortlisted issue. PostgreSQL enforces the mandatory fields for ACT, INVESTIGATE, MONITOR,
  ESCALATE and CLOSE. ACT requires the current supported/validated diagnosis; evidence-required
  issues cannot ACT, MONITOR or CLOSE, but may INVESTIGATE or ESCALATE. INVESTIGATE must point to
  an open evidence request for the same issue. Decision retries are idempotent and genuine changes
  append a new version rather than rewriting prior management reasoning.


## Action register

- 0025_action_register.sql — adds the SC13 action register and immutable `action_event` history.
  Each action pins a specific active decision revision and snapshots the agreed owner, lever,
  guardrail, metric, target/trigger, due date, cadence and forecast effect where applicable.
  Action definitions cannot be rewritten; controlled status transitions append history. Closing
  requires closure evidence, and the supported register statuses/tags match the v4.2 wireframe.


## Prior-action verification

- 0026_prior_action_check.sql — completes the SC13 next-period verification loop. Each immutable
  check records whether the prior action was completed, whether the named driver moved, and whether
  the result responded, together with supporting evidence. One check is allowed per action and
  verification period. Controlled outcomes continue, close, or reopen the action and always append
  an `action_event` of type `verification`. Verification must use a later reporting period;
  prior checks cannot be edited or deleted.


## Owner Pack claims

- 0027_owner_pack_claims.sql — adds versioned Owner Packs, claims and immutable calc-result
  citations. Every pack pins the review's one completed calc run. The server-side `claim_check`
  requires citations, verifies every numeric magnitude in claim prose against the cited engine
  results, and blocks the v4.2 banned accusation/absolute wording. Accepted claims must pass this
  check. Signed versions require final artefact path/hash/renderer/template metadata and become
  immutable; a later change is represented by the next pack version.
- Direction, evidence-status echo and scope remain reviewer/gate checks; they are not silently
  inferred from prose by this migration.


## Reviewer workbench and sign-off

- 0028_reviewer_signoff.sql — adds threaded immutable review comments with reviewer-controlled
  resolution, explicit draft/changes-requested → in-review submission, Not Reconciled disclosure,
  reviewer check snapshots, and immutable sign-off history pinned to the exact pack version and
  calculation run. Final `record_pack_signoff` is intentionally server-only: `restaurant_app`
  cannot execute it, so the API must evaluate the deterministic `packages/review_gate` contract
  before a pack can be signed. Signed pack and sign-off records remain immutable.


## Owner Pack deterministic artefacts

- 0029_owner_pack_renderer.sql — adds the authoritative source-snapshot SHA-256 to each rendered
  pack artefact and a server-only attachment function. The artefact object path is tenant/pack
  scoped, direct `restaurant_app` execution is denied, and signed packs require both byte hash
  and source hash so the API can reject stale renders before sign-off.


## Food Cost canonical inputs

- 0030_food_cost_facts.sql — introduces the Slice 5 canonical `item`,
  `item_sales_fact` (T2), `stock_fact` (T3), and `item_cost_snapshot` (T4A)
  model with composite tenant/source/profile/staging lineage, SELECT-only customer RLS and immutable
  fact records. It extends `item_mapping` with a canonical item FK without changing approved
  mapping identity, adds food-cost profile confirmation, and provides the atomic/idempotent
  `commit_food_cost_import_batch` transaction. T3 `expected_usage` is explicitly rejected from
  parsed canonical input and `stock_fact` has no Expected Usage field; readiness records
  `DERIVED_T2_X_T4A` as the only expected-usage source.


### 0031_food_cost_calc_runs.sql
Extends the immutable calculation spine for Food Cost. It admits only committed T2/T3/T4A batches
under the `item_sales`, `stock`, and `item_cost` input roles, seeds the FC v1 calculation
registry, adds explicit Food Cost queueing/rerun entry points, and preserves PL input isolation.


## Slice 5 review-spine guard

- 0032_slice5_review_spine_guard.sql — keeps the signed review architecture single-anchored:
  every confirmed review FRAME must pin a completed immutable `pl-*` calculation run whose
  comparator matches the review. Food Cost remains a supporting analysis snapshot and cannot become
  a parallel review/decision/Owner-Pack route. CI proves Amberside Food/Beverage routing, exact
  T2/T3/T4A lineage, and continued R1 signed-pack acceptance.


## Slice 6 Revenue inputs

- 0033_revenue_facts.sql — adds immutable T1B meal-period/business-view facts and T7
  customer-source/channel facts with profile/staging/source lineage, layout-only first-run profile
  confirmation, atomic/idempotent canonical commit, and `revenue_inputs` readiness that ties both
  source totals to committed Management P&L Net Sales at the configured 0.5% reconciliation
  tolerance. Revenue calc queueing remains blocked until S6-3.


- 0034_revenue_calc_runs.sql — extends the calc-run spine for `revenue-v1`, admitting only
  committed T1B/T7/T1 batches under Revenue-specific input roles, registers RV/CT v1 calculation
  definitions, and enables reconciled Revenue queue/rerun requests.


## Slice 7 Labour inputs

- 0035_labour_facts.sql — adds immutable T5 role-group Labour facts, profile-scoped
  `labour_activity_basis` mappings for sources that omit workload semantics, atomic/idempotent
  canonical commit, and `labour_inputs` readiness that separately reconciles T5 actual/comparator
  Labour Cost to committed T1/T6 Direct Labour at the 0.5% tolerance. Activity units are explicitly
  non-additive across role groups; calculation queueing remains blocked until S7-3.


## Slice 7 Labour / Other Cost calculation runs

- `0036_labour_other_calc_runs.sql` extends the immutable calculation spine for
  `labour-other-v1`, admitting committed T5 detail plus T1 actual and matching T6 comparator
  accounting snapshots under Labour-specific input roles. It registers the 12 LB/OC v1
  definitions, enables readiness-gated queue/rerun requests, and keeps module supersession isolated.
  The worker preserves role-group `activity_basis`, never aggregates repeated workload
  denominators, never infers `OVERSTAFFED`, and leaves overtime-rate / OC quantity-rate effects
  `NOT_CALCULATED` unless explicit supported evidence exists.


## Slice 8 C02 evidence

- `0037_c02_evidence.sql` adds immutable typed Yield/Portion/Production/Waste/
  Transfer-Nonrevenue evidence on top of the existing diagnosis workflow, with explicit
  product-group `coverage_key`, reproducible typed inputs, direct source refs, reviewer
  coverage overrides, idempotent/audited controlled writes and tenant RLS. Unsupported
  observations cannot enter quantitative reconciliation; normal loss already in standards
  and internal transfers inside the review boundary cannot be counted again.


## Web app connection

- `0039_period_calculation_requests.sql` adds `request_period_calculation` (admin/editor/setup
  analyst queue a manual recalculation of one module for a period from its latest committed batch;
  pending requests coalesce, the request is audited) and `list_period_calculations` (any user with
  outlet access reads recent requests). Both SECURITY DEFINER, granted to `restaurant_app`.
- `0040_pack_server_role.sql` makes the server-only Owner Pack writes reachable without making
  them ambient. The API connects only as `restaurant_app`, so `attach_pack_artifact` (0029) and
  `record_pack_signoff` (0028) were never callable and no pack could be rendered or signed through
  the API. A NOLOGIN `restaurant_pack_server` role now holds only those two EXECUTE rights;
  `restaurant_app` is a member `WITH INHERIT FALSE, SET TRUE`, so the render and sign-off routes
  `SET LOCAL ROLE` for their one call and nothing else can use it implicitly. Where
  `restaurant_app` is provisioned after migrations (e.g. a new Neon branch role), re-run the
  membership grant from this file. Covered by `db/tests/test_pack_server_role.sql` and
  `api/tests/test_function_grants.py`.
- `0041_mapping_revisions.sql` adds `revise_profile_mappings` (admin/editor/setup analyst): the
  Mappings page's only write. It clones a source profile's **active** approved version into a new
  approved version with account → ladder-line and management-line / product-group / labour-basis
  value changes applied, records `supersedes_profile_version_id`, makes it active and audits
  `IMPORT_MAPPING_REVISED`. Refuses stale (non-active) bases, no-op revisions, calculated ladder
  lines and identities not already in the version. Item, column and transform mappings are carried
  over unchanged. Additive; covered by `db/tests/test_mapping_revisions.sql`.
