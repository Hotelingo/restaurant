\set ON_ERROR_STOP on

begin;

create or replace function test_assert_eq9(actual bigint, expected bigint, label text)
returns void language plpgsql as $$
begin
  if actual <> expected then
    raise exception 'FAIL % -- expected %, got %', label, expected, actual;
  end if;
  raise notice 'PASS  %', label;
end $$;

create or replace function test_assert_rejects9(stmt text, label text)
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

insert into neon_auth."user" (id,name,email,"emailVerified") values
  ('90000000-0000-0000-0000-000000000001','Fact Admin','facts@example.com',false);

set role restaurant_app;
select set_config('app.user_id','90000000-0000-0000-0000-000000000001',true);

select * from bootstrap_organisation(
  'Fact Org','fact-org','Fact Outlet','FACT',
  'USD'::char(3),'UTC',1::smallint,'fact-bootstrap','fact-test'
);

insert into reporting_period(
  organisation_id,outlet_id,period_start,period_end,label
)
select organisation_id,id,'2026-07-01','2026-07-31','July 2026'
from outlet where code='FACT';

insert into source_profile(
  organisation_id,outlet_id,template_code,source_label
)
select organisation_id,id,'T1','Fact P&L'
from outlet where code='FACT';

insert into profile_version(
  organisation_id,outlet_id,source_profile_id,version_no,
  layout_json,fingerprint_hash,fingerprint_components_json,transform_config_json
)
select sp.organisation_id,sp.outlet_id,sp.id,1,
       '{}'::jsonb,repeat('a',64),'{}'::jsonb,'[]'::jsonb
from source_profile sp where sp.source_label='Fact P&L';

update profile_version
set status='approved',
    approved_by='90000000-0000-0000-0000-000000000001',
    approved_at=now()
where version_no=1;

update source_profile sp
set active_profile_version_id=pv.id
from profile_version pv
where pv.source_profile_id=sp.id and pv.version_no=1;

insert into source_file(
  id,organisation_id,outlet_id,template_code,
  storage_bucket,storage_path,original_filename,sha256,
  content_type,size_bytes,uploaded_by,
  detected_file_type,row_count,malware_scan_status,
  malware_scanner,malware_scanned_at,inspection_json
)
select
  '90000000-0000-0000-0000-000000000101',
  o.organisation_id,o.id,'T1','uploads',
  'org/'||o.organisation_id::text||'/outlet/'||o.id::text||
    '/source/90000000-0000-0000-0000-000000000101/pnl.csv',
  'pnl.csv',repeat('1',64),'text/csv',1000,
  '90000000-0000-0000-0000-000000000001',
  'csv',2,'clean','clamav',now(),'{}'::jsonb
from outlet o where o.code='FACT';

insert into import_batch(
  id,organisation_id,outlet_id,source_file_id,template_code,
  profile_version_id,period_id,scenario,status,detected_fingerprint
)
select
  '90000000-0000-0000-0000-000000000201',
  sf.organisation_id,sf.outlet_id,sf.id,sf.template_code,
  pv.id,rp.id,'actual','ready',repeat('a',64)
from source_file sf
join profile_version pv
  on pv.organisation_id=sf.organisation_id and pv.outlet_id=sf.outlet_id
join reporting_period rp
  on rp.organisation_id=sf.organisation_id and rp.outlet_id=sf.outlet_id
where sf.id='90000000-0000-0000-0000-000000000101';

insert into staging_row(
  id,organisation_id,outlet_id,batch_id,source_row_no,
  raw_jsonb,parsed_jsonb,row_status
)
select
  '90000000-0000-0000-0000-000000000301',
  b.organisation_id,b.outlet_id,b.id,2,
  '{"Account_Code":"4000","Account_Name":"Food sales","July_2026":"100"}'::jsonb,
  '{"account_code":"4000","account_name":"Food sales","period":"2026-07","amount":"100"}'::jsonb,
  'parsed'
from import_batch b where b.id='90000000-0000-0000-0000-000000000201';

-- Canonical tables are read-only to the normal application role.
select test_assert_rejects9($q$
  insert into account(organisation_id,outlet_id,account_code,account_name)
  select organisation_id,id,'4000','Food sales'
  from outlet where code='FACT'
$q$, 'restaurant_app cannot directly insert canonical accounts');

reset role;

insert into account(
  id,organisation_id,outlet_id,account_code,account_name
)
select
  '90000000-0000-0000-0000-000000000401',
  organisation_id,id,'4000','Food sales'
from outlet where code='FACT';

insert into financial_fact(
  organisation_id,outlet_id,period_id,scenario,
  account_id,ladder_line_id,amount,currency_code,
  batch_id,profile_version_id,staging_row_id
)
select
  b.organisation_id,b.outlet_id,b.period_id,b.scenario,
  a.id,ll.id,100,'USD',
  b.id,b.profile_version_id,s.id
from import_batch b
join account a
  on a.organisation_id=b.organisation_id and a.outlet_id=b.outlet_id
join staging_row s
  on s.organisation_id=b.organisation_id
 and s.outlet_id=b.outlet_id
 and s.batch_id=b.id
join ladder_line ll on ll.code='NET_SALES'
where b.id='90000000-0000-0000-0000-000000000201';

select test_assert_rejects9($q$
  insert into financial_fact(
    organisation_id,outlet_id,period_id,scenario,
    account_id,ladder_line_id,amount,currency_code,
    batch_id,profile_version_id,staging_row_id
  )
  select
    b.organisation_id,b.outlet_id,b.period_id,b.scenario,
    null,ll.id,100,'USD',
    b.id,b.profile_version_id,s.id
  from import_batch b
  join staging_row s on s.batch_id=b.id
  join ladder_line ll on ll.code='NET_SALES'
  where b.id='90000000-0000-0000-0000-000000000201'
$q$, 'actual financial fact requires account_id');

select test_assert_rejects9($q$
  insert into financial_fact(
    organisation_id,outlet_id,period_id,scenario,
    account_id,ladder_line_id,amount,currency_code,
    batch_id,profile_version_id,staging_row_id
  )
  select
    b.organisation_id,b.outlet_id,b.period_id,b.scenario,
    a.id,ll.id,999,'USD',
    b.id,b.profile_version_id,s.id
  from import_batch b
  join account a on a.outlet_id=b.outlet_id
  join staging_row s on s.batch_id=b.id
  join ladder_line ll on ll.code='PRODUCT_COST'
  where b.id='90000000-0000-0000-0000-000000000201'
$q$, 'one account-grain canonical row per account/batch');

select test_assert_rejects9($q$
  update financial_fact set amount=999
$q$, 'canonical facts are immutable even for owner/service path');

-- Create a T6 ladder-grain budget batch without a synthetic account.
set role restaurant_app;
select set_config('app.user_id','90000000-0000-0000-0000-000000000001',true);

insert into source_profile(
  organisation_id,outlet_id,template_code,source_label
)
select organisation_id,id,'T6','Fact Budget'
from outlet where code='FACT';

insert into profile_version(
  organisation_id,outlet_id,source_profile_id,version_no,
  layout_json,fingerprint_hash,fingerprint_components_json,transform_config_json
)
select sp.organisation_id,sp.outlet_id,sp.id,1,
       '{}'::jsonb,repeat('b',64),'{}'::jsonb,'[]'::jsonb
from source_profile sp where sp.source_label='Fact Budget';

update profile_version
set status='approved',
    approved_by='90000000-0000-0000-0000-000000000001',
    approved_at=now()
where fingerprint_hash=repeat('b',64);

update source_profile sp
set active_profile_version_id=pv.id
from profile_version pv
where pv.source_profile_id=sp.id and pv.fingerprint_hash=repeat('b',64);

insert into source_file(
  id,organisation_id,outlet_id,template_code,
  storage_bucket,storage_path,original_filename,sha256,
  content_type,size_bytes,uploaded_by,
  detected_file_type,row_count,malware_scan_status,
  malware_scanner,malware_scanned_at,inspection_json
)
select
  '90000000-0000-0000-0000-000000000102',
  o.organisation_id,o.id,'T6','uploads',
  'org/'||o.organisation_id::text||'/outlet/'||o.id::text||
    '/source/90000000-0000-0000-0000-000000000102/budget.csv',
  'budget.csv',repeat('2',64),'text/csv',500,
  '90000000-0000-0000-0000-000000000001',
  'csv',2,'clean','clamav',now(),'{}'::jsonb
from outlet o where o.code='FACT';

insert into import_batch(
  id,organisation_id,outlet_id,source_file_id,template_code,
  profile_version_id,period_id,scenario,status,detected_fingerprint
)
select
  '90000000-0000-0000-0000-000000000202',
  sf.organisation_id,sf.outlet_id,sf.id,sf.template_code,
  pv.id,rp.id,'budget','ready',repeat('b',64)
from source_file sf
join profile_version pv
  on pv.organisation_id=sf.organisation_id
 and pv.outlet_id=sf.outlet_id
 and pv.fingerprint_hash=repeat('b',64)
join reporting_period rp
  on rp.organisation_id=sf.organisation_id and rp.outlet_id=sf.outlet_id
where sf.id='90000000-0000-0000-0000-000000000102';

insert into staging_row(
  id,organisation_id,outlet_id,batch_id,source_row_no,
  raw_jsonb,parsed_jsonb,row_status
)
select
  '90000000-0000-0000-0000-000000000302',
  b.organisation_id,b.outlet_id,b.id,2,
  '{"Management_Line":"Net Sales","Budget_July_2026":"232000"}'::jsonb,
  '{"management_line":"Net Sales","period":"2026-07","amount":"232000"}'::jsonb,
  'parsed'
from import_batch b where b.id='90000000-0000-0000-0000-000000000202';

reset role;

insert into financial_fact(
  organisation_id,outlet_id,period_id,scenario,
  account_id,ladder_line_id,amount,currency_code,
  batch_id,profile_version_id,staging_row_id
)
select
  b.organisation_id,b.outlet_id,b.period_id,b.scenario,
  null,ll.id,232000,'USD',
  b.id,b.profile_version_id,s.id
from import_batch b
join staging_row s on s.batch_id=b.id
join ladder_line ll on ll.code='NET_SALES'
where b.id='90000000-0000-0000-0000-000000000202';

select test_assert_eq9(
  (select count(*) from financial_fact where account_id is null and scenario='budget'),
  1,
  'budget comparator persists directly at ladder grain without synthetic account');

select test_assert_rejects9($q$
  insert into financial_fact(
    organisation_id,outlet_id,period_id,scenario,
    account_id,ladder_line_id,amount,currency_code,
    batch_id,profile_version_id,staging_row_id
  )
  select
    b.organisation_id,b.outlet_id,b.period_id,b.scenario,
    null,ll.id,1,'USD',
    b.id,b.profile_version_id,s.id
  from import_batch b
  join staging_row s on s.batch_id=b.id
  join ladder_line ll on ll.code='NET_SALES'
  where b.id='90000000-0000-0000-0000-000000000202'
$q$, 'ladder-grain comparator is unique by batch and ladder line');

rollback;
