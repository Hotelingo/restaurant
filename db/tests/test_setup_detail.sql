\set ON_ERROR_STOP on

begin;

create or replace function test_assert_eq2(actual bigint, expected bigint, label text)
returns void language plpgsql as $$
begin
  if actual <> expected then
    raise exception 'FAIL % -- expected %, got %', label, expected, actual;
  end if;
  raise notice 'PASS  %', label;
end $$;

create or replace function test_assert_rejects2(stmt text, label text)
returns void language plpgsql as $$
begin
  begin
    execute stmt;
  exception when others then
    raise notice 'PASS  %  (%)', label, sqlerrm;
    return;
  end;
  raise exception 'FAIL % -- statement was accepted but should have been rejected', label;
end $$;

insert into neon_auth."user" (id)
values ('20000000-0000-0000-0000-000000000001');

set role restaurant_app;
select set_config('app.user_id','20000000-0000-0000-0000-000000000001',true);

select * from bootstrap_organisation(
  'Setup Detail Org'::text,'setup-detail-org'::text,
  'Setup Detail Outlet'::text,'SD1'::text,
  'USD'::char(3),'UTC'::text,1::smallint,
  'setup-detail-bootstrap'::text,'ci-detail'::text
);

select * from create_restaurant_context_version(
  (select id from outlet where code='SD1'),
  'casual dining',
  '{"seats":80}'::jsonb,
  '["breakfast","lunch","dinner"]'::jsonb,
  '["dine-in"]'::jsonb,
  '["walk-in"]'::jsonb,
  'partial',
  'clocked-hours',
  'moderate',
  'developing',
  '2026-09-01',
  'context-idem-0001',
  'ci-context'
);

select * from create_restaurant_context_version(
  (select id from outlet where code='SD1'),
  'casual dining',
  '{"seats":80}'::jsonb,
  '["breakfast","lunch","dinner"]'::jsonb,
  '["dine-in"]'::jsonb,
  '["walk-in"]'::jsonb,
  'partial',
  'clocked-hours',
  'moderate',
  'developing',
  '2026-09-01',
  'context-idem-0001',
  'ci-context-retry'
);

select test_assert_eq2(
  (select count(*) from restaurant_context where outlet_id=(select id from outlet where code='SD1')),
  1,
  'context retry is idempotent'
);

select * from create_restaurant_context_version(
  (select id from outlet where code='SD1'),
  'casual dining',
  '{"seats":90}'::jsonb,
  '["lunch","dinner"]'::jsonb,
  '["dine-in","delivery"]'::jsonb,
  '["walk-in","online"]'::jsonb,
  'complete',
  'clocked-hours',
  'strong',
  'mature',
  '2026-10-01',
  'context-idem-0002',
  'ci-context-v2'
);

select test_assert_eq2(
  (select max(version_no) from restaurant_context where outlet_id=(select id from outlet where code='SD1')),
  2,
  'new context request creates the next immutable version'
);

select * from create_reporting_period(
  (select id from outlet where code='SD1'),
  '2026-09-01','2026-09-30','September 2026',
  'period-idem-0001','ci-period'
);

select * from create_reporting_period(
  (select id from outlet where code='SD1'),
  '2026-09-01','2026-09-30','September 2026',
  'period-idem-0001','ci-period-retry'
);

select test_assert_eq2(
  (select count(*) from reporting_period where outlet_id=(select id from outlet where code='SD1')),
  1,
  'period retry is idempotent'
);

select test_assert_rejects2($q$
  select * from create_reporting_period(
    (select id from outlet where code='SD1'),
    '2026-09-15','2026-10-15','Overlap',
    'period-idem-0002','ci-overlap'
  )
$q$, 'overlapping period is rejected');

rollback;
