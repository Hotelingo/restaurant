\set ON_ERROR_STOP on

begin;

create or replace function test_assert_eq10(actual bigint, expected bigint, label text)
returns void language plpgsql as $$
begin
  if actual <> expected then
    raise exception 'FAIL % -- expected %, got %', label, expected, actual;
  end if;
  raise notice 'PASS  %', label;
end $$;

create or replace function test_assert_text10(actual text, expected text, label text)
returns void language plpgsql as $$
begin
  if actual is distinct from expected then
    raise exception 'FAIL % -- expected %, got %', label, expected, actual;
  end if;
  raise notice 'PASS  %', label;
end $$;

create or replace function test_assert_rejects10(stmt text, label text)
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
  ('a0000000-0000-0000-0000-000000000001','Commit Admin','commit@example.com',false);

set role restaurant_app;
select set_config('app.user_id','a0000000-0000-0000-0000-000000000001',true);

select * from bootstrap_organisation(
  'Commit Org','commit-org','Commit Outlet','COMMIT',
  'USD'::char(3),'UTC',1::smallint,'commit-bootstrap','commit-test'
);

insert into reporting_period(
  organisation_id,outlet_id,period_start,period_end,label
)
select organisation_id,id,'2026-07-01','2026-07-31','July 2026'
from outlet where code='COMMIT';

-- T1 approved profile + mapping.
insert into source_profile(organisation_id,outlet_id,template_code,source_label)
select organisation_id,id,'T1','Commit P&L'
from outlet where code='COMMIT';

insert into profile_version(
  organisation_id,outlet_id,source_profile_id,version_no,
  layout_json,fingerprint_hash,fingerprint_components_json,transform_config_json
)
select organisation_id,outlet_id,id,1,'{}',repeat('a',64),'{}','[]'
from source_profile where source_label='Commit P&L';

insert into account_mapping(
  organisation_id,outlet_id,profile_version_id,
  source_account_code,source_account_name,ladder_line_id,mapping_basis,approved_by
)
select
  pv.organisation_id,pv.outlet_id,pv.id,
  '4000','Food sales',ll.id,'confirmed',
  'a0000000-0000-0000-0000-000000000001'
from profile_version pv
join source_profile sp on sp.id=pv.source_profile_id
join ladder_line ll on ll.code='NET_SALES'
where sp.source_label='Commit P&L';

update profile_version
set status='approved',
    approved_by='a0000000-0000-0000-0000-000000000001',
    approved_at=now()
where fingerprint_hash=repeat('a',64);

update source_profile sp
set active_profile_version_id=pv.id
from profile_version pv
where pv.source_profile_id=sp.id and pv.fingerprint_hash=repeat('a',64);

insert into source_file(
  id,organisation_id,outlet_id,template_code,
  storage_bucket,storage_path,original_filename,sha256,
  content_type,size_bytes,uploaded_by,
  detected_file_type,row_count,malware_scan_status,
  malware_scanner,malware_scanned_at,inspection_json
)
select
  'a0000000-0000-0000-0000-000000000101',
  o.organisation_id,o.id,'T1','uploads',
  'org/'||o.organisation_id::text||'/outlet/'||o.id::text||
    '/source/a0000000-0000-0000-0000-000000000101/pnl.csv',
  'pnl.csv',repeat('1',64),'text/csv',100,
  'a0000000-0000-0000-0000-000000000001',
  'csv',2,'clean','clamav',now(),'{}'
from outlet o where o.code='COMMIT';

insert into import_batch(
  id,organisation_id,outlet_id,source_file_id,template_code,
  profile_version_id,period_id,scenario,status,detected_fingerprint
)
select
  'a0000000-0000-0000-0000-000000000201',
  sf.organisation_id,sf.outlet_id,sf.id,'T1',
  pv.id,rp.id,'actual','ready',repeat('a',64)
from source_file sf
join source_profile sp
  on sp.organisation_id=sf.organisation_id
 and sp.outlet_id=sf.outlet_id
 and sp.source_label='Commit P&L'
join profile_version pv on pv.id=sp.active_profile_version_id
join reporting_period rp
  on rp.organisation_id=sf.organisation_id and rp.outlet_id=sf.outlet_id
where sf.id='a0000000-0000-0000-0000-000000000101';

insert into staging_row(
  organisation_id,outlet_id,batch_id,source_row_no,
  raw_jsonb,parsed_jsonb,row_status
)
select
  b.organisation_id,b.outlet_id,b.id,2,
  '{"Account_Code":"4000","Account_Name":"Food sales","July_2026":"191100"}',
  '{"period":"2026-07","account_code":"4000","account_name":"Food sales","amount":"191100"}',
  'parsed'
from import_batch b
where b.id='a0000000-0000-0000-0000-000000000201';

-- Fault injection is owner-only. Every one of the nine transaction steps must
-- roll the entire commit back to zero facts and a ready batch.
reset role;

do $$
declare
  step_no int;
  fact_rows bigint;
  batch_state text;
begin
  for step_no in 1..9 loop
    begin
      perform *
      from public._commit_financial_import_batch(
        'a0000000-0000-0000-0000-000000000201',
        'fault-key-'||step_no::text,
        'fault-test',
        true,
        step_no
      );
      raise exception 'fault step % unexpectedly succeeded', step_no;
    exception
      when others then
        if sqlerrm not like 'FAULT_STEP_%' then
          raise;
        end if;
    end;

    select count(*) into fact_rows
    from public.financial_fact
    where batch_id='a0000000-0000-0000-0000-000000000201';

    select status::text into batch_state
    from public.import_batch
    where id='a0000000-0000-0000-0000-000000000201';

    if fact_rows <> 0 or batch_state <> 'ready' then
      raise exception
        'FAIL fault step % left facts=% batch_state=%',
        step_no, fact_rows, batch_state;
    end if;
  end loop;
  raise notice 'PASS  fault injection after every commit step rolls back all facts/state';
end
$$;

set role restaurant_app;
select set_config('app.user_id','a0000000-0000-0000-0000-000000000001',true);

select * from commit_financial_import_batch(
  'a0000000-0000-0000-0000-000000000201',
  'commit-idempotency-1',
  'commit-success',
  false
);

select test_assert_eq10(
  (select count(*) from financial_fact
   where batch_id='a0000000-0000-0000-0000-000000000201'),
  1,
  'successful T1 commit writes one canonical fact'
);

select test_assert_text10(
  (select status::text from import_batch
   where id='a0000000-0000-0000-0000-000000000201'),
  'committed',
  'successful T1 commit marks batch committed'
);

-- Same idempotency key returns original response without duplication.
select * from commit_financial_import_batch(
  'a0000000-0000-0000-0000-000000000201',
  'commit-idempotency-1',
  'commit-retry',
  false
);

select test_assert_eq10(
  (select count(*) from financial_fact
   where batch_id='a0000000-0000-0000-0000-000000000201'),
  1,
  'retry with same idempotency key does not duplicate facts'
);

select test_assert_text10(
  (select status from data_readiness
   where capability_code='management_pl'),
  'partial',
  'P&L readiness is partial until comparator commits'
);

-- T6 ladder-grain comparator profile + mapping.
insert into source_profile(organisation_id,outlet_id,template_code,source_label)
select organisation_id,id,'T6','Commit Budget'
from outlet where code='COMMIT';

insert into profile_version(
  organisation_id,outlet_id,source_profile_id,version_no,
  layout_json,fingerprint_hash,fingerprint_components_json,transform_config_json
)
select organisation_id,outlet_id,id,1,'{}',repeat('b',64),'{}','[]'
from source_profile where source_label='Commit Budget';

insert into value_mapping(
  organisation_id,outlet_id,profile_version_id,
  field_name,source_value,canonical_value
)
select
  pv.organisation_id,pv.outlet_id,pv.id,
  'management_line','Net Sales','NET_SALES'
from profile_version pv
join source_profile sp on sp.id=pv.source_profile_id
where sp.source_label='Commit Budget';

update profile_version
set status='approved',
    approved_by='a0000000-0000-0000-0000-000000000001',
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
  'a0000000-0000-0000-0000-000000000102',
  o.organisation_id,o.id,'T6','uploads',
  'org/'||o.organisation_id::text||'/outlet/'||o.id::text||
    '/source/a0000000-0000-0000-0000-000000000102/budget.csv',
  'budget.csv',repeat('2',64),'text/csv',100,
  'a0000000-0000-0000-0000-000000000001',
  'csv',2,'clean','clamav',now(),'{}'
from outlet o where o.code='COMMIT';

insert into import_batch(
  id,organisation_id,outlet_id,source_file_id,template_code,
  profile_version_id,period_id,scenario,status,detected_fingerprint
)
select
  'a0000000-0000-0000-0000-000000000202',
  sf.organisation_id,sf.outlet_id,sf.id,'T6',
  pv.id,rp.id,'budget','ready',repeat('b',64)
from source_file sf
join source_profile sp
  on sp.organisation_id=sf.organisation_id
 and sp.outlet_id=sf.outlet_id
 and sp.source_label='Commit Budget'
join profile_version pv on pv.id=sp.active_profile_version_id
join reporting_period rp
  on rp.organisation_id=sf.organisation_id and rp.outlet_id=sf.outlet_id
where sf.id='a0000000-0000-0000-0000-000000000102';

insert into staging_row(
  organisation_id,outlet_id,batch_id,source_row_no,
  raw_jsonb,parsed_jsonb,row_status
)
select
  b.organisation_id,b.outlet_id,b.id,2,
  '{"Management_Line":"Net Sales","Budget_July_2026":"232000"}',
  '{"period":"2026-07","management_line":"Net Sales","amount":"232000"}',
  'parsed'
from import_batch b
where b.id='a0000000-0000-0000-0000-000000000202';

select * from commit_financial_import_batch(
  'a0000000-0000-0000-0000-000000000202',
  'commit-idempotency-2',
  'commit-budget',
  true
);

select test_assert_eq10(
  (select count(*) from financial_fact
   where batch_id='a0000000-0000-0000-0000-000000000202'
     and account_id is null),
  1,
  'T6 commits directly at ladder grain without synthetic account'
);

select test_assert_text10(
  (select status from data_readiness
   where capability_code='management_pl'),
  'ready',
  'P&L readiness becomes ready after actual and comparator commit'
);

reset role;

select test_assert_eq10(
  (select count(*) from calculation_request_queue
   where source_batch_id='a0000000-0000-0000-0000-000000000202'
     and status='pending'),
  1,
  'optional step nine writes one durable calculation request'
);

select test_assert_rejects10($q$
  update financial_fact set amount=999
$q$, 'committed canonical facts remain immutable for owner/service path');

select test_assert_rejects10($q$
  update import_batch set canonical_commit_hash=repeat('9',64)
  where id='a0000000-0000-0000-0000-000000000201'
$q$, 'committed batch remains immutable for owner/service path');

rollback;
