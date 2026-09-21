# Migrations — accepted Slice 1 baseline

**Status: ACCEPTED for Slice 1 on 2026-09-21.** OD-01 through OD-12 are resolved. This baseline
incorporates OD-04 outlet scoping, OD-06 authentication-role implications, and OD-10 materiality
metadata. It remains subject to migration tests before deployment to preview/production.

The original draft is preserved untouched at `docs/source/Supabase_Schema_Draft_v0_1.sql`. Nothing
here silently overwrites it — every deviation is listed below with the gap it closes.

## Scope

Slice 1 only: tenancy, context, settings, materiality, audit, plus the platform reference tables.
Ingestion, facts, calculation and review tables arrive with their own slices, per the phase map.

## Files

| File | Contents |
|---|---|
| `0001_enums_and_reference.sql` | Enums and platform-owned reference tables |
| `0002_slice1_core.sql` | Tenancy, periods, context, settings, materiality, audit |
| `0003_immutability.sql` | Immutability trigger functions and slice-1 triggers |
| `0004_rls.sql` | RLS helpers, enablement and policies |

## Verified

The pre-decision baseline applied cleanly to PostgreSQL 16.13 from an empty database. The accepted
revision adds explicit outlet-scope semantics and staff outlet scoping and must remain green under:
- `supabase/tests/test_slice1_constraints.sql`
- `supabase/tests/test_slice1_rls.sql`

Do not deploy these migrations merely because they parse; the RLS suite is part of acceptance.

Applying them needs two Supabase objects that exist in a real project but not in a bare cluster —
`auth.users` and `auth.uid()`. `supabase/tests/README.md` has the stubs.

## Deviations from the draft schema

| Gap | Draft | Here | Why |
|---|---|---|---|
| **G-01** | No policies; one commented-out hint | RLS enabled on all 15 tables, 23 policies, four `security definer` helpers | The architecture document's rule 3 was unimplemented |
| **G-02** | `outlet_id references outlet(id)` | Composite FK `(organisation_id, outlet_id)` with `unique (organisation_id, id)` on parents | A row could carry org A's `organisation_id` and org B's `outlet_id`; RLS filters on `organisation_id` and would expose it. Now unrepresentable |
| **G-03** | `unique (organisation_id, code)` with `code` nullable | `unique nulls not distinct` | PostgreSQL treats NULLs as distinct, so the draft permitted unlimited code-less duplicates. The same defect on `account_mapping` silently voided the "one source account → one ladder line" invariant |
| **G-05** | Immutability documented only | `forbid_mutation()`, `forbid_mutation_when_final()`, `forbid_mutation_when_approved()` | Invariants a database does not enforce are hopes. If a signed pack can change after signature, the signature means nothing |
| **G-08** | No indexes | Indexes with each table | Hot paths are known now; adding them later means a migration under load |
| **G-09** | Missing | `restaurant_context`, `setting`, `materiality_setting`, `audit_log`, `staff_assignment`, `calc_definition`, `template_definition`, `driver_taxonomy` | `materiality_setting` feeds `SEQ.FIRST_MATERIAL_MOVEMENT`, slice acceptance criterion #7; `audit_log` is required by the staff-access rule |
| **G-10** | `template_code` as `text`; no `updated_at` | `template_code` enum; `updated_at` with triggers | Consistency with the architecture document |
| **G-11 / OD-04** | `membership.outlet_scope uuid[]` | explicit `membership.outlet_scope_mode` + `membership_outlet` join table | `all_outlets` is explicit; `selected_outlets` requires join rows; selected scope with zero rows grants zero access. Composite FKs prevent cross-organisation scope rows. |

Additional domain constraints not in the draft: `materiality_setting` requires at least one
positive threshold, percentages are stored as ratios in (0,1], approval requires both approver and
timestamp, and source is classified as product default / user confirmed / user modified;
`reporting_period` requires `period_end >= period_start`; `staff_assignment` requires
`expires_at > starts_at`; `ladder_line.kind` is constrained to the four valid kinds.

## Decisions that affect later migrations

**G-07 / OD-03 — budget grain is resolved.** In Slice 3, `financial_fact.account_id` must be
nullable for ladder-grain comparator rows and required for `scenario='actual'`. `ladder_line_id`
remains required. Do not create synthetic accounts. Use separate/partial uniqueness rules for
account-grain and ladder-grain facts.

## Phase map (G-12)

| Slice | Tables |
|---|---|
| 1 ✅ | `organisation`, `outlet`, `membership`, `membership_outlet`, `staff_assignment`, `reporting_period`, `restaurant_context`, `setting`, `materiality_setting`, `audit_log`, `ladder_framework`, `ladder_line`, `driver_taxonomy`, `calc_definition`, `template_definition` |
| 2 | `source_file`, `source_profile`, `profile_version`, `column_mapping`, `account_mapping`, `item_mapping`, `value_mapping`, `transform_rule`, `import_batch`, `staging_row`, `validation_result` |
| 3 | `account`, `financial_fact`, `calc_run`, `calc_run_input`, `calc_result`, `calc_dependency` |
| 4 | `review`, `review_issue`, `diagnosis`, `driver_evidence`, `evidence_request`, `decision`, `action`, `action_event`, `prior_action_check`, `review_comment`, `pack_version`, `claim`, `claim_citation`, `signoff` |
| 5 | `stock_fact`, `item`, `item_sales_fact`, `recipe_version`, `recipe_line`, `item_cost_snapshot` |
| 6 | `meal_period_fact`, `customer_source_fact` |
| 7 | `labour_fact` |
| 9 | `menu_population`, `menu_population_member`, `item_period_metric`, `change_event`, `item_availability`, `activity_evidence`, `interaction_evidence`, `lineup_role`, `menu_decision`, `menu_test`, `menu_test_result` |
| 10 | `transaction_fact` |

## Rules for every future migration

- Composite tenancy foreign keys on every table carrying both `organisation_id` and `outlet_id`.
- RLS enabled **and a policy written** — enabling RLS without a policy denies everything, which
  fails closed but also fails loudly in the wrong place.
- **No client INSERT or UPDATE policy on canonical facts or calculation results, ever.** Those
  writes go through service credentials or scoped security-definer RPCs.
- `NULLS NOT DISTINCT` on any unique constraint containing a nullable column.
- Immutability triggers per the list at the foot of `0003`, each with a test that attempts the
  mutation **as the service role** — a test that only proves a normal client is blocked proves
  nothing, since the service role is where the risk lives.
- Indexes in the same migration as the table.
- A stated rollback or forward-fix plan. No destructive migration without one.
