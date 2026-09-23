\set ON_ERROR_STOP on
begin;

create or replace function test_assert_eq13(actual bigint, expected bigint, label text)
returns void language plpgsql as $$
begin
  if actual <> expected then
    raise exception 'FAIL % -- expected %, got %', label, expected, actual;
  end if;
  raise notice 'PASS %', label;
end $$;

create or replace function test_assert_text13(actual text, expected text, label text)
returns void language plpgsql as $$
begin
  if actual is distinct from expected then
    raise exception 'FAIL % -- expected %, got %', label, expected, actual;
  end if;
  raise notice 'PASS %', label;
end $$;

create or replace function test_assert_rejects13(stmt text, label text)
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
  ('d0000000-0000-0000-0000-000000000001','Calc Admin','calc-admin@example.com',false),
  ('d0000000-0000-0000-0000-000000000002','Other Admin','other-admin@example.com',false);

set role restaurant_app;
select set_config('app.user_id','d0000000-0000-0000-0000-000000000001',true);

select * from bootstrap_organisation(
  'Calc Org','calc-org','Calc Outlet','CALC',
  'USD'::char(3),'UTC',1::smallint,'calc-bootstrap-0001','calc-test'
);

insert into reporting_period(
  organisation_id,outlet_id,period_start,period_end,label
)
select organisation_id,id,'2026-07-01','2026-07-31','July 2026'
from outlet where code='CALC';

reset role;

-- Build one genuine committed canonical batch for the run-input invariant.
insert into source_profile(organisation_id,outlet_id,template_code,source_label)
select organisation_id,id,'T1','Calc P&L'
from outlet where code='CALC';

insert into profile_version(
  organisation_id,outlet_id,source_profile_id,version_no,
  layout_json,fingerprint_hash,fingerprint_components_json,
  transform_config_json,status,approved_by,approved_at
)
select
  organisation_id,outlet_id,id,1,'{}',repeat('d',64),'{}','[]',
  'approved','d0000000-0000-0000-0000-000000000001',now()
from source_profile where source_label='Calc P&L';

update source_profile sp
set active_profile_version_id=pv.id
from profile_version pv
where pv.source_profile_id=sp.id
  and sp.source_label='Calc P&L';

insert into source_file(
  id,organisation_id,outlet_id,template_code,
  storage_bucket,storage_path,original_filename,sha256,
  content_type,size_bytes,uploaded_by,
  detected_file_type,row_count,malware_scan_status,
  malware_scanner,malware_scanned_at,inspection_json
)
select
  'd0000000-0000-0000-0000-000000000101',
  o.organisation_id,o.id,'T1','uploads',
  'org/'||o.organisation_id::text||'/outlet/'||o.id::text||
    '/source/d0000000-0000-0000-0000-000000000101/pnl.csv',
  'pnl.csv',repeat('4',64),'text/csv',100,
  'd0000000-0000-0000-0000-000000000001',
  'csv',2,'clean','clamav',now(),'{}'
from outlet o where o.code='CALC';

insert into import_batch(
  id,organisation_id,outlet_id,source_file_id,template_code,
  profile_version_id,period_id,scenario,status,detected_fingerprint
)
select
  'd0000000-0000-0000-0000-000000000201',
  sf.organisation_id,sf.outlet_id,sf.id,'T1',
  pv.id,rp.id,'actual','uploaded',repeat('d',64)
from source_file sf
join source_profile sp
  on sp.organisation_id=sf.organisation_id
 and sp.outlet_id=sf.outlet_id
 and sp.source_label='Calc P&L'
join profile_version pv on pv.id=sp.active_profile_version_id
join reporting_period rp
  on rp.organisation_id=sf.organisation_id and rp.outlet_id=sf.outlet_id
where sf.id='d0000000-0000-0000-0000-000000000101';

insert into staging_row(
  organisation_id,outlet_id,batch_id,source_row_no,
  raw_jsonb,parsed_jsonb,row_status
)
select
  b.organisation_id,b.outlet_id,b.id,2,'{}',
  '{"period":"2026-07","account_code":"4000","account_name":"Food sales","amount":"228500"}',
  'parsed'
from import_batch b
where b.id='d0000000-0000-0000-0000-000000000201';

insert into account(
  id,organisation_id,outlet_id,account_code,account_name
)
select
  'd0000000-0000-0000-0000-000000000301',
  organisation_id,id,'4000','Food sales'
from outlet where code='CALC';

insert into financial_fact(
  organisation_id,outlet_id,period_id,scenario,
  account_id,ladder_line_id,amount,currency_code,
  batch_id,profile_version_id,staging_row_id
)
select
  b.organisation_id,b.outlet_id,b.period_id,b.scenario,
  a.id,ll.id,228500,'USD',b.id,b.profile_version_id,s.id
from import_batch b
join account a
  on a.organisation_id=b.organisation_id and a.outlet_id=b.outlet_id
join ladder_line ll on ll.code='NET_SALES'
join staging_row s on s.batch_id=b.id
where b.id='d0000000-0000-0000-0000-000000000201';

update import_batch
set status='committed',
    committed_by='d0000000-0000-0000-0000-000000000001',
    committed_at=now(),
    canonical_commit_hash=repeat('5',64),
    canonical_commit_summary='{"fact_count":1}'
where id='d0000000-0000-0000-0000-000000000201';

-- A second batch exists in the same context but is not committed.
insert into source_file(
  id,organisation_id,outlet_id,template_code,
  storage_bucket,storage_path,original_filename,sha256,
  content_type,size_bytes,uploaded_by,
  detected_file_type,row_count,malware_scan_status,
  malware_scanner,malware_scanned_at,inspection_json
)
select
  'd0000000-0000-0000-0000-000000000102',
  o.organisation_id,o.id,'T1','uploads',
  'org/'||o.organisation_id::text||'/outlet/'||o.id::text||
    '/source/d0000000-0000-0000-0000-000000000102/uncommitted.csv',
  'uncommitted.csv',repeat('6',64),'text/csv',50,
  'd0000000-0000-0000-0000-000000000001',
  'csv',1,'clean','clamav',now(),'{}'
from outlet o where o.code='CALC';

insert into import_batch(
  id,organisation_id,outlet_id,source_file_id,template_code,
  profile_version_id,period_id,scenario,status,detected_fingerprint
)
select
  'd0000000-0000-0000-0000-000000000202',
  sf.organisation_id,sf.outlet_id,sf.id,'T1',
  pv.id,rp.id,'actual','uploaded',repeat('e',64)
from source_file sf
join source_profile sp
  on sp.organisation_id=sf.organisation_id
 and sp.outlet_id=sf.outlet_id
 and sp.source_label='Calc P&L'
join profile_version pv on pv.id=sp.active_profile_version_id
join reporting_period rp
  on rp.organisation_id=sf.organisation_id and rp.outlet_id=sf.outlet_id
where sf.id='d0000000-0000-0000-0000-000000000102';

-- Create the immutable run snapshot and prove its input gate.
insert into calc_run(
  id,organisation_id,outlet_id,period_id,
  engine_version,settings_snapshot,comparator_scenario,status
)
select
  'd0000000-0000-0000-0000-000000000401',
  o.organisation_id,o.id,rp.id,
  'pl-v1',
  '{"primary_comparator":"budget","materiality":{"absolute":"1000","percent":"0.10"}}',
  'budget','queued'
from outlet o
join reporting_period rp
  on rp.organisation_id=o.organisation_id and rp.outlet_id=o.id
where o.code='CALC';

insert into calc_run_input(
  organisation_id,outlet_id,run_id,batch_id,
  profile_version_id,input_role,scenario,canonical_commit_hash
)
select
  b.organisation_id,b.outlet_id,
  'd0000000-0000-0000-0000-000000000401',
  b.id,b.profile_version_id,'actual',b.scenario,b.canonical_commit_hash
from import_batch b
where b.id='d0000000-0000-0000-0000-000000000201';

select test_assert_eq13(
  (select count(*) from calc_run_input
   where run_id='d0000000-0000-0000-0000-000000000401'),
  1,
  'committed canonical batch can feed a calc run'
);

select test_assert_rejects13($q$
  insert into calc_run_input(
    organisation_id,outlet_id,run_id,batch_id,
    profile_version_id,input_role,scenario,canonical_commit_hash
  )
  select
    b.organisation_id,b.outlet_id,
    'd0000000-0000-0000-0000-000000000401',
    b.id,b.profile_version_id,'actual',b.scenario,repeat('6',64)
  from import_batch b
  where b.id='d0000000-0000-0000-0000-000000000202'
$q$, 'uncommitted batch cannot feed a calc run');

update calc_run
set status='running',started_at=now()
where id='d0000000-0000-0000-0000-000000000401';

insert into calc_result(
  id,organisation_id,outlet_id,run_id,
  calc_id,grain_type,grain_key,value_numeric,unit,currency_code,
  calculation_status,evidence_status,result_metadata
)
select
  'd0000000-0000-0000-0000-000000000501',
  organisation_id,id,'d0000000-0000-0000-0000-000000000401',
  'PL.NET_SALES','management_pl',
  '{"scenario":"actual","ladder_code":"NET_SALES"}',
  228500,'currency','USD','CALCULATED','supported','{}'
from outlet where code='CALC';

insert into calc_result(
  id,organisation_id,outlet_id,run_id,
  calc_id,grain_type,grain_key,value_numeric,unit,currency_code,
  calculation_status,evidence_status,result_metadata
)
select
  'd0000000-0000-0000-0000-000000000502',
  organisation_id,id,'d0000000-0000-0000-0000-000000000401',
  'PL.PRODUCT_COST','management_pl',
  '{"scenario":"actual","ladder_code":"PRODUCT_COST"}',
  70282,'currency','USD','CALCULATED','supported','{}'
from outlet where code='CALC';

insert into calc_result(
  id,organisation_id,outlet_id,run_id,
  calc_id,grain_type,grain_key,value_numeric,unit,currency_code,
  calculation_status,evidence_status,result_metadata
)
select
  'd0000000-0000-0000-0000-000000000503',
  organisation_id,id,'d0000000-0000-0000-0000-000000000401',
  'PL.PRODUCT_MARGIN','management_pl',
  '{"scenario":"actual","ladder_code":"PRODUCT_MARGIN"}',
  158218,'currency','USD','CALCULATED','supported','{}'
from outlet where code='CALC';

insert into calc_dependency(
  organisation_id,outlet_id,run_id,parent_result_id,child_result_id,dependency_role
)
select organisation_id,id,'d0000000-0000-0000-0000-000000000401',
  'd0000000-0000-0000-0000-000000000503',
  'd0000000-0000-0000-0000-000000000501',
  'formula_input'
from outlet where code='CALC';

insert into calc_dependency(
  organisation_id,outlet_id,run_id,parent_result_id,child_result_id,dependency_role
)
select organisation_id,id,'d0000000-0000-0000-0000-000000000401',
  'd0000000-0000-0000-0000-000000000503',
  'd0000000-0000-0000-0000-000000000502',
  'formula_input'
from outlet where code='CALC';

select test_assert_eq13(
  (select count(*) from calc_dependency
   where run_id='d0000000-0000-0000-0000-000000000401'),
  2,
  'derived calc result records deterministic dependency lineage'
);

select test_assert_rejects13($q$
  insert into calc_result(
    organisation_id,outlet_id,run_id,
    calc_id,grain_type,grain_key,value_numeric,unit,currency_code,
    calculation_status,evidence_status,result_metadata
  )
  select
    organisation_id,id,'d0000000-0000-0000-0000-000000000401',
    'PL.NET_SALES','management_pl',
    '{"scenario":"actual","ladder_code":"NET_SALES"}',
    999,'currency','USD','CALCULATED','supported','{}'
  from outlet where code='CALC'
$q$, 'calc result uniqueness blocks duplicate run/calc/grain');

select test_assert_rejects13($q$
  insert into calc_result(
    organisation_id,outlet_id,run_id,
    calc_id,grain_type,grain_key,value_numeric,unit,currency_code,
    calculation_status,evidence_status,explanation_code,result_metadata
  )
  select
    organisation_id,id,'d0000000-0000-0000-0000-000000000401',
    'PL.VAR.OPERATING_PROFIT','management_pl_variance',
    '{"ladder_code":"OPERATING_PROFIT"}',
    0,'currency','USD','NOT_CALCULATED','evidence_required',
    'COMPARATOR_NOT_COMMITTED','{}'
  from outlet where code='CALC'
$q$, 'NOT_CALCULATED cannot masquerade as numeric zero');

-- restaurant_app has read-only access to calculation persistence.
set role restaurant_app;
select set_config('app.user_id','d0000000-0000-0000-0000-000000000001',true);

select test_assert_eq13(
  (select count(*) from calc_result
   where run_id='d0000000-0000-0000-0000-000000000401'),
  3,
  'tenant user can read its calculation results'
);

select test_assert_rejects13($q$
  insert into calc_result(
    organisation_id,outlet_id,run_id,
    calc_id,grain_type,grain_key,value_numeric,unit,currency_code,
    calculation_status,evidence_status,result_metadata
  )
  select
    organisation_id,id,'d0000000-0000-0000-0000-000000000401',
    'PL.OWNER_RESULT','management_pl',
    '{"scenario":"actual","ladder_code":"OWNER_RESULT"}',
    1,'currency','USD','CALCULATED','supported','{}'
  from outlet where code='CALC'
$q$, 'application role cannot write calc results directly');

reset role;

update calc_run
set status='completed',completed_at=now(),result_hash=repeat('9',64)
where id='d0000000-0000-0000-0000-000000000401';

select test_assert_text13(
  (select status from calc_run
   where id='d0000000-0000-0000-0000-000000000401'),
  'completed',
  'running calc run can transition to completed with result hash'
);

select test_assert_rejects13($q$
  update calc_result
  set value_numeric=1
  where id='d0000000-0000-0000-0000-000000000501'
$q$, 'calc results are immutable');

select test_assert_rejects13($q$
  insert into calc_result(
    organisation_id,outlet_id,run_id,
    calc_id,grain_type,grain_key,value_numeric,unit,currency_code,
    calculation_status,evidence_status,result_metadata
  )
  select
    organisation_id,id,'d0000000-0000-0000-0000-000000000401',
    'PL.OWNER_RESULT','management_pl',
    '{"scenario":"actual","ladder_code":"OWNER_RESULT"}',
    1,'currency','USD','CALCULATED','supported','{}'
  from outlet where code='CALC'
$q$, 'completed run rejects late result insertion');

select test_assert_rejects13($q$
  update calc_run
  set settings_snapshot='{"tampered":true}'
  where id='d0000000-0000-0000-0000-000000000401'
$q$, 'completed run snapshot is immutable');

select test_assert_rejects13($q$
  delete from calc_run
  where id='d0000000-0000-0000-0000-000000000401'
$q$, 'calc run history cannot be deleted');

select test_assert_eq13(
  (select count(*) from calc_definition
   where definition_version='v1' and module='PL'),
  22,
  'PL v1 calculation registry seeds eleven ladder and eleven variance definitions'
);

-- RLS proof from a second tenant.
set role restaurant_app;
select set_config('app.user_id','d0000000-0000-0000-0000-000000000002',true);

select * from bootstrap_organisation(
  'Other Calc Org','other-calc-org','Other Outlet','OTHER',
  'USD'::char(3),'UTC',1::smallint,'other-calc-bootstrap','calc-rls-test'
);

insert into reporting_period(
  organisation_id,outlet_id,period_start,period_end,label
)
select organisation_id,id,'2026-07-01','2026-07-31','July 2026'
from outlet where code='OTHER';

reset role;

insert into calc_run(
  id,organisation_id,outlet_id,period_id,
  engine_version,settings_snapshot,status
)
select
  'd0000000-0000-0000-0000-000000000402',
  o.organisation_id,o.id,rp.id,'pl-v1','{}','queued'
from outlet o
join reporting_period rp
  on rp.organisation_id=o.organisation_id and rp.outlet_id=o.id
where o.code='OTHER';

set role restaurant_app;
select set_config('app.user_id','d0000000-0000-0000-0000-000000000001',true);

select test_assert_eq13(
  (select count(*) from calc_run
   where id='d0000000-0000-0000-0000-000000000402'),
  0,
  'tenant A cannot read tenant B calculation runs'
);

rollback;
