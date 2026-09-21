\set ON_ERROR_STOP on

begin;

create or replace function test_assert_eq7(actual bigint, expected bigint, label text)
returns void language plpgsql as $$
begin
  if actual <> expected then
    raise exception 'FAIL % -- expected %, got %', label, expected, actual;
  end if;
  raise notice 'PASS  %', label;
end $$;

create or replace function test_assert_bool7(actual boolean, expected boolean, label text)
returns void language plpgsql as $$
begin
  if actual is distinct from expected then
    raise exception 'FAIL % -- expected %, got %', label, expected, actual;
  end if;
  raise notice 'PASS  %', label;
end $$;

create or replace function test_assert_rejects7(stmt text, label text)
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
  ('70000000-0000-0000-0000-000000000001','Ingestion Admin','ingestion@example.com',false);

insert into ladder_framework(code,name) values ('RPR-INGEST-TEST','Ingestion test framework');
insert into ladder_line(framework_id,code,name,kind,display_order,is_calculated)
select id,'INGEST.TEST.NET_SALES','Net Sales','revenue',1,false
from ladder_framework where code='RPR-INGEST-TEST';

set role restaurant_app;
select set_config('app.user_id','70000000-0000-0000-0000-000000000001',true);

select * from bootstrap_organisation(
  'Ingestion Org','ingestion-org','Ingestion Outlet','ING',
  'USD'::char(3),'UTC',1::smallint,'ingestion-bootstrap','ingestion-test'
);

insert into reporting_period(
  organisation_id,outlet_id,period_start,period_end,label
)
select organisation_id,id,'2026-07-01','2026-07-31','July 2026'
from outlet where code='ING';

insert into source_profile(
  organisation_id,outlet_id,template_code,source_label
)
select organisation_id,id,'T1','Ingestion P&L'
from outlet where code='ING';

insert into profile_version(
  organisation_id,outlet_id,source_profile_id,version_no,
  layout_json,fingerprint_hash,fingerprint_components_json,transform_config_json
)
select sp.organisation_id,sp.outlet_id,sp.id,1,
       '{}'::jsonb,repeat('a',64),'{}'::jsonb,'[]'::jsonb
from source_profile sp where sp.source_label='Ingestion P&L';

update profile_version
set status='approved',
    approved_by='70000000-0000-0000-0000-000000000001',
    approved_at=now()
where version_no=1;

update source_profile sp
set active_profile_version_id=pv.id
from profile_version pv
where pv.source_profile_id=sp.id and pv.version_no=1;

insert into source_file(
  id,organisation_id,outlet_id,template_code,
  storage_bucket,storage_path,original_filename,sha256,
  content_type,size_bytes,uploaded_by
)
select
  '70000000-0000-0000-0000-000000000101',
  o.organisation_id,o.id,'T1',
  'source',
  'org/'||o.organisation_id::text||'/outlet/'||o.id::text||
    '/source/70000000-0000-0000-0000-000000000101/pnl.csv',
  'pnl.csv',repeat('1',64),'text/csv',830,
  '70000000-0000-0000-0000-000000000001'
from outlet o where o.code='ING';

select test_assert_rejects7($q$
  insert into source_file(
    id,organisation_id,outlet_id,template_code,
    storage_bucket,storage_path,original_filename,sha256,
    content_type,size_bytes,uploaded_by
  )
  select
    '70000000-0000-0000-0000-000000000199',
    o.organisation_id,o.id,'T1','source','wrong/path.csv',
    'bad.csv',repeat('9',64),'text/csv',10,
    '70000000-0000-0000-0000-000000000001'
  from outlet o where o.code='ING'
$q$, 'source storage path must match tenant/file identity');

insert into import_batch(
  id,organisation_id,outlet_id,source_file_id,template_code,
  profile_version_id,period_id,scenario,status,detected_fingerprint
)
select
  '70000000-0000-0000-0000-000000000201',
  sf.organisation_id,sf.outlet_id,sf.id,sf.template_code,
  pv.id,rp.id,'actual','ready',repeat('a',64)
from source_file sf
join profile_version pv
  on pv.organisation_id=sf.organisation_id and pv.outlet_id=sf.outlet_id
join reporting_period rp
  on rp.organisation_id=sf.organisation_id and rp.outlet_id=sf.outlet_id
where sf.id='70000000-0000-0000-0000-000000000101'
  and pv.version_no=1;

insert into staging_row(
  id,organisation_id,outlet_id,batch_id,source_row_no,
  raw_jsonb,parsed_jsonb,row_status
)
select
  '70000000-0000-0000-0000-000000000301',
  b.organisation_id,b.outlet_id,b.id,1,
  '{"Account_Code":"4000","July_2026":"191100"}'::jsonb,
  '{"account_code":"4000","period":"2026-07","amount":"191100"}'::jsonb,
  'parsed'
from import_batch b where b.id='70000000-0000-0000-0000-000000000201';

insert into validation_result(
  organisation_id,outlet_id,batch_id,staging_row_id,
  rule_code,severity,object_scope,field_name,
  actual_json,expected_json,tolerance_json,message,remediation
)
select
  b.organisation_id,b.outlet_id,b.id,s.id,
  'TEST_BLOCK','block','row:1','amount',
  '191100'::jsonb,'191100'::jsonb,'0.005'::jsonb,
  'Test blocking validation','Resolve test validation'
from import_batch b
join staging_row s on s.batch_id=b.id
where b.id='70000000-0000-0000-0000-000000000201';

select test_assert_bool7(
  batch_has_unresolved_blocks('70000000-0000-0000-0000-000000000201'),
  true,
  'unresolved block is visible to commit gate'
);

update validation_result
set resolved=true,
    resolution_note='Confirmed source and mapping',
    resolved_by='70000000-0000-0000-0000-000000000001',
    resolved_at=now()
where batch_id='70000000-0000-0000-0000-000000000201';

select test_assert_bool7(
  batch_has_unresolved_blocks('70000000-0000-0000-0000-000000000201'),
  false,
  'resolved block no longer blocks commit gate'
);

update import_batch
set status='committed',
    committed_by='70000000-0000-0000-0000-000000000001',
    committed_at=now(),
    canonical_commit_hash=repeat('c',64),
    canonical_commit_summary='{"fact_count":15,"amount_total":"228500"}'::jsonb
where id='70000000-0000-0000-0000-000000000201';

insert into source_file(
  id,organisation_id,outlet_id,template_code,
  storage_bucket,storage_path,original_filename,sha256,
  content_type,size_bytes,uploaded_by
)
select
  '70000000-0000-0000-0000-000000000102',
  o.organisation_id,o.id,'T1',
  'source',
  'org/'||o.organisation_id::text||'/outlet/'||o.id::text||
    '/source/70000000-0000-0000-0000-000000000102/pnl-corrected.csv',
  'pnl-corrected.csv',repeat('2',64),'text/csv',840,
  '70000000-0000-0000-0000-000000000001'
from outlet o where o.code='ING';

insert into import_batch(
  id,organisation_id,outlet_id,source_file_id,template_code,
  profile_version_id,period_id,scenario,status,
  detected_fingerprint,supersedes_batch_id
)
select
  '70000000-0000-0000-0000-000000000202',
  sf.organisation_id,sf.outlet_id,sf.id,sf.template_code,
  pv.id,rp.id,'actual','ready',repeat('b',64),
  '70000000-0000-0000-0000-000000000201'
from source_file sf
join profile_version pv
  on pv.organisation_id=sf.organisation_id and pv.outlet_id=sf.outlet_id
join reporting_period rp
  on rp.organisation_id=sf.organisation_id and rp.outlet_id=sf.outlet_id
where sf.id='70000000-0000-0000-0000-000000000102'
  and pv.version_no=1;

select test_assert_rejects7($q$
  update import_batch
  set status='committed',
      committed_by='70000000-0000-0000-0000-000000000001',
      committed_at=now(),
      canonical_commit_hash=repeat('d',64),
      canonical_commit_summary='{"fact_count":15}'::jsonb
  where id='70000000-0000-0000-0000-000000000202'
$q$, 'duplicate committed scope is blocked until explicit supersede');

select supersede_import_batch(
  '70000000-0000-0000-0000-000000000201',
  '70000000-0000-0000-0000-000000000202',
  'ingestion-supersede-test'
);

update import_batch
set status='committed',
    committed_by='70000000-0000-0000-0000-000000000001',
    committed_at=now(),
    canonical_commit_hash=repeat('d',64),
    canonical_commit_summary='{"fact_count":15}'::jsonb
where id='70000000-0000-0000-0000-000000000202';

select test_assert_eq7(
  (select count(*) from import_batch where status='committed'),
  1,
  'only one committed batch remains in outlet/period/scenario/template scope'
);

reset role;

select test_assert_rejects7($q$
  update source_file set original_filename='changed.csv'
  where id='70000000-0000-0000-0000-000000000101'
$q$, 'raw source-file metadata is immutable even for owner/service path');

select test_assert_rejects7($q$
  update staging_row set row_status='changed'
  where id='70000000-0000-0000-0000-000000000301'
$q$, 'staging row is immutable even for owner/service path');

select test_assert_rejects7($q$
  update import_batch set canonical_commit_hash=repeat('e',64)
  where id='70000000-0000-0000-0000-000000000202'
$q$, 'committed batch content is immutable even for owner/service path');

select test_assert_rejects7($q$
  update import_batch set status='ready'
  where id='70000000-0000-0000-0000-000000000201'
$q$, 'superseded batch is immutable even for owner/service path');

rollback;
