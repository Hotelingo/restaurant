\set ON_ERROR_STOP on
begin;

create or replace function test_assert_eq21(actual bigint, expected bigint, label text)
returns void language plpgsql as $$
begin
  if actual <> expected then
    raise exception 'FAIL % -- expected %, got %', label, expected, actual;
  end if;
  raise notice 'PASS %', label;
end $$;

create or replace function test_assert_text21(actual text, expected text, label text)
returns void language plpgsql as $$
begin
  if actual is distinct from expected then
    raise exception 'FAIL % -- expected %, got %', label, expected, actual;
  end if;
  raise notice 'PASS %', label;
end $$;

create or replace function test_assert_rejects21(stmt text, label text)
returns void language plpgsql as $$
begin
  begin
    execute stmt;
  exception when others then
    raise notice 'PASS % (%)', label, sqlerrm;
    return;
  end;
  raise exception 'FAIL % -- statement was accepted but should have been rejected', label;
end $$;

insert into neon_auth."user"(id,name,email,"emailVerified") values
  ('21000000-0000-0000-0000-000000000001','Review Admin','review-admin@example.com',false),
  ('21000000-0000-0000-0000-000000000002','Other Admin','other-review@example.com',false);

set role restaurant_app;
select set_config('app.user_id','21000000-0000-0000-0000-000000000001',true);

select * from bootstrap_organisation(
  'Review Org','review-org','Review Outlet','REV',
  'USD'::char(3),'UTC',1::smallint,'review-bootstrap-1','review-test'
);

insert into reporting_period(
  organisation_id,outlet_id,period_start,period_end,label
)
select organisation_id,id,'2026-07-01','2026-07-31','July 2026'
from outlet where code='REV';

reset role;

insert into restaurant_context(
  id,organisation_id,outlet_id,version_no,
  service_style,capacity_json,meal_periods_json,business_formats_json,
  customer_sources_json,recipe_costing_status,labour_recording_basis,
  source_tracking_quality,evidence_maturity,
  effective_from,created_by
)
select
  '21000000-0000-0000-0000-000000000101',
  organisation_id,id,1,
  'full_service','{"seats":80}','["Lunch","Dinner"]','["Dine-in"]',
  '["Direct"]','partial','paid_hours','structured','structured',
  '2026-01-01','21000000-0000-0000-0000-000000000001'
from outlet where code='REV';

insert into materiality_setting(
  id,organisation_id,outlet_id,scope_type,
  absolute_threshold,percent_threshold,source_kind,
  proposal_basis,recurrence_rule,risk_override_enabled,
  effective_from,approved_by,approved_at
)
select
  '21000000-0000-0000-0000-000000000102',
  organisation_id,id,'general',
  1000,0.10,'user_confirmed',
  '{"basis":"confirmed for test"}','{}',true,
  '2026-01-01',
  '21000000-0000-0000-0000-000000000001',now()
from outlet where code='REV';

insert into calc_run(
  id,organisation_id,outlet_id,period_id,
  engine_version,settings_snapshot,comparator_scenario,status
)
select
  '21000000-0000-0000-0000-000000000201',
  o.organisation_id,o.id,rp.id,
  'pl-v1',
  jsonb_build_object(
    'materiality',
    jsonb_build_object(
      'general',
      jsonb_build_object(
        'id','21000000-0000-0000-0000-000000000102',
        'absolute_threshold','1000',
        'percent_threshold','0.10',
        'source_kind','user_confirmed',
        'proposal_basis',jsonb_build_object('basis','confirmed for test'),
        'recurrence_rule','{}'::jsonb,
        'risk_override_enabled',true,
        'effective_from','2026-01-01',
        'effective_to',null,
        'approved_by','21000000-0000-0000-0000-000000000001',
        'approved_at','2026-09-22T07:00:00+00:00'
      )
    ),
    'comparator_selection',
    jsonb_build_object('scenario','budget','basis','outlet_setting')
  ),
  'budget','queued'
from outlet o
join reporting_period rp
  on rp.organisation_id=o.organisation_id and rp.outlet_id=o.id
where o.code='REV';

update calc_run
set status='running',started_at=now()
where id='21000000-0000-0000-0000-000000000201';

update calc_run
set status='completed',completed_at=now(),result_hash=repeat('a',64)
where id='21000000-0000-0000-0000-000000000201';

set role restaurant_app;
select set_config('app.user_id','21000000-0000-0000-0000-000000000001',true);

select * from create_review(
  (select id from outlet where code='REV'),
  (select id from reporting_period where label='July 2026' and outlet_id=(select id from outlet where code='REV')),
  '21000000-0000-0000-0000-000000000201',
  'review-create-0001',
  'review-test'
);

select test_assert_eq21(
  (select count(*) from review where outlet_id=(select id from outlet where code='REV')),
  1,
  'review create persists exactly one active review'
);

select test_assert_text21(
  (select status::text from review where outlet_id=(select id from outlet where code='REV')),
  'draft',
  'new review begins in draft'
);

select test_assert_text21(
  (select comparator_scenario::text from review where outlet_id=(select id from outlet where code='REV')),
  'budget',
  'review comparator is pinned from completed calc run'
);

select test_assert_text21(
  (select context_version_id::text from review where outlet_id=(select id from outlet where code='REV')),
  '21000000-0000-0000-0000-000000000101',
  'review pins the period-effective context version'
);

select test_assert_text21(
  (select materiality_snapshot->'general'->>'absolute_threshold'
   from review where outlet_id=(select id from outlet where code='REV')),
  '1000',
  'review materiality is the frozen calc-run snapshot'
);

select test_assert_text21(
  (select active_calc_run_id::text from review where outlet_id=(select id from outlet where code='REV')),
  '21000000-0000-0000-0000-000000000201',
  'review pins one completed calc run'
);

-- Retry is idempotent.
select * from create_review(
  (select id from outlet where code='REV'),
  (select id from reporting_period where label='July 2026' and outlet_id=(select id from outlet where code='REV')),
  '21000000-0000-0000-0000-000000000201',
  'review-create-0001',
  'review-retry'
);

select test_assert_eq21(
  (select count(*) from review where outlet_id=(select id from outlet where code='REV')),
  1,
  'review create retry does not duplicate the review'
);

-- A second active review for the same outlet/period is prohibited.
select test_assert_rejects21($q$
  select * from create_review(
    (select id from outlet where code='REV'),
    (select id from reporting_period where label='July 2026' and outlet_id=(select id from outlet where code='REV')),
    '21000000-0000-0000-0000-000000000201',
    'review-create-0002',
    'review-duplicate'
  )
$q$, 'database enforces one active review per outlet and period');

select * from confirm_review_frame(
  (select id from review where outlet_id=(select id from outlet where code='REV')),
  '{
    "accounts_closed":"yes",
    "material_invoices_in":"yes",
    "inventory_count_complete":"no",
    "cutoff_checked":"yes"
  }'::jsonb,
  'Budget is the owner-approved July plan.',
  '{
    "meal_period_definitions":{"status":"same","reviewed":true},
    "unit_definitions":{"status":"same","reviewed":true},
    "cost_classification":{"status":"same","reviewed":true},
    "comparator_basis":{"status":"same","reviewed":true},
    "operating_days":{"status":"changed","reviewed":true}
  }'::jsonb,
  '{
    "safety":true,
    "control":true,
    "legal_compliance":false,
    "guest_impact":false,
    "recurrence":true
  }'::jsonb,
  'review-frame-0001',
  'review-test'
);

select test_assert_text21(
  (select status::text from review where outlet_id=(select id from outlet where code='REV')),
  'in_review',
  'confirmed FRAME advances review to in_review'
);

select test_assert_text21(
  (select close_status_snapshot->>'inventory_count_complete'
   from review where outlet_id=(select id from outlet where code='REV')),
  'no',
  'FRAME preserves a negative close check instead of blocking the review'
);

select test_assert_text21(
  (select definition_continuity_snapshot->'operating_days'->>'status'
   from review where outlet_id=(select id from outlet where code='REV')),
  'changed',
  'FRAME preserves changed definitions explicitly'
);

-- Confirmation retry returns prior response and does not mutate the snapshot.
select * from confirm_review_frame(
  (select id from review where outlet_id=(select id from outlet where code='REV')),
  '{}'::jsonb,
  'ignored on idempotent retry',
  '{}'::jsonb,
  '{}'::jsonb,
  'review-frame-0001',
  'review-frame-retry'
);

select test_assert_eq21(
  (select count(*) from audit_log where action_code='REVIEW_FRAME_CONFIRMED'),
  1,
  'idempotent FRAME retry does not duplicate audit event'
);

reset role;

select test_assert_rejects21($q$
  update review
  set materiality_snapshot='{"tampered":true}'
  where outlet_id=(select id from outlet where code='REV')
$q$, 'confirmed review snapshot cannot be rewritten by owner/service path');

select test_assert_rejects21($q$
  delete from review
  where outlet_id=(select id from outlet where code='REV')
$q$, 'review history cannot be deleted');

-- RLS: another tenant cannot see Review Org's review.
set role restaurant_app;
select set_config('app.user_id','21000000-0000-0000-0000-000000000002',true);

select * from bootstrap_organisation(
  'Other Review Org','other-review-org','Other Review Outlet','OREV',
  'USD'::char(3),'UTC',1::smallint,'other-review-bootstrap','review-rls'
);

select test_assert_eq21(
  (select count(*) from review where outlet_id=(select id from outlet where code='REV')),
  0,
  'cross-tenant review read is hidden by RLS'
);

rollback;
