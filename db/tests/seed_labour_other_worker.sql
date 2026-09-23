\set ON_ERROR_STOP on

insert into neon_auth."user"(id,name,email,"emailVerified")
values (
  '77000000-0000-0000-0000-000000000001',
  'Labour Worker Admin',
  'labour-worker@example.com',
  false
);

set role restaurant_app;
select set_config('app.user_id','77000000-0000-0000-0000-000000000001',false);

select * from bootstrap_organisation(
  'Labour Worker Org','labour-worker-org',
  'Labour Worker Outlet','LBWORKER',
  'USD'::char(3),'UTC',1::smallint,
  'labour-worker-bootstrap','labour-worker-ci'
);

insert into reporting_period(
  id,organisation_id,outlet_id,period_start,period_end,label
)
select
  '77000000-0000-0000-0000-000000000010',
  organisation_id,id,'2026-07-01','2026-07-31','July 2026'
from outlet where code='LBWORKER';

reset role;


insert into source_profile(
  id,organisation_id,outlet_id,template_code,source_label
)
select v.id,o.organisation_id,o.id,v.template_code,v.source_label
from outlet o
cross join (values
  ('77000000-0000-0000-0000-000000000101'::uuid,'T1','Labour accounting actual'),
  ('77000000-0000-0000-0000-000000000102'::uuid,'T6','Labour accounting budget'),
  ('77000000-0000-0000-0000-000000000103'::uuid,'T5','Labour detail')
) v(id,template_code,source_label)
where o.code='LBWORKER';

insert into profile_version(
  id,organisation_id,outlet_id,source_profile_id,version_no,
  layout_json,fingerprint_hash,fingerprint_components_json,transform_config_json
)
select
  v.profile_id,sp.organisation_id,sp.outlet_id,sp.id,1,
  '{}'::jsonb,v.hash,'{}'::jsonb,'[]'::jsonb
from source_profile sp
join (values
  ('77000000-0000-0000-0000-000000000101'::uuid,'77000000-0000-0000-0000-000000000111'::uuid,repeat('1',64)),
  ('77000000-0000-0000-0000-000000000102'::uuid,'77000000-0000-0000-0000-000000000112'::uuid,repeat('2',64)),
  ('77000000-0000-0000-0000-000000000103'::uuid,'77000000-0000-0000-0000-000000000113'::uuid,repeat('3',64))
) v(source_id,profile_id,hash)
  on v.source_id=sp.id;

update profile_version
set status='approved',
    approved_by='77000000-0000-0000-0000-000000000001',
    approved_at=now()
where id in (
  '77000000-0000-0000-0000-000000000111',
  '77000000-0000-0000-0000-000000000112',
  '77000000-0000-0000-0000-000000000113'
);

update source_profile sp
set active_profile_version_id=pv.id
from profile_version pv
where pv.source_profile_id=sp.id
  and sp.id in (
    '77000000-0000-0000-0000-000000000101',
    '77000000-0000-0000-0000-000000000102',
    '77000000-0000-0000-0000-000000000103'
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
  '77000000-0000-0000-0000-000000000001',
  'csv',v.row_count,'clean','ci',now(),'{}'::jsonb
from outlet o
cross join (values
  ('77000000-0000-0000-0000-000000000121'::uuid,'T1',repeat('a',64),4),
  ('77000000-0000-0000-0000-000000000122'::uuid,'T6',repeat('b',64),4),
  ('77000000-0000-0000-0000-000000000123'::uuid,'T5',repeat('c',64),5)
) v(id,template_code,hash,row_count)
where o.code='LBWORKER';

insert into import_batch(
  id,organisation_id,outlet_id,source_file_id,template_code,
  profile_version_id,period_id,scenario,status,detected_fingerprint
)
select
  v.batch_id,sf.organisation_id,sf.outlet_id,sf.id,sf.template_code,
  v.profile_id,'77000000-0000-0000-0000-000000000010',
  v.scenario::scenario_code,'ready',v.fingerprint
from source_file sf
join (values
  ('77000000-0000-0000-0000-000000000121'::uuid,'77000000-0000-0000-0000-000000000131'::uuid,'77000000-0000-0000-0000-000000000111'::uuid,'actual',repeat('1',64)),
  ('77000000-0000-0000-0000-000000000122'::uuid,'77000000-0000-0000-0000-000000000132'::uuid,'77000000-0000-0000-0000-000000000112'::uuid,'budget',repeat('2',64)),
  ('77000000-0000-0000-0000-000000000123'::uuid,'77000000-0000-0000-0000-000000000133'::uuid,'77000000-0000-0000-0000-000000000113'::uuid,'actual',repeat('3',64))
) v(source_id,batch_id,profile_id,scenario,fingerprint)
  on v.source_id=sf.id;


create temporary table lb_worker_pl(
  row_no int,
  account_code text,
  account_name text,
  ladder_code text,
  actual_amount numeric,
  budget_amount numeric
);

insert into lb_worker_pl values
  (2,'6000','Direct Labour','DIRECT_LABOUR',84317,79112),
  (3,'6100','Other Direct Operating','OTHER_DIRECT_OPERATING',2500,2300),
  (4,'7000','Shared Restaurant Cost','SHARED_RESTAURANT_COST',14252,12160),
  (5,'8000','Owner Structural Cost','OWNER_STRUCTURAL_COST',26000,26000);

insert into account(
  organisation_id,outlet_id,account_code,account_name
)
select o.organisation_id,o.id,p.account_code,p.account_name
from outlet o cross join lb_worker_pl p
where o.code='LBWORKER';

insert into staging_row(
  organisation_id,outlet_id,batch_id,source_row_no,
  raw_jsonb,parsed_jsonb,row_status
)
select
  b.organisation_id,b.outlet_id,b.id,p.row_no,
  jsonb_build_object(
    'Account_Code',p.account_code,
    'Account_Name',p.account_name,
    'Amount',p.actual_amount
  ),
  jsonb_build_object(
    'period','2026-07',
    'account_code',p.account_code,
    'account_name',p.account_name,
    'amount',p.actual_amount::text
  ),
  'parsed'
from import_batch b cross join lb_worker_pl p
where b.id='77000000-0000-0000-0000-000000000131';

insert into financial_fact(
  organisation_id,outlet_id,period_id,scenario,
  account_id,ladder_line_id,amount,currency_code,
  batch_id,profile_version_id,staging_row_id
)
select
  b.organisation_id,b.outlet_id,b.period_id,'actual',
  a.id,ll.id,p.actual_amount,'USD',
  b.id,b.profile_version_id,s.id
from import_batch b
cross join lb_worker_pl p
join account a
  on a.organisation_id=b.organisation_id
 and a.outlet_id=b.outlet_id
 and a.account_code=p.account_code
join ladder_line ll on ll.code=p.ladder_code
join staging_row s
  on s.batch_id=b.id and s.source_row_no=p.row_no
where b.id='77000000-0000-0000-0000-000000000131';


insert into staging_row(
  organisation_id,outlet_id,batch_id,source_row_no,
  raw_jsonb,parsed_jsonb,row_status
)
select
  b.organisation_id,b.outlet_id,b.id,p.row_no,
  jsonb_build_object(
    'Management_Line',p.ladder_code,
    'Amount',p.budget_amount
  ),
  jsonb_build_object(
    'period','2026-07',
    'management_line',p.ladder_code,
    'amount',p.budget_amount::text
  ),
  'parsed'
from import_batch b cross join lb_worker_pl p
where b.id='77000000-0000-0000-0000-000000000132';

insert into financial_fact(
  organisation_id,outlet_id,period_id,scenario,
  account_id,ladder_line_id,amount,currency_code,
  batch_id,profile_version_id,staging_row_id
)
select
  b.organisation_id,b.outlet_id,b.period_id,'budget',
  null,ll.id,p.budget_amount,'USD',
  b.id,b.profile_version_id,s.id
from import_batch b
cross join lb_worker_pl p
join ladder_line ll on ll.code=p.ladder_code
join staging_row s
  on s.batch_id=b.id and s.source_row_no=p.row_no
where b.id='77000000-0000-0000-0000-000000000132';


insert into staging_row(
  organisation_id,outlet_id,batch_id,source_row_no,
  raw_jsonb,parsed_jsonb,row_status
)
select
  b.organisation_id,b.outlet_id,b.id,v.row_no,
  jsonb_build_object(
    'Area',v.role_group,
    'Paid_Hours',v.actual_hours,
    'Budget_Hours',v.comparator_hours,
    'Overtime_Hours',v.overtime_hours,
    'Labour_Cost',v.actual_cost,
    'Budget_Labour_Cost',v.comparator_cost,
    'Covers_or_Orders',v.activity_units
  ),
  jsonb_build_object(
    'period','2026-07',
    'role_group',v.role_group,
    'actual_hours',v.actual_hours::text,
    'comparator_hours',v.comparator_hours::text,
    'overtime_hours',v.overtime_hours::text,
    'actual_cost',v.actual_cost::text,
    'comparator_cost',v.comparator_cost::text,
    'activity_units',v.activity_units::text,
    'activity_basis',v.activity_basis,
    'comparator_scenario','budget'
  ),
  'parsed'
from import_batch b
cross join (values
  (2,'Dinner FOH',1100::numeric,1030::numeric,100::numeric,27000::numeric,24850::numeric,2390::numeric,'dinner_covers'),
  (3,'Kitchen prep',800::numeric,730::numeric,40::numeric,20500::numeric,18300::numeric,5650::numeric,'total_covers'),
  (4,'Lunch FOH',750::numeric,720::numeric,20::numeric,17400::numeric,16500::numeric,1480::numeric,'lunch_covers'),
  (5,'Bar',400::numeric,390::numeric,30::numeric,9600::numeric,9300::numeric,3090::numeric,'brunch_plus_dinner_covers'),
  (6,'Management / shared',430::numeric,410::numeric,30::numeric,9817::numeric,10162::numeric,5650::numeric,'total_covers')
) v(
  row_no,role_group,actual_hours,comparator_hours,overtime_hours,
  actual_cost,comparator_cost,activity_units,activity_basis
)
where b.id='77000000-0000-0000-0000-000000000133';

insert into labour_fact(
  organisation_id,outlet_id,period_id,role_group,
  actual_hours,comparator_hours,actual_cost,comparator_cost,
  scheduled_hours,overtime_hours,activity_units,activity_basis,
  comparator_scenario,notes,
  batch_id,profile_version_id,staging_row_id
)
select
  b.organisation_id,b.outlet_id,b.period_id,
  s.parsed_jsonb->>'role_group',
  (s.parsed_jsonb->>'actual_hours')::numeric,
  (s.parsed_jsonb->>'comparator_hours')::numeric,
  (s.parsed_jsonb->>'actual_cost')::numeric,
  (s.parsed_jsonb->>'comparator_cost')::numeric,
  null,
  (s.parsed_jsonb->>'overtime_hours')::numeric,
  (s.parsed_jsonb->>'activity_units')::numeric,
  s.parsed_jsonb->>'activity_basis',
  'budget',
  null,
  b.id,b.profile_version_id,s.id
from import_batch b
join staging_row s on s.batch_id=b.id
where b.id='77000000-0000-0000-0000-000000000133';


update import_batch
set status='committed',
    committed_by='77000000-0000-0000-0000-000000000001',
    committed_at=now(),
    canonical_commit_hash=repeat('4',64),
    canonical_commit_summary='{"fact_count":4}'
where id='77000000-0000-0000-0000-000000000131';

update import_batch
set status='committed',
    committed_by='77000000-0000-0000-0000-000000000001',
    committed_at=now(),
    canonical_commit_hash=repeat('5',64),
    canonical_commit_summary='{"fact_count":4}'
where id='77000000-0000-0000-0000-000000000132';

update import_batch
set status='committed',
    committed_by='77000000-0000-0000-0000-000000000001',
    committed_at=now(),
    canonical_commit_hash=repeat('6',64),
    canonical_commit_summary='{
      "fact_count":5,
      "actual_cost_total":84317,
      "comparator_cost_total":79112,
      "activity_unit_rollup":"PROHIBITED_ACROSS_ROLE_GROUPS"
    }'
where id='77000000-0000-0000-0000-000000000133';


insert into data_readiness(
  organisation_id,outlet_id,period_id,capability_code,status,
  latest_batch_id,details_json
)
select
  organisation_id,outlet_id,period_id,
  'labour_inputs','ready',id,
  '{
    "t5_committed":true,
    "pnl_direct_labour":84317,
    "t5_actual_labour_cost":84317,
    "actual_pnl_relative_difference":0,
    "comparator_scenario":"budget",
    "pnl_comparator_direct_labour":79112,
    "t5_comparator_labour_cost":79112,
    "comparator_pnl_relative_difference":0,
    "actual_pnl_tie":true,
    "comparator_pnl_tie":true,
    "tolerance_ratio":0.005,
    "activity_unit_rollup":"PROHIBITED_ACROSS_ROLE_GROUPS"
  }'::jsonb
from import_batch
where id='77000000-0000-0000-0000-000000000133';


insert into calculation_request_queue(
  id,organisation_id,outlet_id,period_id,source_batch_id,reason,status,created_at
)
select
  '77000000-0000-0000-0000-000000000401',
  organisation_id,outlet_id,period_id,id,
  'labour_other_ci_first','pending',clock_timestamp()
from import_batch
where id='77000000-0000-0000-0000-000000000133';

insert into calculation_request_queue(
  id,organisation_id,outlet_id,period_id,source_batch_id,reason,status,created_at
)
select
  '77000000-0000-0000-0000-000000000402',
  organisation_id,outlet_id,period_id,id,
  'labour_other_ci_repeat','pending',clock_timestamp()+interval '1 millisecond'
from import_batch
where id='77000000-0000-0000-0000-000000000133';
