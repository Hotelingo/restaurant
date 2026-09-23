-- 0038 · Import audit writer
--
-- Regression for the defect where POST /imports/upload and /parse inserted
-- into audit_log directly and failed under restaurant_app's RLS, so no file
-- could be uploaded. Proves the sanctioned writer works AND cannot be used to
-- forge audit history: not for another tenant, not by a read-only role, not
-- for arbitrary action codes, not with a chosen actor.

\set ON_ERROR_STOP on

begin;

create or replace function test_assert_rejects_audit(stmt text, label text)
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
grant execute on function test_assert_rejects_audit(text,text) to restaurant_app;

insert into neon_auth."user" (id,name,email,"emailVerified") values
  ('38000000-0000-0000-0000-00000000000a','Audit Admin A','audit-a@example.com',false),
  ('38000000-0000-0000-0000-00000000000b','Audit Admin B','audit-b@example.com',false),
  ('38000000-0000-0000-0000-00000000000c','Audit Viewer A','audit-v@example.com',false);

-- ------------------------------------------------ tenant A: admin + a batch
set role restaurant_app;
select set_config('app.user_id','38000000-0000-0000-0000-00000000000a',true);
select * from bootstrap_organisation(
  'Audit Org A','audit-org-a','Audit Outlet A','AUDA',
  'GBP'::char(3),'UTC',1::smallint,'audit-bootstrap-a','audit-test');

insert into source_file(
  id,organisation_id,outlet_id,template_code,storage_bucket,storage_path,
  original_filename,sha256,content_type,size_bytes,uploaded_by,
  detected_file_type,row_count,malware_scan_status,malware_scanner,
  malware_scanned_at,inspection_json)
select '38000000-0000-0000-0000-0000000000f1', o.organisation_id, o.id, 'T1', 'uploads',
  'org/'||o.organisation_id||'/outlet/'||o.id||'/source/38000000-0000-0000-0000-0000000000f1/pnl.csv',
  'pnl.csv', repeat('a',64), 'text/csv', 830, '38000000-0000-0000-0000-00000000000a',
  'csv', 15, 'clean', 'local-bypass', now(), '{"content_inspected":true}'::jsonb
from outlet o where o.code='AUDA';

insert into import_batch(id,organisation_id,outlet_id,source_file_id,template_code,status)
select '38000000-0000-0000-0000-0000000000b1', o.organisation_id, o.id,
       '38000000-0000-0000-0000-0000000000f1', 'T1', 'uploaded'
from outlet o where o.code='AUDA';

-- ------------------------------------------------ the sanctioned path works
select record_import_audit_event(
  '38000000-0000-0000-0000-0000000000b1','IMPORT_FILE_UPLOADED','source_file',
  '38000000-0000-0000-0000-0000000000f1',null,'corr-upload');
select record_import_audit_event(
  '38000000-0000-0000-0000-0000000000b1','IMPORT_BATCH_PARSED','import_batch',
  '38000000-0000-0000-0000-0000000000b1','fingerprint-hash',null);

do $$
declare v_rows int; v_actor_ok boolean; v_tenant_ok boolean;
begin
  select count(*),
         bool_and(a.actor_user_id = '38000000-0000-0000-0000-00000000000a'),
         bool_and(a.organisation_id = b.organisation_id and a.outlet_id = b.outlet_id)
    into v_rows, v_actor_ok, v_tenant_ok
    from audit_log a
    join import_batch b on b.id = '38000000-0000-0000-0000-0000000000b1'
   where a.action_code in ('IMPORT_FILE_UPLOADED','IMPORT_BATCH_PARSED')
     and a.organisation_id = b.organisation_id;
  if v_rows <> 2 or not v_actor_ok or not v_tenant_ok then
    raise exception 'FAIL import audit rows: rows=% actor_ok=% tenant_ok=%', v_rows, v_actor_ok, v_tenant_ok;
  end if;
  raise notice 'PASS  admin records upload and parse events; actor and tenant derived server-side';
end $$;

-- ------------------------------------------------ the guarantees still hold
select test_assert_rejects_audit($q$
  insert into audit_log(actor_user_id,organisation_id,outlet_id,action_code,object_type)
  select '38000000-0000-0000-0000-00000000000a', organisation_id, outlet_id,
         'IMPORT_FILE_UPLOADED','source_file'
  from import_batch where id='38000000-0000-0000-0000-0000000000b1'
$q$, 'direct audit_log INSERT remains denied to restaurant_app');

select test_assert_rejects_audit($q$
  select record_import_audit_event('38000000-0000-0000-0000-0000000000b1',
    'MEMBER_DEACTIVATED','import_batch','x',null,null)
$q$, 'writer refuses action codes outside the import set');

select test_assert_rejects_audit($q$
  select record_import_audit_event('38000000-0000-0000-0000-0000000000b1',
    'IMPORT_FILE_UPLOADED','membership','x',null,null)
$q$, 'writer refuses object types outside the import set');

select test_assert_rejects_audit($q$
  select record_import_audit_event('38000000-0000-0000-0000-0000000000ff',
    'IMPORT_FILE_UPLOADED','source_file','x',null,null)
$q$, 'unknown batch is refused');

-- ------------------------------------------------ tenant B cannot forge into A
select set_config('app.user_id','38000000-0000-0000-0000-00000000000b',true);
select * from bootstrap_organisation(
  'Audit Org B','audit-org-b','Audit Outlet B','AUDB',
  'GBP'::char(3),'UTC',1::smallint,'audit-bootstrap-b','audit-test');

select test_assert_rejects_audit($q$
  select record_import_audit_event('38000000-0000-0000-0000-0000000000b1',
    'IMPORT_FILE_UPLOADED','source_file','x',null,null)
$q$, 'another tenant cannot write audit events against this batch');

-- ------------------------------------------------ a read-only role cannot either
reset role;
insert into membership(organisation_id,user_id,role,outlet_scope_mode)
select organisation_id,'38000000-0000-0000-0000-00000000000c','viewer','all_outlets'
from import_batch where id='38000000-0000-0000-0000-0000000000b1';
set role restaurant_app;
select set_config('app.user_id','38000000-0000-0000-0000-00000000000c',true);

select test_assert_rejects_audit($q$
  select record_import_audit_event('38000000-0000-0000-0000-0000000000b1',
    'IMPORT_FILE_UPLOADED','source_file','x',null,null)
$q$, 'viewer in the same organisation cannot record import events');

-- ------------------------------------------------ no authenticated user
select set_config('app.user_id','',true);
select test_assert_rejects_audit($q$
  select record_import_audit_event('38000000-0000-0000-0000-0000000000b1',
    'IMPORT_FILE_UPLOADED','source_file','x',null,null)
$q$, 'writer requires an authenticated user context');

reset role;
rollback;
