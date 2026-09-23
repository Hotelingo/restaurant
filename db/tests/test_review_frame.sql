\set ON_ERROR_STOP on
begin;

create or replace function test_assert_eq14(actual bigint, expected bigint, label text)
returns void language plpgsql as $$
begin
  if actual <> expected then
    raise exception 'FAIL % -- expected %, got %', label, expected, actual;
  end if;
  raise notice 'PASS %', label;
end $$;

create or replace function test_assert_text14(actual text, expected text, label text)
returns void language plpgsql as $$
begin
  if actual is distinct from expected then
    raise exception 'FAIL % -- expected %, got %', label, expected, actual;
  end if;
  raise notice 'PASS %', label;
end $$;

create or replace function test_assert_rejects14(stmt text, label text)
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
  ('f0000000-0000-0000-0000-000000000001','Review Admin','review@example.com',false);

set role restaurant_app;
select set_config('app.user_id','f0000000-0000-0000-0000-000000000001',true);

select * from bootstrap_organisation(
  'Review Org','review-org','Review Outlet','REVIEW',
  'USD'::char(3),'UTC',1::smallint,'review-bootstrap-0001','review-test'
);

insert into reporting_period(
  organisation_id,outlet_id,period_start,period_end,label
)
select organisation_id,id,'2026-07-01','2026-07-31','July 2026'
from outlet where code='REVIEW';

reset role;

insert into restaurant_context(
  id,organisation_id,outlet_id,version_no,service_style,
  effective_from,created_by
)
select
  'f0000000-0000-0000-0000-000000000101',
  organisation_id,id,1,'casual dining','2026-01-01',
  'f0000000-0000-0000-0000-000000000001'
from outlet where code='REVIEW';

insert into calc_run(
  id,organisation_id,outlet_id,period_id,
  engine_version,settings_snapshot,comparator_scenario,status
)
select
  'f0000000-0000-0000-0000-000000000201',
  o.organisation_id,o.id,rp.id,
  'pl-v1',
  '{"materiality":{"general":{"id":"m-general","absolute_threshold":"1000.0000","percent_threshold":"0.100000","risk_override_enabled":true}},"comparator_selection":{"scenario":"budget","basis":"outlet_setting"}}',
  'budget','queued'
from outlet o
join reporting_period rp
  on rp.organisation_id=o.organisation_id and rp.outlet_id=o.id
where o.code='REVIEW';

update calc_run
set status='running',started_at=now()
where id='f0000000-0000-0000-0000-000000000201';

insert into calc_result(
  id,organisation_id,outlet_id,run_id,
  calc_id,grain_type,grain_key,value_numeric,unit,currency_code,
  calculation_status,evidence_status,result_metadata
)
select
  'f0000000-0000-0000-0000-000000000301',
  organisation_id,id,'f0000000-0000-0000-0000-000000000201',
  'PL.OPERATING_PROFIT','management_pl',
  '{"scenario":"actual","ladder_code":"OPERATING_PROFIT"}',
  53549,'currency','USD','CALCULATED','supported','{}'
from outlet where code='REVIEW';

update calc_run
set status='completed',completed_at=now(),result_hash=repeat('a',64)
where id='f0000000-0000-0000-0000-000000000201';

set role restaurant_app;
select set_config('app.user_id','f0000000-0000-0000-0000-000000000001',true);

select * from create_review(
  (select id from outlet where code='REVIEW'),
  (select id from reporting_period where label='July 2026'
    and outlet_id=(select id from outlet where code='REVIEW')),
  'review-create-0001',
  'review-test'
);

select * from create_review(
  (select id from outlet where code='REVIEW'),
  (select id from reporting_period where label='July 2026'
    and outlet_id=(select id from outlet where code='REVIEW')),
  'review-create-0002',
  'review-test-retry'
);

select test_assert_eq14(
  (select count(*) from review
   where outlet_id=(select id from outlet where code='REVIEW')
     and status<>'closed'),
  1,
  'one active review per outlet/period is preserved across create retries'
);

select test_assert_rejects14($q$
  select * from frame_review(
    (select id from review where outlet_id=(select id from outlet where code='REVIEW')),
    'f0000000-0000-0000-0000-000000000101',
    'f0000000-0000-0000-0000-000000000201',
    'forecast',
    'frame-wrong-comparator',
    'review-test'
  )
$q$, 'FRAME rejects comparator that does not match the completed calc snapshot');

select test_assert_text14(
  (select status::text from review
   where outlet_id=(select id from outlet where code='REVIEW')),
  'draft',
  'failed FRAME leaves the review draft'
);

select * from frame_review(
  (select id from review where outlet_id=(select id from outlet where code='REVIEW')),
  'f0000000-0000-0000-0000-000000000101',
  'f0000000-0000-0000-0000-000000000201',
  'budget',
  'frame-confirm-0001',
  'review-test'
);

select test_assert_text14(
  (select status::text from review
   where outlet_id=(select id from outlet where code='REVIEW')),
  'in_review',
  'confirmed FRAME advances draft review to in_review'
);

select test_assert_text14(
  (select comparator_scenario::text from review
   where outlet_id=(select id from outlet where code='REVIEW')),
  'budget',
  'FRAME pins the review comparator'
);

select test_assert_text14(
  (select materiality_snapshot->'general'->>'absolute_threshold'
   from review where outlet_id=(select id from outlet where code='REVIEW')),
  '1000.0000',
  'FRAME copies the exact frozen materiality snapshot from the calc run'
);

select test_assert_eq14(
  (select count(*) from calc_run r
   join review rv on rv.id=r.review_id
   where r.id='f0000000-0000-0000-0000-000000000201'
     and rv.active_calc_run_id=r.id),
  1,
  'FRAME establishes bidirectional review/calc-run lineage'
);

select * from frame_review(
  (select id from review where outlet_id=(select id from outlet where code='REVIEW')),
  'f0000000-0000-0000-0000-000000000101',
  'f0000000-0000-0000-0000-000000000201',
  'budget',
  'frame-confirm-0002',
  'review-test-repeat'
);

select test_assert_eq14(
  (select count(*) from review
   where outlet_id=(select id from outlet where code='REVIEW')),
  1,
  'same confirmed FRAME is safe to retry without duplicating review state'
);

reset role;

select test_assert_rejects14($q$
  update review
  set materiality_snapshot='{"tampered":true}'
  where outlet_id=(select id from outlet where code='REVIEW')
$q$, 'confirmed FRAME cannot be rewritten even by owner/service path');

select test_assert_rejects14($q$
  insert into review(
    organisation_id,outlet_id,period_id,review_leader_id
  )
  select
    o.organisation_id,o.id,rp.id,
    'f0000000-0000-0000-0000-000000000001'
  from outlet o
  join reporting_period rp
    on rp.organisation_id=o.organisation_id and rp.outlet_id=o.id
  where o.code='REVIEW'
$q$, 'database unique constraint blocks a second active review for the same outlet/period');

set role restaurant_app;
select set_config('app.user_id','f0000000-0000-0000-0000-000000000001',true);

select test_assert_rejects14($q$
  insert into review(
    organisation_id,outlet_id,period_id,review_leader_id
  )
  select
    o.organisation_id,o.id,rp.id,
    'f0000000-0000-0000-0000-000000000001'
  from outlet o
  join reporting_period rp
    on rp.organisation_id=o.organisation_id and rp.outlet_id=o.id
  where o.code='REVIEW'
$q$, 'application role has no direct review write path');

rollback;
