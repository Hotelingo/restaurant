\set ON_ERROR_STOP on

begin;

create or replace function test_assert_eq3(actual bigint, expected bigint, label text)
returns void language plpgsql as $$
begin
  if actual <> expected then
    raise exception 'FAIL % -- expected %, got %', label, expected, actual;
  end if;
  raise notice 'PASS  %', label;
end $$;

create or replace function test_assert_rejects3(stmt text, label text)
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
  ('30000000-0000-0000-0000-000000000001'),
  ('30000000-0000-0000-0000-000000000002');

set role restaurant_app;
select set_config('app.user_id','30000000-0000-0000-0000-000000000001',true);

select * from bootstrap_organisation(
  'Controls Org'::text,'controls-org'::text,'Controls One'::text,'C1'::text,
  'USD'::char(3),'UTC'::text,1::smallint,'controls-bootstrap'::text,'ci-controls'
);

select * from create_outlet(
  (select id from organisation where slug='controls-org'),
  'Controls Two','C2','USD'::char(3),'UTC',1::smallint,
  'controls-outlet-0001','ci-controls'
);

select * from create_outlet(
  (select id from organisation where slug='controls-org'),
  'Controls Two','C2','USD'::char(3),'UTC',1::smallint,
  'controls-outlet-0001','ci-controls-retry'
);

select test_assert_eq3(
  (select count(*) from outlet where organisation_id=(select id from organisation where slug='controls-org')),
  2,
  'additional outlet retry is idempotent'
);

select * from put_outlet_setting(
  (select id from outlet where code='C1'),
  'primary_comparator','"budget"'::jsonb,
  'controls-setting-0001','ci-controls'
);

select * from put_outlet_setting(
  (select id from outlet where code='C1'),
  'primary_comparator','"budget"'::jsonb,
  'controls-setting-0001','ci-controls-retry'
);

select test_assert_eq3(
  (select count(*) from setting where outlet_id=(select id from outlet where code='C1') and key='primary_comparator'),
  1,
  'setting retry is idempotent'
);

select test_assert_rejects3($q$
  select * from put_outlet_setting(
    (select id from outlet where code='C1'),
    'arbitrary_customer_code','true'::jsonb,
    'controls-bad-setting','ci-controls'
  )
$q$, 'unsupported setting key is rejected');

select * from create_materiality_version(
  (select id from outlet where code='C1'),
  'general'::materiality_scope,
  1000,0.10,
  '{"basis":"explicit confirmation"}'::jsonb,
  '{"consecutive_periods":2}'::jsonb,
  true,'2026-09-01',
  'controls-materiality-0001','ci-controls'
);

select * from create_materiality_version(
  (select id from outlet where code='C1'),
  'general'::materiality_scope,
  1500,0.10,
  '{"basis":"reconfirmed"}'::jsonb,
  '{"consecutive_periods":2}'::jsonb,
  true,'2026-10-01',
  'controls-materiality-0002','ci-controls'
);

select test_assert_eq3(
  (select count(*) from materiality_setting where outlet_id=(select id from outlet where code='C1') and scope_type='general'),
  2,
  'materiality creates immutable versions'
);

select test_assert_eq3(
  (select count(*) from materiality_setting where outlet_id=(select id from outlet where code='C1') and scope_type='general' and effective_to is null),
  1,
  'exactly one current materiality version remains'
);

reset role;
select test_assert_rejects3($q$
  update materiality_setting
  set absolute_threshold=999
  where outlet_id=(select id from outlet where code='C1')
    and scope_type='general'
    and effective_to is not null
$q$, 'approved historical materiality values cannot be edited');

set role restaurant_app;
select set_config('app.user_id','30000000-0000-0000-0000-000000000001',true);

insert into membership (
  organisation_id,user_id,role,outlet_scope_mode
)
select id,'30000000-0000-0000-0000-000000000002','admin','selected_outlets'
from organisation where slug='controls-org';

insert into membership_outlet (membership_id,organisation_id,outlet_id)
select m.id,m.organisation_id,o.id
from membership m
join organisation org on org.id=m.organisation_id and org.slug='controls-org'
join outlet o on o.organisation_id=org.id and o.code='C1'
where m.user_id='30000000-0000-0000-0000-000000000002'
  and m.role='admin';

select set_config('app.user_id','30000000-0000-0000-0000-000000000002',true);

select test_assert_rejects3($q$
  select * from create_outlet(
    (select organisation_id from membership where user_id='30000000-0000-0000-0000-000000000002' limit 1),
    'Controls Three','C3','USD'::char(3),'UTC',1::smallint,
    'controls-outlet-0002','ci-controls'
  )
$q$, 'selected-outlet admin cannot create organisation-wide outlets');

select test_assert_eq3(
  (select count(*) from outlet),
  1,
  'selected-outlet admin sees only assigned outlet through RLS'
);

reset role;
rollback;
