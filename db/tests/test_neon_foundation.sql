\set ON_ERROR_STOP on

begin;

create or replace function test_assert_eq(actual bigint, expected bigint, label text)
returns void language plpgsql as $$
begin
  if actual <> expected then
    raise exception 'FAIL % -- expected %, got %', label, expected, actual;
  end if;
  raise notice 'PASS  %', label;
end $$;

create or replace function test_assert_rejects(stmt text, label text)
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

insert into neon_auth."user" (id) values
  ('10000000-0000-0000-0000-000000000001'),
  ('10000000-0000-0000-0000-000000000002'),
  ('10000000-0000-0000-0000-000000000003');

set role restaurant_app;

select set_config('app.user_id','10000000-0000-0000-0000-000000000001',true);

select * from bootstrap_organisation(
  'Org A'::text,'org-a'::text,'A One'::text,'A1'::text,
  'USD'::char(3),'UTC'::text,1::smallint,'ci-bootstrap-a'::text
);

insert into outlet (
  organisation_id,name,code,currency_code,timezone,fiscal_year_start_month
)
select id,'A Two','A2','USD','UTC',1
from organisation where slug='org-a';

insert into membership (
  organisation_id,user_id,role,outlet_scope_mode
)
select id,'10000000-0000-0000-0000-000000000002','viewer','selected_outlets'
from organisation where slug='org-a';

insert into membership_outlet (membership_id,organisation_id,outlet_id)
select
  m.id,
  m.organisation_id,
  o.id
from membership m
join organisation org on org.id=m.organisation_id and org.slug='org-a'
join outlet o on o.organisation_id=org.id and o.code='A1'
where m.user_id='10000000-0000-0000-0000-000000000002'
  and m.role='viewer';

select test_assert_eq((select count(*) from outlet),2,
  'all_outlets admin sees both outlets');

select * from bootstrap_organisation(
  'Org A'::text,'org-a'::text,'A One'::text,'A1'::text,
  'USD'::char(3),'UTC'::text,1::smallint,'ci-bootstrap-a'::text
);

select test_assert_eq(
  (select count(*) from membership
   where user_id='10000000-0000-0000-0000-000000000001'),
  1,
  'bootstrap retry returns prior result without duplicate membership'
);

select set_config('app.user_id','10000000-0000-0000-0000-000000000002',true);

select test_assert_eq((select count(*) from organisation),1,
  'selected viewer sees its organisation');
select test_assert_eq((select count(*) from outlet),1,
  'selected viewer sees only selected outlet');
select test_assert_eq((select count(*) from outlet where code='A2'),0,
  'selected viewer cannot see unselected outlet');

select set_config('app.user_id','10000000-0000-0000-0000-000000000003',true);

select test_assert_eq((select count(*) from organisation),0,
  'unaffiliated user sees zero organisations');
select test_assert_eq((select count(*) from outlet),0,
  'unaffiliated user sees zero outlets');

select test_assert_rejects($q$
  insert into organisation(name,slug) values ('Bypass','bypass')
$q$, 'direct organisation insert is blocked by RLS');

select * from bootstrap_organisation(
  'Org B'::text,'org-b'::text,'B One'::text,'B1'::text,
  'USD'::char(3),'UTC'::text,1::smallint,'ci-bootstrap-b'::text
);

select test_assert_eq((select count(*) from organisation),1,
  'Org B admin sees only Org B');

select set_config('app.user_id','10000000-0000-0000-0000-000000000001',true);

select test_assert_eq((select count(*) from organisation),1,
  'Org A admin still sees only Org A after Org B exists');

insert into reporting_period (
  organisation_id,outlet_id,period_start,period_end,label
)
select o.organisation_id,o.id,'2026-07-01','2026-07-31','July 2026'
from outlet o where o.code='A1';

select test_assert_rejects($q$
  insert into reporting_period (
    organisation_id,outlet_id,period_start,period_end,label
  )
  select o.organisation_id,o.id,'2026-07-15','2026-08-15','Overlap'
  from outlet o where o.code='A1'
$q$, 'overlapping reporting periods are rejected');

insert into restaurant_context (
  organisation_id,outlet_id,version_no,effective_from,created_by
)
select o.organisation_id,o.id,1,'2026-07-01',
       '10000000-0000-0000-0000-000000000001'
from outlet o where o.code='A1';

insert into materiality_setting (
  organisation_id,outlet_id,scope_type,absolute_threshold,percent_threshold,
  source_kind,effective_from,approved_by,approved_at
)
select o.organisation_id,o.id,'general',1000,0.10,
       'user_confirmed','2026-07-01',
       '10000000-0000-0000-0000-000000000001',now()
from outlet o where o.code='A1';

-- Immutability must hold even for the table owner/service path. Test it outside
-- client RLS; an UPDATE filtered to zero rows would be a false-positive test.
reset role;

select test_assert_rejects($q$
  update restaurant_context set service_style='changed'
$q$, 'restaurant context is immutable even for owner/service path');

select test_assert_rejects($q$
  update materiality_setting set absolute_threshold=500
$q$, 'approved materiality is immutable even for owner/service path');

set role restaurant_app;
select set_config('app.user_id','10000000-0000-0000-0000-000000000001',true);

select test_assert_eq(
  (select count(*) from audit_log where action_code='SETUP_BOOTSTRAP'),1,
  'Org A admin sees only its own bootstrap audit row'
);

reset role;
rollback;
