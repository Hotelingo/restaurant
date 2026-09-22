\set ON_ERROR_STOP on
begin;

create or replace function lb35_eq(actual bigint, expected bigint, label text)
returns void language plpgsql as $$
begin
  if actual is distinct from expected then
    raise exception 'FAIL % -- expected %, got %',label,expected,actual;
  end if;
  raise notice 'PASS %',label;
end $$;

create or replace function lb35_num(actual numeric, expected numeric, label text)
returns void language plpgsql as $$
begin
  if actual is distinct from expected then
    raise exception 'FAIL % -- expected %, got %',label,expected,actual;
  end if;
  raise notice 'PASS %',label;
end $$;

create or replace function lb35_text(actual text, expected text, label text)
returns void language plpgsql as $$
begin
  if actual is distinct from expected then
    raise exception 'FAIL % -- expected %, got %',label,expected,actual;
  end if;
  raise notice 'PASS %',label;
end $$;

create or replace function lb35_true(actual boolean, label text)
returns void language plpgsql as $$
begin
  if not coalesce(actual,false) then
    raise exception 'FAIL %',label;
  end if;
  raise notice 'PASS %',label;
end $$;

create or replace function lb35_rejects(stmt text, label text)
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
  '75000000-0000-0000-0000-000000000001',
  'Labour Admin',
  'labour-admin@example.com',
  false
);

set role restaurant_app;
select set_config('app.user_id','75000000-0000-0000-0000-000000000001',true);

select * from bootstrap_organisation(
  'Labour Org','labour-org',
  'Labour Outlet','LAB35',
  'USD'::char(3),'UTC',1::smallint,
  'lb35-bootstrap','lb35-test'
);

insert into reporting_period(
  id,organisation_id,outlet_id,period_start,period_end,label
)
select
  '75000000-0000-0000-0000-000000000010',
  organisation_id,id,'2026-07-01','2026-07-31','July 2026'
from outlet where code='LAB35';

insert into reporting_period(
  id,organisation_id,outlet_id,period_start,period_end,label
)
select
  '75000000-0000-0000-0000-000000000011',
  organisation_id,id,'2026-08-01','2026-08-31','August 2026'
from outlet where code='LAB35';

reset role;


-- Approved T1/T6/T5 profiles.
insert into source_profile(
  id,organisation_id,outlet_id,template_code,source_label
)
select v.id,o.organisation_id,o.id,v.template_code,v.label
from outlet o
cross join (values
  ('75000000-0000-0000-0000-000000000101'::uuid,'T1','Labour P&L'),
  ('75000000-0000-0000-0000-000000000102'::uuid,'T6','Labour Budget'),
  ('75000000-0000-0000-0000-000000000103'::uuid,'T5','Labour Detail')
) v(id,template_code,label)
where o.code='LAB35';

insert into profile_version(
  id,organisation_id,outlet_id,source_profile_id,version_no,
  layout_json,fingerprint_hash,fingerprint_components_json,transform_config_json
)
select
  v.profile_id,sp.organisation_id,sp.outlet_id,sp.id,1,
  '{}'::jsonb,v.hash,'{}'::jsonb,'[]'::jsonb
from source_profile sp
join (values
  ('75000000-0000-0000-0000-000000000101'::uuid,'75000000-0000-0000-0000-000000000111'::uuid,repeat('1',64)),
  ('75000000-0000-0000-0000-000000000102'::uuid,'75000000-0000-0000-0000-000000000112'::uuid,repeat('2',64)),
  ('75000000-0000-0000-0000-000000000103'::uuid,'75000000-0000-0000-0000-000000000113'::uuid,repeat('3',64))
) v(source_id,profile_id,hash)
  on v.source_id=sp.id;

-- Amberside's Covers_or_Orders has no semantic basis column. Freeze the
-- required role-group basis explicitly in the approved T5 profile.
insert into value_mapping(
  organisation_id,outlet_id,profile_version_id,
  field_name,source_value,canonical_value
)
select
  pv.organisation_id,pv.outlet_id,pv.id,
  'labour_activity_basis',v.role_group,v.activity_basis
from profile_version pv
cross join (values
  ('Dinner FOH','dinner_covers'),
  ('Kitchen prep','total_covers'),
  ('Lunch FOH','lunch_covers'),
  ('Bar','brunch_plus_dinner_covers'),
  ('Management / shared','total_covers')
) v(role_group,activity_basis)
where pv.id='75000000-0000-0000-0000-000000000113';

update profile_version
set status='approved',
    approved_by='75000000-0000-0000-0000-000000000001',
    approved_at=now()
where id in (
  '75000000-0000-0000-0000-000000000111',
  '75000000-0000-0000-0000-000000000112',
  '75000000-0000-0000-0000-000000000113'
);

update source_profile sp
set active_profile_version_id=pv.id
from profile_version pv
where pv.source_profile_id=sp.id
  and sp.id in (
    '75000000-0000-0000-0000-000000000101',
    '75000000-0000-0000-0000-000000000102',
    '75000000-0000-0000-0000-000000000103'
  );


-- July source files and batches.
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
  '75000000-0000-0000-0000-000000000001',
  'csv',v.rows,'clean','ci',now(),'{}'::jsonb
from outlet o
cross join (values
  ('75000000-0000-0000-0000-000000000121'::uuid,'T1',repeat('a',64),1),
  ('75000000-0000-0000-0000-000000000122'::uuid,'T6',repeat('b',64),1),
  ('75000000-0000-0000-0000-000000000123'::uuid,'T5',repeat('c',64),5)
) v(id,template_code,hash,rows)
where o.code='LAB35';

insert into import_batch(
  id,organisation_id,outlet_id,source_file_id,template_code,
  profile_version_id,period_id,scenario,status,detected_fingerprint
)
select
  v.batch_id,sf.organisation_id,sf.outlet_id,sf.id,sf.template_code,
  v.profile_id,'75000000-0000-0000-0000-000000000010',
  v.scenario::scenario_code,'ready',v.fingerprint
from source_file sf
join (values
  ('75000000-0000-0000-0000-000000000121'::uuid,'75000000-0000-0000-0000-000000000131'::uuid,'75000000-0000-0000-0000-000000000111'::uuid,'actual',repeat('1',64)),
  ('75000000-0000-0000-0000-000000000122'::uuid,'75000000-0000-0000-0000-000000000132'::uuid,'75000000-0000-0000-0000-000000000112'::uuid,'budget',repeat('2',64)),
  ('75000000-0000-0000-0000-000000000123'::uuid,'75000000-0000-0000-0000-000000000133'::uuid,'75000000-0000-0000-0000-000000000113'::uuid,'actual',repeat('3',64))
) v(source_id,batch_id,profile_id,scenario,fingerprint)
  on v.source_id=sf.id;


-- T1 Direct Labour accounting anchor.
insert into account(
  id,organisation_id,outlet_id,account_code,account_name
)
select
  '75000000-0000-0000-0000-000000000201',
  organisation_id,id,'6000','Payroll, restaurant'
from outlet where code='LAB35';

insert into staging_row(
  id,organisation_id,outlet_id,batch_id,source_row_no,
  raw_jsonb,parsed_jsonb,row_status
)
select
  '75000000-0000-0000-0000-000000000211',
  organisation_id,outlet_id,id,2,
  '{"Account_Code":"6000","Account_Name":"Payroll, restaurant","July_2026":"84317"}',
  '{"period":"2026-07","account_code":"6000","account_name":"Payroll, restaurant","amount":"84317"}',
  'parsed'
from import_batch
where id='75000000-0000-0000-0000-000000000131';

insert into financial_fact(
  organisation_id,outlet_id,period_id,scenario,
  account_id,ladder_line_id,amount,currency_code,
  batch_id,profile_version_id,staging_row_id
)
select
  b.organisation_id,b.outlet_id,b.period_id,'actual',
  '75000000-0000-0000-0000-000000000201',
  ll.id,84317,'USD',b.id,b.profile_version_id,
  '75000000-0000-0000-0000-000000000211'
from import_batch b
join ladder_line ll on ll.code='DIRECT_LABOUR'
where b.id='75000000-0000-0000-0000-000000000131';

update import_batch
set status='committed',
    committed_by='75000000-0000-0000-0000-000000000001',
    committed_at=now(),
    canonical_commit_hash=repeat('4',64),
    canonical_commit_summary='{"fact_count":1}'
where id='75000000-0000-0000-0000-000000000131';


-- T6 budget Direct Labour comparator at ladder grain.
insert into staging_row(
  id,organisation_id,outlet_id,batch_id,source_row_no,
  raw_jsonb,parsed_jsonb,row_status
)
select
  '75000000-0000-0000-0000-000000000212',
  organisation_id,outlet_id,id,2,
  '{"Management_Line":"Direct Labour","Budget_July_2026":"79112"}',
  '{"period":"2026-07","management_line":"Direct Labour","amount":"79112"}',
  'parsed'
from import_batch
where id='75000000-0000-0000-0000-000000000132';

insert into financial_fact(
  organisation_id,outlet_id,period_id,scenario,
  account_id,ladder_line_id,amount,currency_code,
  batch_id,profile_version_id,staging_row_id
)
select
  b.organisation_id,b.outlet_id,b.period_id,'budget',
  null,ll.id,79112,'USD',b.id,b.profile_version_id,
  '75000000-0000-0000-0000-000000000212'
from import_batch b
join ladder_line ll on ll.code='DIRECT_LABOUR'
where b.id='75000000-0000-0000-0000-000000000132';

update import_batch
set status='committed',
    committed_by='75000000-0000-0000-0000-000000000001',
    committed_at=now(),
    canonical_commit_hash=repeat('5',64),
    canonical_commit_summary='{"fact_count":1}'
where id='75000000-0000-0000-0000-000000000132';


-- Amberside T5 staging deliberately omits activity_basis. Approved profile
-- mappings must supply it; no inference from 2,390 / 5,650 / 1,480 / 3,090.
insert into staging_row(
  organisation_id,outlet_id,batch_id,source_row_no,
  raw_jsonb,parsed_jsonb,row_status
)
select
  b.organisation_id,b.outlet_id,b.id,v.row_no,
  jsonb_build_object(
    'Area',v.role_group,'Paid_Hours',v.actual_hours,
    'Budget_Hours',v.comparator_hours,'Overtime_Hours',v.overtime_hours,
    'Labour_Cost',v.actual_cost,'Budget_Labour_Cost',v.comparator_cost,
    'Covers_or_Orders',v.activity_units
  ),
  jsonb_build_object(
    'period','2026-07','role_group',v.role_group,
    'actual_hours',v.actual_hours::text,
    'comparator_hours',v.comparator_hours::text,
    'overtime_hours',v.overtime_hours::text,
    'actual_cost',v.actual_cost::text,
    'comparator_cost',v.comparator_cost::text,
    'activity_units',v.activity_units::text,
    'comparator_scenario','budget'
  ),
  'parsed'
from import_batch b
cross join (values
  (2,'Dinner FOH',1100::numeric,1030::numeric,100::numeric,27000::numeric,24850::numeric,2390::numeric),
  (3,'Kitchen prep',800::numeric,730::numeric,40::numeric,20500::numeric,18300::numeric,5650::numeric),
  (4,'Lunch FOH',750::numeric,720::numeric,20::numeric,17400::numeric,16500::numeric,1480::numeric),
  (5,'Bar',400::numeric,390::numeric,30::numeric,9600::numeric,9300::numeric,3090::numeric),
  (6,'Management / shared',430::numeric,410::numeric,30::numeric,9817::numeric,10162::numeric,5650::numeric)
) v(row_no,role_group,actual_hours,comparator_hours,overtime_hours,actual_cost,comparator_cost,activity_units)
where b.id='75000000-0000-0000-0000-000000000133';


set role restaurant_app;
select set_config('app.user_id','75000000-0000-0000-0000-000000000001',true);

select * from commit_labour_import_batch(
  '75000000-0000-0000-0000-000000000133',
  'lb35-t5-commit',
  'lb35-test',
  false
);

select lb35_eq(
  (select count(*) from labour_fact
   where batch_id='75000000-0000-0000-0000-000000000133'),
  5,
  'T5 commits five immutable role-group facts'
);
select lb35_num(
  (select sum(actual_cost) from labour_fact
   where batch_id='75000000-0000-0000-0000-000000000133'),
  84317,
  'T5 actual Labour Cost ties to T1 Direct Labour'
);
select lb35_num(
  (select sum(comparator_cost) from labour_fact
   where batch_id='75000000-0000-0000-0000-000000000133'),
  79112,
  'T5 comparator Labour Cost ties to T6 Direct Labour'
);
select lb35_num(
  (select sum(actual_hours) from labour_fact
   where batch_id='75000000-0000-0000-0000-000000000133'),
  3480,
  'T5 actual paid hours preserve role-group sum'
);
select lb35_num(
  (select sum(comparator_hours) from labour_fact
   where batch_id='75000000-0000-0000-0000-000000000133'),
  3280,
  'T5 comparator hours preserve role-group sum'
);

select lb35_text(
  (select activity_basis from labour_fact
   where batch_id='75000000-0000-0000-0000-000000000133'
     and role_group='Kitchen prep'),
  'total_covers',
  'Kitchen prep receives approved total-covers basis'
);
select lb35_text(
  (select activity_basis from labour_fact
   where batch_id='75000000-0000-0000-0000-000000000133'
     and role_group='Management / shared'),
  'total_covers',
  'Management/shared receives same approved total-covers basis'
);
select lb35_num(
  (select activity_units from labour_fact
   where batch_id='75000000-0000-0000-0000-000000000133'
     and role_group='Kitchen prep'),
  5650,
  'Kitchen prep retains 5650 contextual units'
);
select lb35_num(
  (select activity_units from labour_fact
   where batch_id='75000000-0000-0000-0000-000000000133'
     and role_group='Management / shared'),
  5650,
  'Management/shared retains repeated 5650 contextual units'
);

select lb35_text(
  (select status from data_readiness
   where outlet_id=(select id from outlet where code='LAB35')
     and period_id='75000000-0000-0000-0000-000000000010'
     and capability_code='labour_inputs'),
  'ready',
  'Labour readiness is ready after both accounting tie-outs'
);
select lb35_true(
  (select
     (details_json->>'actual_pnl_tie')::boolean
     and (details_json->>'comparator_pnl_tie')::boolean
     and details_json->>'activity_unit_rollup'='PROHIBITED_ACROSS_ROLE_GROUPS'
   from data_readiness
   where outlet_id=(select id from outlet where code='LAB35')
     and period_id='75000000-0000-0000-0000-000000000010'
     and capability_code='labour_inputs'),
  'Labour readiness discloses both tie-outs and non-additive activity rule'
);

select lb35_true(
  (select reused from commit_labour_import_batch(
    '75000000-0000-0000-0000-000000000133',
    'lb35-t5-commit',
    'lb35-test',
    false
  )),
  'T5 canonical commit is idempotent'
);
select lb35_eq(
  (select count(*) from labour_fact
   where batch_id='75000000-0000-0000-0000-000000000133'),
  5,
  'T5 retry creates no duplicate facts'
);

select lb35_eq(
  (
    select count(*)
    from labour_fact f
    join staging_row s
      on s.id=f.staging_row_id and s.batch_id=f.batch_id
    join import_batch b on b.id=f.batch_id
    join source_file sf on sf.id=b.source_file_id
    where f.batch_id='75000000-0000-0000-0000-000000000133'
      and b.canonical_commit_hash is not null
      and sf.sha256 ~ '^[0-9a-f]{64}$'
  ),
  5,
  'T5 facts retain staging/batch/source-file lineage'
);

select lb35_rejects(
  $q$ update labour_fact set actual_cost=0
      where batch_id='75000000-0000-0000-0000-000000000133' $q$,
  'committed T5 facts are immutable/read-only to app role'
);

reset role;


-- Fault-injection batch in August: otherwise valid T5, same approved basis
-- profile, no competing committed T5 scope.
insert into source_file(
  id,organisation_id,outlet_id,template_code,
  storage_bucket,storage_path,original_filename,sha256,
  content_type,size_bytes,uploaded_by,detected_file_type,row_count,
  malware_scan_status,malware_scanner,malware_scanned_at,inspection_json
)
select
  '75000000-0000-0000-0000-000000000124',
  o.organisation_id,o.id,'T5','uploads',
  'org/'||o.organisation_id::text||'/outlet/'||o.id::text||
    '/source/75000000-0000-0000-0000-000000000124/fault-t5.csv',
  'fault-t5.csv',repeat('d',64),'text/csv',100,
  '75000000-0000-0000-0000-000000000001',
  'csv',1,'clean','ci',now(),'{}'::jsonb
from outlet o where o.code='LAB35';

insert into import_batch(
  id,organisation_id,outlet_id,source_file_id,template_code,
  profile_version_id,period_id,scenario,status,detected_fingerprint
)
select
  '75000000-0000-0000-0000-000000000134',
  sf.organisation_id,sf.outlet_id,sf.id,'T5',
  '75000000-0000-0000-0000-000000000113',
  '75000000-0000-0000-0000-000000000011',
  'actual','ready',repeat('3',64)
from source_file sf
where sf.id='75000000-0000-0000-0000-000000000124';

insert into staging_row(
  organisation_id,outlet_id,batch_id,source_row_no,
  raw_jsonb,parsed_jsonb,row_status
)
select organisation_id,outlet_id,id,2,
  '{"Area":"Dinner FOH","Paid_Hours":"10","Labour_Cost":"200","Covers_or_Orders":"20"}',
  '{"period":"2026-08","role_group":"Dinner FOH","actual_hours":"10","actual_cost":"200","activity_units":"20"}',
  'parsed'
from import_batch
where id='75000000-0000-0000-0000-000000000134';

do $$
declare
  step_no int;
  rows_now bigint;
  state_now text;
begin
  perform set_config(
    'app.user_id',
    '75000000-0000-0000-0000-000000000001',
    true
  );

  for step_no in 1..8 loop
    begin
      perform *
      from public._commit_labour_import_batch(
        '75000000-0000-0000-0000-000000000134',
        'lb35-fault-'||step_no::text,
        'lb35-test',
        step_no
      );
      raise exception 'fault step % unexpectedly succeeded',step_no;
    exception when others then
      if sqlerrm not like 'FAULT_STEP_%' then
        raise;
      end if;
    end;

    select count(*) into rows_now
    from labour_fact
    where batch_id='75000000-0000-0000-0000-000000000134';

    select status::text into state_now
    from import_batch
    where id='75000000-0000-0000-0000-000000000134';

    if rows_now<>0 or state_now<>'ready' then
      raise exception
        'FAIL Labour rollback at step % -- facts %, state %',
        step_no,rows_now,state_now;
    end if;
  end loop;

  raise notice 'PASS Labour commit rolls back atomically at all eight stages';
end
$$;


-- The canonical table itself refuses activity units without a semantic basis.
select lb35_rejects(
  $q$
    insert into labour_fact(
      organisation_id,outlet_id,period_id,role_group,
      actual_hours,actual_cost,activity_units,activity_basis,
      batch_id,profile_version_id,staging_row_id
    )
    select
      b.organisation_id,b.outlet_id,b.period_id,'Forged',1,1,10,null,
      b.id,b.profile_version_id,s.id
    from import_batch b
    join staging_row s on s.batch_id=b.id
    where b.id='75000000-0000-0000-0000-000000000134'
    limit 1
  $q$,
  'database rejects activity units without activity basis'
);

rollback;
