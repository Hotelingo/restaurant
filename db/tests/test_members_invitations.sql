\set ON_ERROR_STOP on

begin;

create or replace function test_assert_eq4(actual bigint, expected bigint, label text)
returns void language plpgsql as $$
begin
  if actual <> expected then
    raise exception 'FAIL % -- expected %, got %', label, expected, actual;
  end if;
  raise notice 'PASS  %', label;
end $$;

create or replace function test_assert_bool4(actual boolean, expected boolean, label text)
returns void language plpgsql as $$
begin
  if actual is distinct from expected then
    raise exception 'FAIL % -- expected %, got %', label, expected, actual;
  end if;
  raise notice 'PASS  %', label;
end $$;

create or replace function test_assert_rejects4(stmt text, label text)
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
  ('40000000-0000-0000-0000-000000000001','Admin User','admin@example.com'),
  ('40000000-0000-0000-0000-000000000002','Viewer User','viewer@example.com');

set role restaurant_app;
select set_config('app.user_id','40000000-0000-0000-0000-000000000001',true);

select * from bootstrap_organisation(
  'Member Test Org','member-test-org','Outlet One','MEM1',
  'USD'::char(3),'UTC',1::smallint,'member-bootstrap-0001','ci-members'
);

select * from create_outlet(
  (select id from organisation where slug='member-test-org'),
  'Outlet Two','MEM2','USD'::char(3),'UTC',1::smallint,
  'member-outlet-0001','ci-members'
);

select * from create_member_invitation(
  (select id from organisation where slug='member-test-org'),
  'viewer@example.com',
  'viewer'::app_role,
  'selected_outlets'::membership_scope_mode,
  array[(select id from outlet where code='MEM1')]::uuid[],
  repeat('a',64),
  now()+interval '72 hours',
  'ci-members'
);

select test_assert_eq4(
  (select count(*) from preview_member_invitation(repeat('a',64)) where effective_status='pending'),
  1,
  'signed invitation preview is available before acceptance'
);

select test_assert_rejects4($q$
  select * from create_member_invitation(
    (select id from organisation where slug='member-test-org'),
    'viewer@example.com',
    'setup_analyst'::app_role,
    'all_outlets'::membership_scope_mode,
    array[]::uuid[],
    repeat('b',64),
    now()+interval '72 hours',
    'ci-members'
  )
$q$, 'setup analyst cannot be invited as a customer membership');

select set_config('app.user_id','40000000-0000-0000-0000-000000000002',true);

select * from accept_member_invitation(repeat('a',64),'ci-member-accept');

select test_assert_eq4((select count(*) from organisation),1,
  'accepted viewer sees invited organisation');
select test_assert_eq4((select count(*) from outlet),1,
  'selected-outlet viewer sees exactly one outlet');
select test_assert_eq4((select count(*) from outlet where code='MEM2'),0,
  'selected-outlet viewer cannot discover other outlet');

select test_assert_rejects4($q$
  select * from accept_member_invitation(repeat('a',64),'ci-member-accept-retry')
$q$, 'accepted invitation cannot be accepted twice');

select set_config('app.user_id','40000000-0000-0000-0000-000000000001',true);

select test_assert_eq4(
  (select count(*) from member_invitation where status='accepted'),
  1,
  'admin sees accepted invitation status'
);

select * from set_membership_active(
  (select id from organisation where slug='member-test-org'),
  (select id from membership
    where user_id='40000000-0000-0000-0000-000000000002' and role='viewer'),
  false,
  'ci-member-deactivate'
);

select test_assert_bool4(
  (select active from membership
    where user_id='40000000-0000-0000-0000-000000000002' and role='viewer'),
  false,
  'admin can deactivate invited membership'
);

select * from set_membership_active(
  (select id from organisation where slug='member-test-org'),
  (select id from membership
    where user_id='40000000-0000-0000-0000-000000000002' and role='viewer'),
  true,
  'ci-member-reactivate'
);

select test_assert_rejects4($q$
  select * from set_membership_active(
    (select id from organisation where slug='member-test-org'),
    (select id from membership
      where user_id='40000000-0000-0000-0000-000000000001' and role='admin'),
    false,
    'ci-last-admin'
  )
$q$, 'last full-organisation admin cannot deactivate self');

select * from create_member_invitation(
  (select id from organisation where slug='member-test-org'),
  'viewer@example.com',
  'editor'::app_role,
  'all_outlets'::membership_scope_mode,
  array[]::uuid[],
  repeat('c',64),
  now()+interval '72 hours',
  'ci-members'
);

select set_config('app.user_id','40000000-0000-0000-0000-000000000002',true);
select * from decline_member_invitation(repeat('c',64),'ci-member-decline');

select set_config('app.user_id','40000000-0000-0000-0000-000000000001',true);
select test_assert_eq4(
  (select count(*) from member_invitation where status='declined'),
  1,
  'recipient can decline a matching invitation'
);

reset role;
rollback;
