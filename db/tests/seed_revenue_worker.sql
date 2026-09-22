\set ON_ERROR_STOP on

insert into neon_auth."user"(id,name,email,"emailVerified")
values ('66000000-0000-0000-0000-000000000001','Revenue Worker Admin','revenue-worker@example.com',false);

set role restaurant_app;
select set_config('app.user_id','66000000-0000-0000-0000-000000000001',false);

select * from bootstrap_organisation(
  'Revenue Worker Org','revenue-worker-org','Revenue Worker Outlet','RVWORKER',
  'USD'::char(3),'UTC',1::smallint,'revenue-worker-bootstrap','revenue-worker-ci'
);

insert into reporting_period(
  id,organisation_id,outlet_id,period_start,period_end,label
)
select
  '66000000-0000-0000-0000-000000000010',
  organisation_id,id,'2026-07-01','2026-07-31','July 2026'
from outlet where code='RVWORKER';

reset role;

insert into source_profile(
  id,organisation_id,outlet_id,template_code,source_label
)
select v.id,o.organisation_id,o.id,v.template_code,v.source_label
from outlet o
cross join (values
  ('66000000-0000-0000-0000-000000000101'::uuid,'T1','Revenue accounting'),
  ('66000000-0000-0000-0000-000000000102'::uuid,'T1B','Revenue activity'),
  ('66000000-0000-0000-0000-000000000103'::uuid,'T7','Revenue source')
) v(id,template_code,source_label)
where o.code='RVWORKER';

insert into profile_version(
  id,organisation_id,outlet_id,source_profile_id,version_no,
  layout_json,fingerprint_hash,fingerprint_components_json,transform_config_json
)
select
  v.profile_id,sp.organisation_id,sp.outlet_id,sp.id,1,
  '{}'::jsonb,v.hash,'{}'::jsonb,'[]'::jsonb
from source_profile sp
join (values
  ('66000000-0000-0000-0000-000000000101'::uuid,'66000000-0000-0000-0000-000000000111'::uuid,repeat('1',64)),
  ('66000000-0000-0000-0000-000000000102'::uuid,'66000000-0000-0000-0000-000000000112'::uuid,repeat('2',64)),
  ('66000000-0000-0000-0000-000000000103'::uuid,'66000000-0000-0000-0000-000000000113'::uuid,repeat('3',64))
) v(source_id,profile_id,hash)
  on v.source_id=sp.id;

update profile_version
set status='approved',
    approved_by='66000000-0000-0000-0000-000000000001',
    approved_at=now()
where id in (
  '66000000-0000-0000-0000-000000000111',
  '66000000-0000-0000-0000-000000000112',
  '66000000-0000-0000-0000-000000000113'
);

update source_profile sp
set active_profile_version_id=pv.id
from profile_version pv
where pv.source_profile_id=sp.id
  and sp.id in (
    '66000000-0000-0000-0000-000000000101',
    '66000000-0000-0000-0000-000000000102',
    '66000000-0000-0000-0000-000000000103'
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
  '66000000-0000-0000-0000-000000000001',
  'csv',v.row_count,'clean','ci',now(),'{}'::jsonb
from outlet o
cross join (values
  ('66000000-0000-0000-0000-000000000121'::uuid,'T1',repeat('a',64),5),
  ('66000000-0000-0000-0000-000000000122'::uuid,'T1B',repeat('b',64),6),
  ('66000000-0000-0000-0000-000000000123'::uuid,'T7',repeat('c',64),9)
) v(id,template_code,hash,row_count)
where o.code='RVWORKER';

insert into import_batch(
  id,organisation_id,outlet_id,source_file_id,template_code,
  profile_version_id,period_id,scenario,status,detected_fingerprint
)
select
  v.batch_id,sf.organisation_id,sf.outlet_id,sf.id,sf.template_code,
  v.profile_id,'66000000-0000-0000-0000-000000000010',
  'actual','ready',v.fingerprint
from source_file sf
join (values
  ('66000000-0000-0000-0000-000000000121'::uuid,'66000000-0000-0000-0000-000000000131'::uuid,'66000000-0000-0000-0000-000000000111'::uuid,repeat('1',64)),
  ('66000000-0000-0000-0000-000000000122'::uuid,'66000000-0000-0000-0000-000000000132'::uuid,'66000000-0000-0000-0000-000000000112'::uuid,repeat('2',64)),
  ('66000000-0000-0000-0000-000000000123'::uuid,'66000000-0000-0000-0000-000000000133'::uuid,'66000000-0000-0000-0000-000000000113'::uuid,repeat('3',64))
) v(source_id,batch_id,profile_id,fingerprint)
  on v.source_id=sf.id;


-- T1 accounting facts needed for CT at outlet grain.
create temporary table rv_worker_pl(
  row_no int,account_code text,account_name text,ladder_code text,amount numeric
);
insert into rv_worker_pl values
  (2,'4000','Net Sales','NET_SALES',228500),
  (3,'5000','Product Cost','PRODUCT_COST',70282),
  (4,'5100','Channel Cost','CHANNEL_COST',3600),
  (5,'6000','Direct Labour','DIRECT_LABOUR',84317),
  (6,'6100','Other Direct Operating','OTHER_DIRECT_OPERATING',2500);

insert into account(
  organisation_id,outlet_id,account_code,account_name
)
select o.organisation_id,o.id,p.account_code,p.account_name
from outlet o cross join rv_worker_pl p
where o.code='RVWORKER';

insert into staging_row(
  organisation_id,outlet_id,batch_id,source_row_no,
  raw_jsonb,parsed_jsonb,row_status
)
select
  b.organisation_id,b.outlet_id,b.id,p.row_no,
  jsonb_build_object(
    'Account_Code',p.account_code,'Account_Name',p.account_name,'Amount',p.amount
  ),
  jsonb_build_object(
    'period','2026-07','account_code',p.account_code,
    'account_name',p.account_name,'amount',p.amount::text
  ),
  'parsed'
from import_batch b cross join rv_worker_pl p
where b.id='66000000-0000-0000-0000-000000000131';

insert into financial_fact(
  organisation_id,outlet_id,period_id,scenario,
  account_id,ladder_line_id,amount,currency_code,
  batch_id,profile_version_id,staging_row_id
)
select
  b.organisation_id,b.outlet_id,b.period_id,'actual',
  a.id,ll.id,p.amount,'USD',
  b.id,b.profile_version_id,s.id
from import_batch b
cross join rv_worker_pl p
join account a
  on a.organisation_id=b.organisation_id
 and a.outlet_id=b.outlet_id
 and a.account_code=p.account_code
join ladder_line ll on ll.code=p.ladder_code
join staging_row s
  on s.batch_id=b.id and s.source_row_no=p.row_no
where b.id='66000000-0000-0000-0000-000000000131';


-- Amberside T1B.
insert into staging_row(
  organisation_id,outlet_id,batch_id,source_row_no,
  raw_jsonb,parsed_jsonb,row_status
)
select
  b.organisation_id,b.outlet_id,b.id,v.row_no,'{}',
  jsonb_build_object(
    'period','2026-07',
    'business_view_type','meal_period',
    'business_view_key',v.view_key,
    'activity_unit_type',v.unit_type,
    'activity_units',v.actual_units::text,
    'revenue',v.actual_revenue::text,
    'comparator_activity_units',v.budget_units::text,
    'comparator_revenue',v.budget_revenue::text
  ),
  'parsed'
from import_batch b
cross join (values
  (2,'Brunch',700::numeric,'covers',25900::numeric,650::numeric,23400::numeric),
  (3,'Lunch',1480::numeric,'covers',45880::numeric,1650::numeric,51150::numeric),
  (4,'Dinner',2390::numeric,'covers',114720::numeric,2450::numeric,115150::numeric),
  (5,'Delivery / Takeaway',750::numeric,'orders',27000::numeric,700::numeric,25200::numeric),
  (6,'Private Event',240::numeric,'guests',12480::numeric,250::numeric,14000::numeric),
  (7,'Corporate / Group',90::numeric,'guests',2520::numeric,100::numeric,3100::numeric)
) v(row_no,view_key,actual_units,unit_type,actual_revenue,budget_units,budget_revenue)
where b.id='66000000-0000-0000-0000-000000000132';

insert into revenue_activity_fact(
  organisation_id,outlet_id,period_id,
  business_view_type,business_view_key,activity_unit_type,
  activity_units,revenue,comparator_activity_units,comparator_revenue,
  batch_id,profile_version_id,staging_row_id
)
select
  b.organisation_id,b.outlet_id,b.period_id,
  s.parsed_jsonb->>'business_view_type',
  s.parsed_jsonb->>'business_view_key',
  s.parsed_jsonb->>'activity_unit_type',
  (s.parsed_jsonb->>'activity_units')::numeric,
  (s.parsed_jsonb->>'revenue')::numeric,
  (s.parsed_jsonb->>'comparator_activity_units')::numeric,
  (s.parsed_jsonb->>'comparator_revenue')::numeric,
  b.id,b.profile_version_id,s.id
from import_batch b
join staging_row s on s.batch_id=b.id
where b.id='66000000-0000-0000-0000-000000000132';


-- Amberside T7 source/channel evidence; costs total 3,600.
insert into staging_row(
  organisation_id,outlet_id,batch_id,source_row_no,
  raw_jsonb,parsed_jsonb,row_status
)
select
  b.organisation_id,b.outlet_id,b.id,v.row_no,'{}',
  jsonb_build_object(
    'period','2026-07','source_channel',v.source_channel,
    'attributed_revenue',v.revenue::text,
    'direct_channel_cost',v.channel_cost::text,
    'source_evidence_status',v.evidence_status
  ),
  'parsed'
from import_batch b
cross join (values
  (2,'Direct / Walk-in',67000::numeric,0::numeric,'partly_supported'),
  (3,'Repeat',55000::numeric,0::numeric,'partly_supported'),
  (4,'Corporate / Local Office',15000::numeric,200::numeric,'supported'),
  (5,'Organic Digital',17000::numeric,250::numeric,'supported'),
  (6,'Paid Marketing',15500::numeric,1250::numeric,'supported'),
  (7,'Reservation Platform',13500::numeric,675::numeric,'supported'),
  (8,'Delivery Platform',23000::numeric,1000::numeric,'supported'),
  (9,'Event',8500::numeric,125::numeric,'supported'),
  (10,'Not attributed',14000::numeric,100::numeric,'evidence_required')
) v(row_no,source_channel,revenue,channel_cost,evidence_status)
where b.id='66000000-0000-0000-0000-000000000133';

insert into channel_source_fact(
  organisation_id,outlet_id,period_id,source_channel,
  attributed_revenue,direct_channel_cost,source_evidence_status,
  batch_id,profile_version_id,staging_row_id
)
select
  b.organisation_id,b.outlet_id,b.period_id,
  s.parsed_jsonb->>'source_channel',
  (s.parsed_jsonb->>'attributed_revenue')::numeric,
  (s.parsed_jsonb->>'direct_channel_cost')::numeric,
  s.parsed_jsonb->>'source_evidence_status',
  b.id,b.profile_version_id,s.id
from import_batch b
join staging_row s on s.batch_id=b.id
where b.id='66000000-0000-0000-0000-000000000133';


update import_batch
set status='committed',
    committed_by='66000000-0000-0000-0000-000000000001',
    committed_at=now(),
    canonical_commit_hash=repeat('4',64),
    canonical_commit_summary='{"fact_count":5}'
where id='66000000-0000-0000-0000-000000000131';

update import_batch
set status='committed',
    committed_by='66000000-0000-0000-0000-000000000001',
    committed_at=now(),
    canonical_commit_hash=repeat('5',64),
    canonical_commit_summary='{"fact_count":6}'
where id='66000000-0000-0000-0000-000000000132';

update import_batch
set status='committed',
    committed_by='66000000-0000-0000-0000-000000000001',
    committed_at=now(),
    canonical_commit_hash=repeat('6',64),
    canonical_commit_summary='{"fact_count":9}'
where id='66000000-0000-0000-0000-000000000133';

insert into data_readiness(
  organisation_id,outlet_id,period_id,capability_code,status,
  latest_batch_id,details_json
)
select
  organisation_id,outlet_id,period_id,'revenue_inputs','ready',id,
  '{
    "t1b_committed":true,
    "t7_committed":true,
    "pnl_net_sales":228500,
    "t1b_revenue_total":228500,
    "t7_attributed_revenue_total":228500,
    "t1b_pnl_relative_difference":0,
    "t7_pnl_relative_difference":0,
    "tolerance_ratio":0.005,
    "t1b_pnl_tie":true,
    "t7_pnl_tie":true
  }'::jsonb
from import_batch
where id='66000000-0000-0000-0000-000000000133';

insert into calculation_request_queue(
  id,organisation_id,outlet_id,period_id,source_batch_id,reason,status,created_at
)
select
  '66000000-0000-0000-0000-000000000401',
  organisation_id,outlet_id,period_id,id,
  'revenue_ci_first','pending',clock_timestamp()
from import_batch
where id='66000000-0000-0000-0000-000000000133';

insert into calculation_request_queue(
  id,organisation_id,outlet_id,period_id,source_batch_id,reason,status,created_at
)
select
  '66000000-0000-0000-0000-000000000402',
  organisation_id,outlet_id,period_id,id,
  'revenue_ci_repeat','pending',clock_timestamp()+interval '1 millisecond'
from import_batch
where id='66000000-0000-0000-0000-000000000133';
