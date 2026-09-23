-- 0039 · Period calculation requests
--
-- Proves a calculation can be requested (and re-requested) without the
-- commit-time flag, that repeats are coalesced, and that the request path
-- cannot be used across tenants, by viewers, for unknown modules, with no
-- committed data, or unauthenticated.

\set ON_ERROR_STOP on

begin;

create or replace function test_assert_rejects_calc(stmt text, label text)
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
grant execute on function test_assert_rejects_calc(text,text) to restaurant_app;

insert into neon_auth."user" (id,name,email,"emailVerified") values
  ('39000000-0000-0000-0000-00000000000a','Calc Admin A','calc-a@example.com',false),
  ('39000000-0000-0000-0000-00000000000b','Calc Admin B','calc-b@example.com',false),
  ('39000000-0000-0000-0000-00000000000c','Calc Viewer A','calc-v@example.com',false);

-- ------------------------------------------------ tenant A with a period
set role restaurant_app;
select set_config('app.user_id','39000000-0000-0000-0000-00000000000a',true);
select * from bootstrap_organisation(
  'Calc Org A','calc-org-a','Calc Outlet A','CALA',
  'GBP'::char(3),'UTC',1::smallint,'calc-bootstrap-a','calc-test');
select * from create_reporting_period(
  (select id from outlet where code='CALA'),
  '2026-07-01','2026-07-31','July 2026','calc-period-a','calc-test');

-- ------------------------------------------------ nothing committed yet
select test_assert_rejects_calc($q$
  select * from request_period_calculation(
    (select id from reporting_period where label='July 2026'
       and outlet_id=(select id from outlet where code='CALA')),'pl')
$q$, 'a period with no committed data cannot be calculated');

select test_assert_rejects_calc($q$
  select * from request_period_calculation(
    (select id from reporting_period where label='July 2026'
       and outlet_id=(select id from outlet where code='CALA')),'menu')
$q$, 'unsupported module is refused');

-- ------------------------------------------------ a committed T1 batch
reset role;
insert into source_file(
  id,organisation_id,outlet_id,template_code,storage_bucket,storage_path,
  original_filename,sha256,content_type,size_bytes,uploaded_by,
  detected_file_type,row_count,malware_scan_status,malware_scanner,
  malware_scanned_at,inspection_json)
select '39000000-0000-0000-0000-0000000000f1', o.organisation_id, o.id, 'T1', 'uploads',
  'org/'||o.organisation_id||'/outlet/'||o.id||'/source/39000000-0000-0000-0000-0000000000f1/pnl.csv',
  'pnl.csv', repeat('c',64), 'text/csv', 830, '39000000-0000-0000-0000-00000000000a',
  'csv', 15, 'clean', 'local-bypass', now(), '{"content_inspected":true}'::jsonb
from outlet o where o.code='CALA';
insert into source_profile(id,organisation_id,outlet_id,template_code,source_label)
select '39000000-0000-0000-0000-0000000000a1', organisation_id, id, 'T1', 'Calc actual'
from outlet where code='CALA';
insert into profile_version(id,organisation_id,outlet_id,source_profile_id,version_no,
  layout_json,fingerprint_hash,fingerprint_components_json,transform_config_json,
  status,approved_by,approved_at)
select '39000000-0000-0000-0000-0000000000a2', organisation_id, outlet_id, id, 1,
  '{}', repeat('e',64), '{}', '[]', 'approved', '39000000-0000-0000-0000-00000000000a', now()
from source_profile where id='39000000-0000-0000-0000-0000000000a1';
insert into import_batch(id,organisation_id,outlet_id,source_file_id,template_code,
                         profile_version_id,period_id,scenario,status,
                         committed_by,committed_at,canonical_commit_hash)
select '39000000-0000-0000-0000-0000000000b1', o.organisation_id, o.id,
       '39000000-0000-0000-0000-0000000000f1', 'T1', '39000000-0000-0000-0000-0000000000a2',
       p.id, 'actual', 'committed', '39000000-0000-0000-0000-00000000000a', now(), repeat('d',64)
from outlet o join reporting_period p on p.outlet_id=o.id where o.code='CALA';
set role restaurant_app;
select set_config('app.user_id','39000000-0000-0000-0000-00000000000a',true);

-- ------------------------------------------------ request, then coalesce
do $$
declare v_first record; v_second record; v_period uuid;
begin
  select p.id into v_period from reporting_period p join outlet o on o.id=p.outlet_id where o.code='CALA';
  select * into v_first from request_period_calculation(v_period,'pl');
  if v_first.reused or v_first.request_status <> 'pending'
     or v_first.source_batch_id <> '39000000-0000-0000-0000-0000000000b1' then
    raise exception 'FAIL first request: %', row_to_json(v_first);
  end if;
  select * into v_second from request_period_calculation(v_period,'pl');
  if not v_second.reused or v_second.request_id <> v_first.request_id then
    raise exception 'FAIL repeat request was not coalesced: %', row_to_json(v_second);
  end if;
  raise notice 'PASS  admin requests a P&L calculation; an immediate repeat returns the same request';
end $$;

do $$
declare v_rows int; v_reason text;
begin
  select count(*), min(reason) into v_rows, v_reason
    from list_period_calculations(
      (select p.id from reporting_period p join outlet o on o.id=p.outlet_id where o.code='CALA'));
  if v_rows <> 1 or v_reason <> 'pl_manual_recalculation' then
    raise exception 'FAIL list_period_calculations: rows=% reason=%', v_rows, v_reason;
  end if;
  raise notice 'PASS  the request is visible with a reason the worker dispatches to the P&L engine';
end $$;

-- ------------------------------------------------ tenant B
select set_config('app.user_id','39000000-0000-0000-0000-00000000000b',true);
select * from bootstrap_organisation(
  'Calc Org B','calc-org-b','Calc Outlet B','CALB',
  'GBP'::char(3),'UTC',1::smallint,'calc-bootstrap-b','calc-test');

reset role;
create temporary table calc_target on commit drop as
  select p.id from reporting_period p join outlet o on o.id=p.outlet_id where o.code='CALA';
grant select on calc_target to restaurant_app;
set role restaurant_app;
select set_config('app.user_id','39000000-0000-0000-0000-00000000000b',true);

select test_assert_rejects_calc($q$
  select * from request_period_calculation((select id from calc_target),'pl')
$q$, 'another tenant cannot request a calculation for this period');

select test_assert_rejects_calc($q$
  select * from list_period_calculations((select id from calc_target))
$q$, 'another tenant cannot read this period''s calculation status');

-- ------------------------------------------------ viewer in tenant A
reset role;
insert into membership(organisation_id,user_id,role,outlet_scope_mode)
select organisation_id,'39000000-0000-0000-0000-00000000000c','viewer','all_outlets'
from outlet where code='CALA';
set role restaurant_app;
select set_config('app.user_id','39000000-0000-0000-0000-00000000000c',true);

select test_assert_rejects_calc($q$
  select * from request_period_calculation((select id from calc_target),'pl')
$q$, 'a viewer cannot request a calculation');

do $$
begin
  if (select count(*) from list_period_calculations((select id from calc_target))) <> 1 then
    raise exception 'FAIL viewer should be able to read calculation status';
  end if;
  raise notice 'PASS  a viewer can read calculation status';
end $$;

-- ------------------------------------------------ unauthenticated
select set_config('app.user_id','',true);
select test_assert_rejects_calc($q$
  select * from request_period_calculation((select id from calc_target),'pl')
$q$, 'requesting a calculation requires an authenticated user');

reset role;
rollback;
