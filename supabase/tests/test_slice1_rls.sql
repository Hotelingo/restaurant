-- Slice 1 RLS tests
--
-- Run after migrations against a scratch Supabase/PostgreSQL database using the
-- auth stubs from supabase/tests/README.md. This script deliberately grants the
-- test roles table privileges so failures prove RLS behaviour, not missing
-- GRANTs.
--
-- The fixtures roll back at the end.

\set ON_ERROR_STOP on
\set QUIET on

begin;

-- ---------------------------------------------------------------- helpers

create or replace function public.test_assert_eq(actual bigint, expected bigint, label text)
returns void
language plpgsql
as $$
begin
  if actual <> expected then
    raise exception 'FAIL % -- expected %, got %', label, expected, actual;
  end if;
  raise notice 'PASS  %', label;
end $$;

create or replace function public.test_assert_rejects(stmt text, label text)
returns void
language plpgsql
as $$
begin
  begin
    execute stmt;
  exception when others then
    raise notice 'PASS  %  (%)', label, sqlerrm;
    return;
  end;
  raise exception 'FAIL % -- statement was accepted but should have been rejected', label;
end $$;

grant execute on function public.test_assert_eq(bigint,bigint,text) to authenticated;
grant execute on function public.test_assert_rejects(text,text) to authenticated;

grant usage on schema public to authenticated;
grant select, insert, update, delete on
  organisation, outlet, membership, membership_outlet, staff_assignment,
  reporting_period, restaurant_context, setting, materiality_setting, audit_log
to authenticated;

-- anon should have enough SQL privilege that RLS, not GRANT, is what returns zero.
grant usage on schema public to anon;
grant select on organisation, outlet, reporting_period, restaurant_context,
  setting, materiality_setting to anon;

-- ---------------------------------------------------------------- fixture users

insert into auth.users (id, email) values
  ('10000000-0000-0000-0000-000000000001','admin-a@example.test'),
  ('10000000-0000-0000-0000-000000000002','editor-a@example.test'),
  ('10000000-0000-0000-0000-000000000003','editor-b@example.test'),
  ('10000000-0000-0000-0000-000000000004','staff-a2@example.test'),
  ('10000000-0000-0000-0000-000000000005','expired-staff@example.test'),
  ('10000000-0000-0000-0000-000000000006','scoped-admin-a@example.test');

insert into organisation (id,name,slug) values
  ('20000000-0000-0000-0000-000000000001','Org A','rls-org-a'),
  ('20000000-0000-0000-0000-000000000002','Org B','rls-org-b');

insert into outlet (id,organisation_id,name,code,currency_code) values
  ('30000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','A One','A1','USD'),
  ('30000000-0000-0000-0000-000000000002','20000000-0000-0000-0000-000000000001','A Two','A2','USD'),
  ('30000000-0000-0000-0000-000000000003','20000000-0000-0000-0000-000000000002','B One','B1','USD');

insert into membership (id,organisation_id,user_id,role,outlet_scope_mode) values
  ('40000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001',
   '10000000-0000-0000-0000-000000000001','admin','all_outlets'),
  ('40000000-0000-0000-0000-000000000002','20000000-0000-0000-0000-000000000001',
   '10000000-0000-0000-0000-000000000002','editor','selected_outlets'),
  ('40000000-0000-0000-0000-000000000003','20000000-0000-0000-0000-000000000002',
   '10000000-0000-0000-0000-000000000003','editor','all_outlets'),
  ('40000000-0000-0000-0000-000000000004','20000000-0000-0000-0000-000000000001',
   '10000000-0000-0000-0000-000000000006','admin','selected_outlets');

insert into membership_outlet (membership_id,organisation_id,outlet_id) values
  ('40000000-0000-0000-0000-000000000002','20000000-0000-0000-0000-000000000001',
   '30000000-0000-0000-0000-000000000001'),
  ('40000000-0000-0000-0000-000000000004','20000000-0000-0000-0000-000000000001',
   '30000000-0000-0000-0000-000000000001');

insert into audit_log (actor_user_id,organisation_id,outlet_id,action_code,object_type,object_id)
values ('10000000-0000-0000-0000-000000000001',
        '20000000-0000-0000-0000-000000000001',
        '30000000-0000-0000-0000-000000000001',
        'TEST_READ','outlet','30000000-0000-0000-0000-000000000001');

insert into staff_assignment
  (id,organisation_id,user_id,outlet_id,starts_at,expires_at,reason,active)
values
  ('50000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001',
   '10000000-0000-0000-0000-000000000004','30000000-0000-0000-0000-000000000002',
   now() - interval '1 hour', now() + interval '1 day', 'RLS test', true),
  ('50000000-0000-0000-0000-000000000002','20000000-0000-0000-0000-000000000001',
   '10000000-0000-0000-0000-000000000005',null,
   now() - interval '2 days', now() - interval '1 day', 'Expired RLS test', true);

-- ---------------------------------------------------------------- all-outlets admin A

set role authenticated;
select set_config('request.jwt.claim.sub','10000000-0000-0000-0000-000000000001',true);

select public.test_assert_eq((select count(*) from organisation),1,
  'admin A sees only organisation A');
select public.test_assert_eq((select count(*) from outlet),2,
  'all_outlets admin A sees both A outlets and no B outlet');
select public.test_assert_eq((select count(*) from audit_log),1,
  'full-scope admin can read organisation audit trail');

reset role;

-- ---------------------------------------------------------------- selected editor A

set role authenticated;
select set_config('request.jwt.claim.sub','10000000-0000-0000-0000-000000000002',true);

select public.test_assert_eq((select count(*) from outlet),1,
  'selected_outlets editor sees only joined outlet');
select public.test_assert_eq(
  (select count(*) from outlet where id='30000000-0000-0000-0000-000000000003'),0,
  'selected editor cannot read cross-tenant outlet');

select public.test_assert_rejects($q$
  insert into reporting_period
    (organisation_id,outlet_id,period_start,period_end,label)
  values
    ('20000000-0000-0000-0000-000000000001',
     '30000000-0000-0000-0000-000000000002',
     '2026-09-01','2026-09-30','Sep blocked')
$q$, 'selected editor cannot write an unscoped outlet');

reset role;

-- selected_outlets with zero rows must fail closed, never become "all".
delete from membership_outlet
where membership_id='40000000-0000-0000-0000-000000000002';

set role authenticated;
select set_config('request.jwt.claim.sub','10000000-0000-0000-0000-000000000002',true);
select public.test_assert_eq((select count(*) from outlet),0,
  'selected_outlets with no joins grants zero outlets');
reset role;

-- ---------------------------------------------------------------- scoped admin cannot escalate own scope

set role authenticated;
select set_config('request.jwt.claim.sub','10000000-0000-0000-0000-000000000006',true);

select public.test_assert_eq((select count(*) from outlet),1,
  'outlet-scoped admin sees only selected outlet');
select public.test_assert_eq((select count(*) from audit_log),0,
  'outlet-scoped admin cannot read organisation-wide audit trail');

select public.test_assert_rejects($q$
  insert into membership
    (organisation_id,user_id,role,outlet_scope_mode)
  values
    ('20000000-0000-0000-0000-000000000001',
     '10000000-0000-0000-0000-000000000006',
     'viewer','all_outlets')
$q$, 'outlet-scoped admin cannot grant organisation-wide membership');

reset role;

-- ---------------------------------------------------------------- outlet-scoped staff

set role authenticated;
select set_config('request.jwt.claim.sub','10000000-0000-0000-0000-000000000004',true);

select public.test_assert_eq((select count(*) from organisation),1,
  'active outlet-scoped staff can resolve assigned organisation');
select public.test_assert_eq((select count(*) from outlet),1,
  'outlet-scoped staff sees assigned outlet only');

reset role;

-- ---------------------------------------------------------------- expired staff

set role authenticated;
select set_config('request.jwt.claim.sub','10000000-0000-0000-0000-000000000005',true);

select public.test_assert_eq((select count(*) from organisation),0,
  'expired staff assignment grants no organisation access');
select public.test_assert_eq((select count(*) from outlet),0,
  'expired staff assignment grants no outlet access');

reset role;

-- ---------------------------------------------------------------- other tenant

set role authenticated;
select set_config('request.jwt.claim.sub','10000000-0000-0000-0000-000000000003',true);

select public.test_assert_eq((select count(*) from organisation),1,
  'org B user sees exactly one organisation');
select public.test_assert_eq((select count(*) from outlet),1,
  'org B user sees only B outlet');

reset role;

-- ---------------------------------------------------------------- anonymous

set role anon;
select public.test_assert_eq((select count(*) from organisation),0,
  'anonymous user reads zero organisations');
select public.test_assert_eq((select count(*) from outlet),0,
  'anonymous user reads zero outlets');
reset role;

rollback;
