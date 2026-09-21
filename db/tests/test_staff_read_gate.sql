\set ON_ERROR_STOP on

begin;

create or replace function test_assert_eq5(actual bigint, expected bigint, label text)
returns void language plpgsql as $$
begin
  if actual <> expected then
    raise exception 'FAIL % -- expected %, got %', label, expected, actual;
  end if;
  raise notice 'PASS  %', label;
end $$;

create or replace function test_assert_bool5(actual boolean, expected boolean, label text)
returns void language plpgsql as $$
begin
  if actual is distinct from expected then
    raise exception 'FAIL % -- expected %, got %', label, expected, actual;
  end if;
  raise notice 'PASS  %', label;
end $$;

create or replace function test_assert_rejects5(stmt text, label text)
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

insert into neon_auth."user" (id,name,email) values
  ('50000000-0000-0000-0000-000000000001','Admin','admin5@example.com'),
  ('50000000-0000-0000-0000-000000000002','Staff','staff5@example.com');

set role restaurant_app;
select set_config('app.user_id','50000000-0000-0000-0000-000000000001',true);

select * from bootstrap_organisation(
  'Staff Gate Org','staff-gate-org','Outlet One','SG1',
  'USD'::char(3),'UTC',1::smallint,'staff-gate-bootstrap','ci-staff-gate'
);

select * from create_outlet(
  (select id from organisation where slug='staff-gate-org'),
  'Outlet Two','SG2','USD'::char(3),'UTC',1::smallint,
  'staff-gate-outlet-2','ci-staff-gate'
);

reset role;

insert into staff_assignment(
  organisation_id,user_id,outlet_id,starts_at,expires_at,reason,active
)
select
  o.organisation_id,
  '50000000-0000-0000-0000-000000000002',
  o.id,
  now()-interval '5 minutes',
  now()+interval '2 hours',
  'CI staff read gate',
  true
from outlet o
where o.code='SG1';

set role restaurant_app;
select set_config('app.user_id','50000000-0000-0000-0000-000000000002',true);

select test_assert_eq5(
  (select count(*) from organisation where slug='staff-gate-org'),
  0,
  'active staff assignment alone does not expose organisation data'
);

select test_assert_eq5(
  (select count(*) from outlet where code in ('SG1','SG2')),
  0,
  'active staff assignment alone does not expose outlet data'
);

select test_assert_bool5(
  has_staff_access((select organisation_id from staff_assignment where user_id=current_app_user_id() limit 1)),
  false,
  'staff access helper is false before audited grant'
);

select authorize_staff_read(
  (select organisation_id from staff_assignment where user_id=current_app_user_id() limit 1),
  (select outlet_id from staff_assignment where user_id=current_app_user_id() limit 1),
  'STAFF_SETUP_READ',
  'outlet',
  (select outlet_id::text from staff_assignment where user_id=current_app_user_id() limit 1),
  'ci-staff-read-1'
);

select test_assert_eq5(
  (select count(*) from organisation where slug='staff-gate-org'),
  1,
  'audited staff grant exposes organisation metadata for the scoped request'
);

select test_assert_eq5(
  (select count(*) from outlet where code='SG1'),
  1,
  'audited staff grant exposes assigned outlet'
);

select test_assert_eq5(
  (select count(*) from outlet where code='SG2'),
  0,
  'audited staff grant does not expose another outlet'
);

reset role;

select test_assert_eq5(
  (select count(*) from audit_log
   where actor_user_id='50000000-0000-0000-0000-000000000002'
     and action_code='STAFF_SETUP_READ'
     and correlation_id='ci-staff-read-1'),
  1,
  'staff read authorization writes exactly one audit event'
);

update staff_assignment
set expires_at=now()-interval '1 minute'
where user_id='50000000-0000-0000-0000-000000000002';

set role restaurant_app;
select set_config('app.user_id','50000000-0000-0000-0000-000000000002',true);

select test_assert_rejects5($q$
  select authorize_staff_read(
    (select organisation_id from staff_assignment where user_id=current_app_user_id() limit 1),
    (select outlet_id from staff_assignment where user_id=current_app_user_id() limit 1),
    'STAFF_SETUP_READ',
    'outlet',
    null,
    'ci-staff-read-expired'
  )
$q$, 'expired staff assignment cannot authorize a read');

reset role;
rollback;
