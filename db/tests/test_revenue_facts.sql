\set ON_ERROR_STOP on
begin;

create or replace function rv33_eq(actual bigint, expected bigint, label text)
returns void language plpgsql as $$
begin
  if actual is distinct from expected then
    raise exception 'FAIL % -- expected %, got %',label,expected,actual;
  end if;
  raise notice 'PASS %',label;
end $$;

create or replace function rv33_num(actual numeric, expected numeric, label text)
returns void language plpgsql as $$
begin
  if actual is distinct from expected then
    raise exception 'FAIL % -- expected %, got %',label,expected,actual;
  end if;
  raise notice 'PASS %',label;
end $$;

create or replace function rv33_text(actual text, expected text, label text)
returns void language plpgsql as $$
begin
  if actual is distinct from expected then
    raise exception 'FAIL % -- expected %, got %',label,expected,actual;
  end if;
  raise notice 'PASS %',label;
end $$;

create or replace function rv33_true(actual boolean, label text)
returns void language plpgsql as $$
begin
  if not coalesce(actual,false) then
    raise exception 'FAIL %',label;
  end if;
  raise notice 'PASS %',label;
end $$;

create or replace function rv33_rejects(stmt text, label text)
returns void language plpgsql as $$
begin
  begin
    execute stmt;
  exception when others then
    raise notice 'PASS % (%)',label,sqlerrm;
    return;
  end;
  raise exception 'FAIL % accepted unexpectedly',label;
end $$;


insert into neon_auth."user"(id,name,email,"emailVerified")
values(
  '33000000-0000-0000-0000-000000000001',
  'Revenue Admin',
  'revenue-admin@example.com',
  false
);

set role restaurant_app;
select set_config('app.user_id','33000000-0000-0000-0000-000000000001',true);

select * from bootstrap_organisation(
  'Revenue Org','revenue-org',
  'Revenue Outlet','REV33',
  'USD'::char(3),'UTC',1::smallint,
  'rv33-bootstrap','rv33-test'
);

insert into reporting_period(
  id,organisation_id,outlet_id,period_start,period_end,label
)
select
  '33000000-0000-0000-0000-000000000010',
  organisation_id,id,'2026-07-01','2026-07-31','July 2026'
from outlet where code='REV33';

reset role;


-- Minimal committed T1 accounting anchor: Net Sales = 228,500.
insert into source_profile(
  id,organisation_id,outlet_id,template_code,source_label
)
select
  '33000000-0000-0000-0000-000000000101',
  organisation_id,id,'T1','Revenue P&L'
from outlet where code='REV33';

insert into profile_version(
  id,organisation_id,outlet_id,source_profile_id,version_no,
  layout_json,fingerprint_hash,fingerprint_components_json,transform_config_json
)
select
  '33000000-0000-0000-0000-000000000111',
  organisation_id,outlet_id,id,1,
  '{}'::jsonb,repeat('1',64),'{}'::jsonb,'[]'::jsonb
from source_profile where id='33000000-0000-0000-0000-000000000101';

insert into account_mapping(
  organisation_id,outlet_id,profile_version_id,
  source_account_code,source_account_name,ladder_line_id,
  mapping_basis,approved_by
)
select
  pv.organisation_id,pv.outlet_id,pv.id,
  '4000','Net sales',ll.id,'confirmed',
  '33000000-0000-0000-0000-000000000001'
from profile_version pv
join ladder_line ll on ll.code='NET_SALES'
where pv.id='33000000-0000-0000-0000-000000000111';

update profile_version
set status='approved',
    approved_by='33000000-0000-0000-0000-000000000001',
    approved_at=now()
where id='33000000-0000-0000-0000-000000000111';

update source_profile
set active_profile_version_id='33000000-0000-0000-0000-000000000111'
where id='33000000-0000-0000-0000-000000000101';

insert into source_file(
  id,organisation_id,outlet_id,template_code,
  storage_bucket,storage_path,original_filename,sha256,
  content_type,size_bytes,uploaded_by,detected_file_type,row_count,
  malware_scan_status,malware_scanner,malware_scanned_at,inspection_json
)
select
  '33000000-0000-0000-0000-000000000121',
  o.organisation_id,o.id,'T1','uploads',
  'org/'||o.organisation_id::text||'/outlet/'||o.id::text||
    '/source/33000000-0000-0000-0000-000000000121/pnl.csv',
  'pnl.csv',repeat('a',64),'text/csv',100,
  '33000000-0000-0000-0000-000000000001',
  'csv',1,'clean','ci',now(),'{}'::jsonb
from outlet o where o.code='REV33';

insert into import_batch(
  id,organisation_id,outlet_id,source_file_id,template_code,
  profile_version_id,period_id,scenario,status,detected_fingerprint
)
select
  '33000000-0000-0000-0000-000000000131',
  sf.organisation_id,sf.outlet_id,sf.id,'T1',
  '33000000-0000-0000-0000-000000000111',
  '33000000-0000-0000-0000-000000000010',
  'actual','ready',repeat('1',64)
from source_file sf
where sf.id='33000000-0000-0000-0000-000000000121';

insert into staging_row(
  organisation_id,outlet_id,batch_id,source_row_no,
  raw_jsonb,parsed_jsonb,row_status
)
select organisation_id,outlet_id,id,2,
  '{"Account_Code":"4000","Account_Name":"Net sales","July_2026":"228500"}',
  '{"period":"2026-07","account_code":"4000","account_name":"Net sales","amount":"228500"}',
  'parsed'
from import_batch
where id='33000000-0000-0000-0000-000000000131';

set role restaurant_app;
select set_config('app.user_id','33000000-0000-0000-0000-000000000001',true);

select * from commit_financial_import_batch(
  '33000000-0000-0000-0000-000000000131',
  'rv33-pnl-commit',
  'rv33-test',
  false
);

reset role;


-- Approved layout-only profiles for T1B and T7.
insert into source_profile(
  id,organisation_id,outlet_id,template_code,source_label
)
select v.id,o.organisation_id,o.id,v.template_code,v.source_label
from outlet o
cross join (values
  ('33000000-0000-0000-0000-000000000102'::uuid,'T1B','Meal Period Sales'),
  ('33000000-0000-0000-0000-000000000103'::uuid,'T7','Customer Source')
) v(id,template_code,source_label)
where o.code='REV33';

insert into profile_version(
  id,organisation_id,outlet_id,source_profile_id,version_no,
  layout_json,fingerprint_hash,fingerprint_components_json,transform_config_json
)
select
  v.profile_id,sp.organisation_id,sp.outlet_id,sp.id,1,
  '{}'::jsonb,v.hash,'{}'::jsonb,
  '[{"code":"fixed_value","target_field":"period","value":"2026-07"}]'::jsonb
from source_profile sp
join (values
  ('33000000-0000-0000-0000-000000000102'::uuid,'33000000-0000-0000-0000-000000000112'::uuid,repeat('2',64)),
  ('33000000-0000-0000-0000-000000000103'::uuid,'33000000-0000-0000-0000-000000000113'::uuid,repeat('3',64))
) v(source_id,profile_id,hash)
  on v.source_id=sp.id;

update profile_version
set status='approved',
    approved_by='33000000-0000-0000-0000-000000000001',
    approved_at=now()
where id in (
  '33000000-0000-0000-0000-000000000112',
  '33000000-0000-0000-0000-000000000113'
);

update source_profile sp
set active_profile_version_id=pv.id
from profile_version pv
where pv.source_profile_id=sp.id
  and sp.id in (
    '33000000-0000-0000-0000-000000000102',
    '33000000-0000-0000-0000-000000000103'
  );

insert into source_file(
  id,organisation_id,outlet_id,template_code,
  storage_bucket,storage_path,original_filename,sha256,
  content_type,size_bytes,uploaded_by,detected_file_type,row_count,
  malware_scan_status,malware_scanner,malware_scanned_at,inspection_json
)
select
  v.id,o.organisation_id,o.id,v.template_code,'uploads',
  'org/'||o.organisation_id::text||'/outlet/'||o.id::text||
    '/source/'||v.id::text||'/'||lower(v.template_code)||'.csv',
  lower(v.template_code)||'.csv',v.hash,'text/csv',1000,
  '33000000-0000-0000-0000-000000000001',
  'csv',v.row_count,'clean','ci',now(),'{}'::jsonb
from outlet o
cross join (values
  ('33000000-0000-0000-0000-000000000122'::uuid,'T1B',repeat('b',64),6),
  ('33000000-0000-0000-0000-000000000123'::uuid,'T7',repeat('c',64),9)
) v(id,template_code,hash,row_count)
where o.code='REV33';

insert into import_batch(
  id,organisation_id,outlet_id,source_file_id,template_code,
  profile_version_id,period_id,scenario,status,detected_fingerprint
)
select
  v.batch_id,sf.organisation_id,sf.outlet_id,sf.id,sf.template_code,
  v.profile_id,'33000000-0000-0000-0000-000000000010',
  'actual','ready',v.fingerprint
from source_file sf
join (values
  ('33000000-0000-0000-0000-000000000122'::uuid,'33000000-0000-0000-0000-000000000132'::uuid,'33000000-0000-0000-0000-000000000112'::uuid,repeat('2',64)),
  ('33000000-0000-0000-0000-000000000123'::uuid,'33000000-0000-0000-0000-000000000133'::uuid,'33000000-0000-0000-0000-000000000113'::uuid,repeat('3',64))
) v(source_id,batch_id,profile_id,fingerprint)
  on v.source_id=sf.id;


-- Amberside T1B meal-period/business-format rows.
insert into staging_row(
  organisation_id,outlet_id,batch_id,source_row_no,
  raw_jsonb,parsed_jsonb,row_status
)
select
  b.organisation_id,b.outlet_id,b.id,v.row_no,
  jsonb_build_object(
    'Meal_Period',v.view_key,'Units',v.actual_units,
    'Unit_Basis',v.unit_type,'Avg_Spend',v.actual_avg,
    'Revenue',v.actual_revenue,'Budget_Units',v.budget_units,
    'Budget_Avg_Spend',v.budget_avg,'Budget_Revenue',v.budget_revenue
  ),
  jsonb_build_object(
    'period','2026-07',
    'business_view_type','meal_period',
    'business_view_key',v.view_key,
    'activity_units',v.actual_units::text,
    'activity_unit_type',v.unit_type,
    'source_avg_spend',v.actual_avg::text,
    'revenue',v.actual_revenue::text,
    'comparator_activity_units',v.budget_units::text,
    'source_comparator_avg_spend',v.budget_avg::text,
    'comparator_revenue',v.budget_revenue::text
  ),
  'parsed'
from import_batch b
cross join (values
  (2,'Brunch',700::numeric,'covers',37::numeric,25900::numeric,650::numeric,36::numeric,23400::numeric),
  (3,'Lunch',1480::numeric,'covers',31::numeric,45880::numeric,1650::numeric,31::numeric,51150::numeric),
  (4,'Dinner',2390::numeric,'covers',48::numeric,114720::numeric,2450::numeric,47::numeric,115150::numeric),
  (5,'Delivery / Takeaway',750::numeric,'orders',36::numeric,27000::numeric,700::numeric,36::numeric,25200::numeric),
  (6,'Private Event',240::numeric,'guests',52::numeric,12480::numeric,250::numeric,56::numeric,14000::numeric),
  (7,'Corporate / Group',90::numeric,'guests',28::numeric,2520::numeric,100::numeric,31::numeric,3100::numeric)
) v(row_no,view_key,actual_units,unit_type,actual_avg,actual_revenue,budget_units,budget_avg,budget_revenue)
where b.id='33000000-0000-0000-0000-000000000132';


-- Amberside T7 source/channel rows.
insert into staging_row(
  organisation_id,outlet_id,batch_id,source_row_no,
  raw_jsonb,parsed_jsonb,row_status
)
select
  b.organisation_id,b.outlet_id,b.id,v.row_no,
  jsonb_build_object(
    'Customer_Source',v.source_channel,'Revenue',v.revenue,
    'Channel_Cost',v.channel_cost,'Evidence_Status',v.evidence_display
  ),
  jsonb_build_object(
    'period','2026-07',
    'source_channel',v.source_channel,
    'attributed_revenue',v.revenue::text,
    'direct_channel_cost',v.channel_cost::text,
    'source_evidence_status',v.evidence_status
  ),
  'parsed'
from import_batch b
cross join (values
  (2,'Direct / Walk-in',67000::numeric,0::numeric,'Partly Supported','partly_supported'),
  (3,'Repeat',55000::numeric,0::numeric,'Partly Supported','partly_supported'),
  (4,'Corporate / Local Office',15000::numeric,200::numeric,'Supported','supported'),
  (5,'Organic Digital',17000::numeric,250::numeric,'Supported','supported'),
  (6,'Paid Marketing',15500::numeric,1250::numeric,'Supported','supported'),
  (7,'Reservation Platform',13500::numeric,675::numeric,'Supported','supported'),
  (8,'Delivery Platform',23000::numeric,1000::numeric,'Supported','supported'),
  (9,'Event',8500::numeric,125::numeric,'Supported','supported'),
  (10,'Not attributed',14000::numeric,100::numeric,'Evidence Required','evidence_required')
) v(row_no,source_channel,revenue,channel_cost,evidence_display,evidence_status)
where b.id='33000000-0000-0000-0000-000000000133';


set role restaurant_app;
select set_config('app.user_id','33000000-0000-0000-0000-000000000001',true);

select * from commit_revenue_import_batch(
  '33000000-0000-0000-0000-000000000132',
  'rv33-t1b-commit',
  'rv33-test',
  false
);
select * from commit_revenue_import_batch(
  '33000000-0000-0000-0000-000000000133',
  'rv33-t7-commit',
  'rv33-test',
  false
);

select rv33_eq(
  (select count(*) from revenue_activity_fact
   where batch_id='33000000-0000-0000-0000-000000000132'),
  6,
  'T1B commits six immutable revenue activity facts'
);
select rv33_eq(
  (select count(*) from channel_source_fact
   where batch_id='33000000-0000-0000-0000-000000000133'),
  9,
  'T7 commits nine immutable source/channel facts'
);
select rv33_num(
  (select sum(revenue) from revenue_activity_fact
   where batch_id='33000000-0000-0000-0000-000000000132'),
  228500,
  'T1B actual revenue totals Amberside Net Sales'
);
select rv33_num(
  (select sum(comparator_revenue) from revenue_activity_fact
   where batch_id='33000000-0000-0000-0000-000000000132'),
  232000,
  'T1B embedded comparator revenue totals Amberside budget'
);
select rv33_num(
  (select sum(attributed_revenue) from channel_source_fact
   where batch_id='33000000-0000-0000-0000-000000000133'),
  228500,
  'T7 attributed revenue totals Amberside Net Sales'
);
select rv33_num(
  (select sum(direct_channel_cost) from channel_source_fact
   where batch_id='33000000-0000-0000-0000-000000000133'),
  3600,
  'T7 direct channel cost totals Management P&L channel cost'
);
select rv33_text(
  (select source_evidence_status from channel_source_fact
   where batch_id='33000000-0000-0000-0000-000000000133'
     and source_channel='Not attributed'),
  'evidence_required',
  'T7 evidence-required state remains canonical evidence'
);

select rv33_text(
  (select status from data_readiness
   where outlet_id=(select id from outlet where code='REV33')
     and period_id='33000000-0000-0000-0000-000000000010'
     and capability_code='revenue_inputs'),
  'ready',
  'Revenue readiness becomes ready after T1B and T7 tie to P&L Net Sales'
);
select rv33_true(
  (select (details_json->>'t1b_pnl_tie')::boolean
          and (details_json->>'t7_pnl_tie')::boolean
   from data_readiness
   where outlet_id=(select id from outlet where code='REV33')
     and period_id='33000000-0000-0000-0000-000000000010'
     and capability_code='revenue_inputs'),
  'Readiness discloses both accounting tie-outs'
);

select rv33_true(
  (select reused from commit_revenue_import_batch(
    '33000000-0000-0000-0000-000000000132',
    'rv33-t1b-commit',
    'rv33-test',
    false
  )),
  'Revenue commit is idempotent'
);
select rv33_eq(
  (select count(*) from revenue_activity_fact
   where batch_id='33000000-0000-0000-0000-000000000132'),
  6,
  'Revenue commit retry creates no duplicate facts'
);

select rv33_eq(
  (
    select count(*)
    from revenue_activity_fact f
    join staging_row s
      on s.id=f.staging_row_id and s.batch_id=f.batch_id
    join import_batch b on b.id=f.batch_id
    join source_file sf on sf.id=b.source_file_id
    where f.batch_id='33000000-0000-0000-0000-000000000132'
      and b.canonical_commit_hash is not null
      and sf.sha256 ~ '^[0-9a-f]{64}$'
  ),
  6,
  'T1B facts retain staging/batch/source-file lineage'
);
select rv33_eq(
  (
    select count(*)
    from channel_source_fact f
    join staging_row s
      on s.id=f.staging_row_id and s.batch_id=f.batch_id
    join import_batch b on b.id=f.batch_id
    join source_file sf on sf.id=b.source_file_id
    where f.batch_id='33000000-0000-0000-0000-000000000133'
      and b.canonical_commit_hash is not null
      and sf.sha256 ~ '^[0-9a-f]{64}$'
  ),
  9,
  'T7 facts retain staging/batch/source-file lineage'
);

select rv33_rejects(
  $q$ update revenue_activity_fact set revenue=0
      where batch_id='33000000-0000-0000-0000-000000000132' $q$,
  'committed T1B facts are immutable'
);
select rv33_rejects(
  $q$ update channel_source_fact set attributed_revenue=0
      where batch_id='33000000-0000-0000-0000-000000000133' $q$,
  'committed T7 facts are immutable'
);
select rv33_rejects(
  $q$ insert into revenue_activity_fact(
      organisation_id,outlet_id,period_id,
      business_view_type,business_view_key,activity_unit_type,
      activity_units,revenue,batch_id,profile_version_id,staging_row_id
    )
    select
      organisation_id,outlet_id,period_id,
      'meal_period','Forged','covers',1,1,
      id,profile_version_id,
      (select id from staging_row where batch_id=import_batch.id limit 1)
    from import_batch
    where id='33000000-0000-0000-0000-000000000132' $q$,
  'restaurant_app cannot directly write T1B canonical facts'
);

reset role;


-- Atomicity: an otherwise valid extra T7 batch rolls back at every stage.
insert into source_file(
  id,organisation_id,outlet_id,template_code,
  storage_bucket,storage_path,original_filename,sha256,
  content_type,size_bytes,uploaded_by,detected_file_type,row_count,
  malware_scan_status,malware_scanner,malware_scanned_at,inspection_json
)
select
  '33000000-0000-0000-0000-000000000124',
  o.organisation_id,o.id,'T7','uploads',
  'org/'||o.organisation_id::text||'/outlet/'||o.id::text||
    '/source/33000000-0000-0000-0000-000000000124/fault-t7.csv',
  'fault-t7.csv',repeat('d',64),'text/csv',100,
  '33000000-0000-0000-0000-000000000001',
  'csv',1,'clean','ci',now(),'{}'::jsonb
from outlet o where o.code='REV33';

insert into import_batch(
  id,organisation_id,outlet_id,source_file_id,template_code,
  profile_version_id,period_id,scenario,status,detected_fingerprint
)
select
  '33000000-0000-0000-0000-000000000134',
  sf.organisation_id,sf.outlet_id,sf.id,'T7',
  '33000000-0000-0000-0000-000000000113',
  '33000000-0000-0000-0000-000000000010',
  'actual','ready',repeat('3',64)
from source_file sf
where sf.id='33000000-0000-0000-0000-000000000124';

insert into staging_row(
  organisation_id,outlet_id,batch_id,source_row_no,
  raw_jsonb,parsed_jsonb,row_status
)
select organisation_id,outlet_id,id,2,
  '{"Customer_Source":"Test","Revenue":"1","Channel_Cost":"0"}',
  '{"period":"2026-07","source_channel":"Test","attributed_revenue":"1","direct_channel_cost":"0","source_evidence_status":"supported"}',
  'parsed'
from import_batch
where id='33000000-0000-0000-0000-000000000134';

do $$
declare
  step_no int;
  rows_now bigint;
  state_now text;
begin
  perform set_config(
    'app.user_id',
    '33000000-0000-0000-0000-000000000001',
    true
  );

  for step_no in 1..8 loop
    begin
      perform *
      from public._commit_revenue_import_batch(
        '33000000-0000-0000-0000-000000000134',
        'rv33-fault-'||step_no::text,
        'rv33-test',
        step_no
      );
      raise exception 'fault step % unexpectedly succeeded',step_no;
    exception when others then
      if sqlerrm not like 'FAULT_STEP_%' then
        raise;
      end if;
    end;

    select count(*) into rows_now
    from channel_source_fact
    where batch_id='33000000-0000-0000-0000-000000000134';

    select status::text into state_now
    from import_batch
    where id='33000000-0000-0000-0000-000000000134';

    if rows_now<>0 or state_now<>'ready' then
      raise exception
        'FAIL revenue rollback at step % -- facts %, state %',
        step_no,rows_now,state_now;
    end if;
  end loop;

  raise notice 'PASS Revenue commit rolls back atomically at all eight stages';
end
$$;


-- First-run layout confirmation is itself idempotent and records the fixed
-- period transform for a source that omits Period.
insert into source_file(
  id,organisation_id,outlet_id,template_code,
  storage_bucket,storage_path,original_filename,sha256,
  content_type,size_bytes,uploaded_by,detected_file_type,row_count,
  malware_scan_status,malware_scanner,malware_scanned_at,inspection_json
)
select
  '33000000-0000-0000-0000-000000000125',
  o.organisation_id,o.id,'T1B','uploads',
  'org/'||o.organisation_id::text||'/outlet/'||o.id::text||
    '/source/33000000-0000-0000-0000-000000000125/new-layout.csv',
  'new-layout.csv',repeat('e',64),'text/csv',100,
  '33000000-0000-0000-0000-000000000001',
  'csv',1,'clean','ci',now(),'{}'::jsonb
from outlet o where o.code='REV33';

insert into import_batch(
  id,organisation_id,outlet_id,source_file_id,template_code,
  period_id,scenario,status,detected_fingerprint,
  parse_completed_at,parse_metadata_json
)
select
  '33000000-0000-0000-0000-000000000135',
  sf.organisation_id,sf.outlet_id,sf.id,'T1B',
  '33000000-0000-0000-0000-000000000010',
  'actual','needs_mapping',repeat('e',64),now(),
  jsonb_build_object(
    'selected_sheet_name','Sheet1',
    'headers',jsonb_build_array('Meal_Period','Units','Unit_Basis','Revenue'),
    'field_map',jsonb_build_object(
      'Meal_Period','business_view_key',
      'Units','activity_units',
      'Unit_Basis','activity_unit_type',
      'Revenue','revenue'
    ),
    'target_period','2026-07',
    'fingerprint_components',jsonb_build_object(
      'sheet_name','Sheet1',
      'ordered_headers',jsonb_build_array(
        'meal period','units','unit basis','revenue'
      ),
      'header_row',1,
      'orientation','row',
      'key_set_hash',repeat('f',64),
      'column_count',4,
      'template_code','T1B',
      'source_keys',jsonb_build_array('brunch')
    )
  )
from source_file sf
where sf.id='33000000-0000-0000-0000-000000000125';

insert into staging_row(
  organisation_id,outlet_id,batch_id,source_row_no,
  raw_jsonb,parsed_jsonb,row_status
)
select organisation_id,outlet_id,id,2,
  '{"Meal_Period":"Brunch","Units":"1","Unit_Basis":"covers","Revenue":"10"}',
  '{"period":"2026-07","business_view_type":"meal_period","business_view_key":"Brunch","activity_units":"1","activity_unit_type":"covers","revenue":"10"}',
  'parsed'
from import_batch
where id='33000000-0000-0000-0000-000000000135';

set role restaurant_app;
select set_config('app.user_id','33000000-0000-0000-0000-000000000001',true);

select * from confirm_revenue_mapping(
  '33000000-0000-0000-0000-000000000135',
  'rv33-profile-confirm',
  'New Meal Layout',
  null,
  'rv33-test'
);

select rv33_text(
  (
    select transform_config_json->0->>'code'
    from profile_version
    where id=(
      select profile_version_id
      from import_batch
      where id='33000000-0000-0000-0000-000000000135'
    )
  ),
  'fixed_value',
  'T1B first-run profile freezes missing Period as fixed-value transform'
);
select rv33_true(
  (
    select reused
    from confirm_revenue_mapping(
      '33000000-0000-0000-0000-000000000135',
      'rv33-profile-confirm',
      'New Meal Layout',
      null,
      'rv33-test'
    )
  ),
  'Revenue profile confirmation is idempotent'
);

reset role;

rollback;
