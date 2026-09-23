# Restaurant Performance Review — Data Architecture & Supabase Model v0.1

## 1. Purpose

This document converts the approved v4.2 wireframe and review methodology into the database contract for the standalone Restaurant application.

Target stack:
- Supabase PostgreSQL + Auth + Storage
- GitHub repository for source control
- Vercel deployment for the web application/API layer
- Server-authoritative calculations; browser values are presentation only

The application preserves the five-layer traceability chain:

**Raw file → Staging row → Canonical fact → Immutable calculation snapshot → Review / signed pack**

Re-mapping or recalculation creates a new higher-layer record and does not rewrite historical evidence.

---

## 2. Architectural rules

1. One PostgreSQL schema for the application.
2. `organisation_id` is present on every customer-owned table.
3. Row-level security is enforced in PostgreSQL, not only in application code.
4. Money is `numeric(20,4)` plus ISO currency code; never floating point.
5. One reporting currency per outlet for R1.
6. Canonical facts are long-form and immutable after commit.
7. A mapping is resolved when a batch is committed; later mapping changes do not rewrite old facts.
8. Calculations are versioned, deterministic and run server-side.
9. Missing values are not zero.
10. `calculation_status` and `evidence_status` are separate concepts.
11. Signed pack versions reference one locked calculation run.
12. Platform staff access requires an active staff assignment and is audited.
13. Client applications never write canonical facts or calculation results directly.

---

## 3. Recommended PostgreSQL enums

### User / workflow
- `app_role`: `admin`, `editor`, `viewer`, `reviewer`, `setup_analyst`
- `review_status`: `draft`, `in_review`, `changes_requested`, `signed`, `released`, `closed`
- `issue_disposition`: `act`, `monitor_with_trigger`, `investigate`, `escalate`, `close_no_action`

### Ingestion
- `template_code`: `T1`, `T1B`, `T2`, `T3`, `T4A`, `T4B`, `T5`, `T6`, `T7`, `T8`, `M1`, `M2`, `M3`, `M4`
- `batch_status`: `uploaded`, `parsing`, `needs_mapping`, `validating`, `blocked`, `warning`, `ready`, `committed`, `superseded`, `rejected`
- `validation_severity`: `block`, `warn`, `info`
- `scenario_code`: `actual`, `budget`, `forecast`, `prior_year`

### Evidence / calculations
- `calculation_status`: `calculated`, `not_calculated`, `error`
- `evidence_status`: `validated`, `supported`, `partly_supported`, `evidence_required`, `not_reconciled`, `not_applicable`
- `claim_status`: `draft`, `accepted`, `edited`, `rejected`

---

## 4. Tenancy and access tables

### `organisation`
- `id uuid pk`
- `name text not null`
- `slug text unique not null`
- `status text not null`
- `created_at timestamptz`

### `outlet`
- `id uuid pk`
- `organisation_id uuid fk organisation`
- `name text not null`
- `code text`
- `currency_code char(3) not null`
- `timezone text`
- `fiscal_year_start_month smallint`
- `active boolean`
- unique `(organisation_id, code)`

### `membership`
- `id uuid pk`
- `organisation_id uuid`
- `user_id uuid` → `auth.users.id`
- `role app_role`
- `outlet_scope uuid[] null` — null means all permitted outlets in the organisation
- `active boolean`
- unique `(organisation_id, user_id, role)`

### `staff_assignment`
- `id uuid pk`
- `organisation_id uuid`
- `user_id uuid`
- `outlet_id uuid null`
- `starts_at timestamptz`
- `expires_at timestamptz`
- `reason text`
- `active boolean`

### `restaurant_context`
Versioned outlet context:
- service style
- seats/capacity JSON
- meal periods JSON
- business formats JSON
- important customer sources JSON
- recipe costing status
- labour recording basis
- customer source tracking quality
- evidence maturity
- `effective_from date`
- `effective_to date null`

### `setting`
Outlet-level key/value settings:
- primary comparator
- tax basis
- sign convention
- popularity factor
- default tolerances
- display preferences

### `materiality_setting`
Versioned settings:
- `scope_type` (`general`, `food`, `beverage`, `labour`, `other_cost`, `menu`)
- absolute threshold
- percent threshold
- recurrence rule JSON
- risk override enabled
- effective dates
- approved by / approved at

### `reporting_period`
- `id uuid pk`
- `organisation_id`
- `outlet_id`
- `period_start date`
- `period_end date`
- `label text`
- `close_status text`
- unique `(outlet_id, period_start, period_end)`

---

## 5. Reference tables — platform-owned

These tables do not contain customer data.

### `ladder_framework`
Defines the Restaurant P&L framework.

### `ladder_line`
Stable codes:
- `NET_SALES`
- `PRODUCT_COST`
- `PRODUCT_MARGIN`
- `CHANNEL_COST`
- `DIRECT_LABOUR`
- `OTHER_DIRECT_OPERATING`
- `CONTRIBUTION`
- `SHARED_RESTAURANT_COST`
- `OPERATING_PROFIT`
- `OWNER_STRUCTURAL_COST`
- `OWNER_RESULT`

Columns:
- `id uuid`
- `framework_id`
- `code text unique`
- `name text`
- `kind` (`revenue`, `cost`, `subtotal`, `profit`)
- `display_order int`
- `is_calculated boolean`

### `driver_taxonomy`
Canonical drivers:
- volume
- rate_price
- mix
- productivity_intensity
- timing_cutoff
- classification_mapping
- one_off_structural
- food_price_spec
- food_yield
- food_portion
- food_production
- food_waste
- food_transfer_nonrevenue
- food_inventory_data

### `calc_definition`
- `calc_id text`
- `definition_version text`
- `module text`
- `name text`
- `unit text`
- `formula_key text`
- `active boolean`

### `template_definition`
One row per supported template version:
- template code
- version
- canonical grain
- required fields JSON
- optional fields JSON
- release
- validation profile JSON

---

## 6. Ingestion layer

### `source_file`
Immutable file metadata:
- `id uuid`
- `organisation_id`
- `outlet_id`
- `template_code`
- `storage_bucket`
- `storage_path`
- `original_filename`
- `sha256`
- `content_type`
- `size_bytes`
- `uploaded_by`
- `uploaded_at`

Supabase Storage path:
`org/{organisation_id}/outlet/{outlet_id}/source/{source_file_id}/{original_filename}`

### `source_profile`
Stable customer/report identity:
- organisation
- outlet
- template code
- source label (`Xero P&L`, `Foodics Item Sales`, etc.)
- active profile version

### `profile_version`
Immutable mapping/profile version:
- `source_profile_id`
- `version_no`
- `layout_json`
- `fingerprint_hash`
- `fingerprint_components_json`
- `transform_config_json`
- `status`
- `approved_by`
- `approved_at`
- `supersedes_profile_version_id`

### `column_mapping`
- `profile_version_id`
- `source_column`
- `canonical_field`
- `required`
- unique `(profile_version_id, source_column)`

### `account_mapping`
- `profile_version_id`
- `source_account_code`
- `source_account_name`
- `ladder_line_id`
- `mapping_basis` (`confirmed`, `suggested_then_confirmed`)
- `approved_by`
- unique source account per profile version

### `item_mapping`
- `profile_version_id`
- `source_item_code`
- `source_item_name`
- `item_id`
- unique source item per profile version

### `value_mapping`
Generic controlled normalization:
- field name
- source value
- canonical value
Examples: `Bev → Beverage`, `Dine In → Dine-in`.

### `transform_rule`
Closed-list transforms only:
- trim
- case normalization
- sign flip
- divide/multiply factor
- strip tax
- parse date
- unpivot months
- split column
- fixed value
- unit normalization

No arbitrary customer scripts inside the product.

### `import_batch`
- source file
- reporting period
- scenario
- profile version
- batch status
- detected fingerprint
- supersedes batch id
- committed by / committed at
- canonical commit hash

### `staging_row`
- import batch
- source row number
- `raw_jsonb`
- `parsed_jsonb`
- row status
- parse errors JSON

### `validation_result`
- batch
- optional staging row
- rule code
- severity
- field
- message
- expected value JSON
- actual value JSON
- resolved boolean
- resolution note

---

## 7. Canonical facts

All fact tables carry:
- `organisation_id`
- `outlet_id`
- `period_id`
- `batch_id`
- `profile_version_id`
- `staging_row_id` where one-to-one lineage exists
- `created_at`

Facts are immutable after commit.

### `account`
Customer chart-of-account identity:
- account code/name
- account section
- active dates

### `financial_fact`
Grain: outlet × period × scenario × account.
- `account_id`
- `ladder_line_id`
- `scenario`
- `amount numeric(20,4)`
- `currency_code`

Unique: `(outlet_id, period_id, scenario, account_id, batch_id)`

### `meal_period_fact`
Grain: outlet × period × meal period/business format.
- meal period
- activity units
- activity unit type (`covers`, `orders`, `attendees`)
- food revenue
- beverage revenue
- other revenue
- total revenue
- availability days/hours/seats optional

### `stock_fact`
R1 grain: outlet × period × product group/category.
- product group
- category
- opening inventory
- purchases
- closing inventory
- optional external transfer adjustment
- optional non-revenue use amount
- inventory locations snapshot JSON
- valuation basis

### `labour_fact`
Grain: outlet × period × role group.
- role group
- paid hours
- overtime hours
- labour cost
- covers/orders/workload
- scheduled hours optional

### `customer_source_fact`
- source/channel
- attributed revenue
- activity units
- direct acquisition/channel cost
- attribution evidence status

### `item`
Canonical restaurant item:
- code
- name
- product group
- menu population/category
- active dates

### `item_sales_fact`
Grain: item × period × optional meal period/channel.
- units
- net revenue
- discounts
- gross revenue optional
- availability days optional

### `recipe_version`
- item
- version code
- effective from/to
- approved by
- approved status

### `recipe_line`
- recipe version
- ingredient code/name
- approved quantity
- UOM
- yield factor
- approved unit cost
- extended approved cost

### `item_cost_snapshot`
For restaurants that provide only item-level cost:
- item
- effective date
- approved product cost/unit
- source batch

### `transaction_fact` — advanced
- check id
- item
- quantity
- net revenue
- channel
- occasion/meal period
- event timestamp

---

## 8. Calculation layer

### `calc_run`
One immutable calculation snapshot.
- `review_id`
- `engine_version`
- `settings_snapshot jsonb`
- `started_at`
- `completed_at`
- `status`
- `supersedes_calc_run_id`

### `calc_run_input`
Links the run to every committed batch/profile version it used.

### `calc_result`
- `run_id`
- `calc_id`
- `grain_type`
- `grain_key jsonb`
- `value_numeric numeric(20,4) null`
- `value_text text null`
- `unit`
- `currency_code`
- `calculation_status`
- `evidence_status`
- `explanation_code`
- `result_metadata jsonb`

Never use numeric zero to represent a missing calculation.

### `calc_dependency`
- parent calc result
- child calc result
- dependency role

This supports deterministic lineage between subtotals/bridges.

---

## 9. Review layer

### `review`
- outlet
- reporting period
- status
- comparator scenario
- context version
- materiality snapshot
- active calc run
- review leader
- started / closed timestamps

Unique active review per outlet/period.

### `review_issue`
- review
- title
- source calc result
- movement amount
- movement rate
- ladder line / module
- materiality reason
- shortlist order
- evidence status
- issue status

### `diagnosis`
- review issue
- driver class
- supported summary
- hypothesis summary
- unknowns
- diagnostic status

### `driver_evidence`
- review issue / diagnosis
- driver taxonomy
- evidence source type/id
- quantified impact nullable
- evidence status
- note
- approved by

### `evidence_request`
- review issue
- requested dataset/template
- reason
- minimum fields JSON
- requested from
- due date
- status
- linked import batch when fulfilled

### `decision`
- review issue
- disposition
- decision text
- decided by/at

### `action`
- decision
- owner user id
- lever
- guardrail
- metric
- target / trigger
- due date
- cadence
- status

### `action_event`
History of completion, comments and result checks.

### `prior_action_check`
Next-month verification:
- prior action
- current review
- completed?
- driver moved?
- financial result responded?
- result evidence
- close/reopen state

### `review_comment`
Threaded comments with role and resolution status.

---

## 10. Pack / sign-off layer

### `pack_version`
- review
- version number
- calc run
- generated at
- status
- signed artifact path/hash

### `claim`
- pack version
- section code
- claim text
- claim status
- evidence status
- accepted/edited by

### `claim_citation`
- claim
- calc_result
- optional fact/batch
- citation role

### `signoff`
- pack version
- reviewer user
- decision (`signed`, `changes_requested`)
- caveat
- timestamp

A signed pack never changes. Any edit creates the next pack version.

---

## 11. Menu / TRAIL layer

### `menu_population`
- outlet
- name
- effective dates
- popularity factor
- selection criteria JSON

### `menu_population_member`
- population
- item
- effective dates

### `item_period_metric`
Stores locked SCREEN outputs for a calc run:
- units
- menu mix %
- net revenue/unit
- product cost/unit
- Classic CM/unit
- popularity threshold
- CM benchmark
- SCREEN class

### `change_event`
Price, recipe, placement, promotion, availability or other menu change.

### `item_availability`
- period/item
- days available
- reason for limited availability

### `activity_evidence`
- item
- resource/station
- confirmed constraint boolean
- prep/service minutes
- load flag
- waste/rework notes

### `interaction_evidence`
- item
- related item
- relationship type (`complement`, `substitute`, `association`)
- metric/value
- evidence status
- causal claim allowed = false by default

### `lineup_role`
- item
- role code
- required/optional
- rationale

### `menu_decision`
- item/review
- menu action
- hypothesis
- owner
- guardrail
- review date
- evidence status

### `menu_test`
- menu decision
- baseline period
- test period
- hypothesis
- primary intervention
- guardrails JSON
- locked at

### `menu_test_result`
- menu test
- focal metric
- substitute/complement/system metrics
- observed result
- human outcome

---

## 12. RLS design

### Customer access
Every tenant table:
`organisation_id = any organisation where auth.uid() has active membership`.

Outlet-scoped memberships additionally require outlet in allowed scope.

### Direct client permissions
Client may directly:
- read permitted rows
- create/edit review decisions/actions where role allows
- upload files through signed Storage flow

Client may **not** directly:
- insert/update canonical facts
- insert/update calculation results
- alter committed batches
- alter signed pack versions

Those operations occur through server/API service credentials or tightly-scoped security-definer RPCs.

### Staff access
Staff customer access requires:
- active `staff_assignment`
- non-expired scope
- every customer-data read/action written to `audit_log`

### Audit log
Record:
- actor
- organisation/outlet
- action code
- object type/id
- before/after hashes where relevant
- timestamp
- request/correlation id

---

## 13. Database invariants to enforce with constraints

- One source account maps to one ladder line per profile version.
- One source item maps to one canonical item per profile version.
- A committed batch cannot be edited.
- A superseded batch remains queryable.
- Duplicate outlet/period/scenario/template batch blocks until explicit supersede.
- Only committed batches feed calculation runs.
- Calc results are immutable after run completion.
- Signed pack references exactly one completed calc run.
- ACT requires owner, lever, guardrail, metric and due/cadence.
- INVESTIGATE requires evidence request, owner and due date.
- MONITOR requires trigger and cadence.
- ESCALATE requires decision required, escalation owner and deadline.
- Historical signed packs and prior calc runs cannot be overwritten.

---

## 14. Recommended repository boundary

A clean monorepo keeps contracts together without coupling UI to calculations:

- `apps/web` — Next.js / TypeScript UI
- `api` — FastAPI / Python server API
- `packages/contracts` — generated/shared API schemas
- `packages/calc_engine` — pure deterministic calculation functions
- `packages/import_engine` — parsing, fingerprinting, mapping, validation
- `supabase/migrations` — SQL migrations
- `supabase/seed` — platform reference data + Amberside fixture
- `tests/golden` — deterministic fixture parity tests
- `docs` — architecture and calculation registry

The calculation and import packages must have no browser dependency.