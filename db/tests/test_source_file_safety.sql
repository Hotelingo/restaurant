\set ON_ERROR_STOP on

begin;

create or replace function test_assert_rejects8(stmt text, label text)
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
  ('80000000-0000-0000-0000-000000000001','Safety Admin','safety@example.com',false);

set role restaurant_app;
select set_config('app.user_id','80000000-0000-0000-0000-000000000001',true);

select * from bootstrap_organisation(
  'Safety Org','safety-org','Safety Outlet','SAFE',
  'USD'::char(3),'UTC',1::smallint,'safety-bootstrap','safety-test'
);

insert into source_file(
  id,organisation_id,outlet_id,template_code,
  storage_bucket,storage_path,original_filename,sha256,
  content_type,size_bytes,uploaded_by,
  detected_file_type,row_count,malware_scan_status,
  malware_scanner,malware_scanned_at,inspection_json
)
select
  '80000000-0000-0000-0000-000000000101',
  o.organisation_id,o.id,'T1','uploads',
  'org/'||o.organisation_id::text||'/outlet/'||o.id::text||
    '/source/80000000-0000-0000-0000-000000000101/pnl.csv',
  'pnl.csv',repeat('1',64),'text/csv',1000,
  '80000000-0000-0000-0000-000000000001',
  'csv',10,'clean','clamav',now(),
  '{"content_inspected":true}'::jsonb
from outlet o where o.code='SAFE';

select test_assert_rejects8($q$
  insert into source_file(
    id,organisation_id,outlet_id,template_code,
    storage_bucket,storage_path,original_filename,sha256,
    content_type,size_bytes,uploaded_by,
    detected_file_type,row_count,malware_scan_status,
    malware_scanner,malware_scanned_at,inspection_json
  )
  select
    '80000000-0000-0000-0000-000000000102',
    o.organisation_id,o.id,'T1','public-files',
    'org/'||o.organisation_id::text||'/outlet/'||o.id::text||
      '/source/80000000-0000-0000-0000-000000000102/bad.csv',
    'bad.csv',repeat('2',64),'text/csv',1000,
    '80000000-0000-0000-0000-000000000001',
    'csv',10,'clean','clamav',now(),'{}'::jsonb
  from outlet o where o.code='SAFE'
$q$, 'source file must use the R1 private uploads bucket');

select test_assert_rejects8($q$
  insert into source_file(
    id,organisation_id,outlet_id,template_code,
    storage_bucket,storage_path,original_filename,sha256,
    content_type,size_bytes,uploaded_by,
    detected_file_type,row_count,malware_scan_status,
    malware_scanner,malware_scanned_at,inspection_json
  )
  select
    '80000000-0000-0000-0000-000000000103',
    o.organisation_id,o.id,'T1','uploads',
    'org/'||o.organisation_id::text||'/outlet/'||o.id::text||
      '/source/80000000-0000-0000-0000-000000000103/too-many.csv',
    'too-many.csv',repeat('3',64),'text/csv',1000,
    '80000000-0000-0000-0000-000000000001',
    'csv',250001,'clean','clamav',now(),'{}'::jsonb
  from outlet o where o.code='SAFE'
$q$, 'source file row cap is enforced in PostgreSQL');

select test_assert_rejects8($q$
  insert into source_file(
    id,organisation_id,outlet_id,template_code,
    storage_bucket,storage_path,original_filename,sha256,
    content_type,size_bytes,uploaded_by,
    detected_file_type,row_count,malware_scan_status,
    malware_scanner,malware_scanned_at,inspection_json
  )
  select
    '80000000-0000-0000-0000-000000000104',
    o.organisation_id,o.id,'T1','uploads',
    'org/'||o.organisation_id::text||'/outlet/'||o.id::text||
      '/source/80000000-0000-0000-0000-000000000104/infected.csv',
    'infected.csv',repeat('4',64),'text/csv',1000,
    '80000000-0000-0000-0000-000000000001',
    'csv',10,'infected','clamav',now(),'{}'::jsonb
  from outlet o where o.code='SAFE'
$q$, 'non-clean malware status cannot be persisted as an accepted source file');

rollback;
