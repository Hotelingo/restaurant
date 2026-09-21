\set ON_ERROR_STOP on

-- Persistent CI fixture for the background worker. This database exists only
-- for the ephemeral GitHub Actions job, so unlike the regression suites above
-- this seed intentionally does not roll back.

insert into neon_auth."user"(id,name,email,"emailVerified")
values ('e0000000-0000-0000-0000-000000000001','Worker Admin','worker@example.com',false);

set role restaurant_app;
select set_config('app.user_id','e0000000-0000-0000-0000-000000000001',false);

select * from bootstrap_organisation(
  'Worker Org','worker-org','Worker Outlet','WORKER',
  'USD'::char(3),'UTC',1::smallint,'worker-bootstrap','worker-ci'
);

insert into reporting_period(
  id,organisation_id,outlet_id,period_start,period_end,label
)
select
  'e0000000-0000-0000-0000-000000000010',
  organisation_id,id,'2026-07-01','2026-07-31','July 2026'
from outlet where code='WORKER';

reset role;

insert into setting(organisation_id,outlet_id,key,value_json)
select organisation_id,id,'primary_comparator','"budget"'::jsonb
from outlet where code='WORKER';

insert into materiality_setting(
  id,organisation_id,outlet_id,scope_type,
  absolute_threshold,percent_threshold,source_kind,
  proposal_basis,recurrence_rule,risk_override_enabled,
  effective_from,approved_by,approved_at
)
select
  'e0000000-0000-0000-0000-000000000020',
  organisation_id,id,'general',
  1000,0.10,'user_confirmed',
  '{"basis":"ci"}','{}',false,
  '2026-07-01',
  'e0000000-0000-0000-0000-000000000001',now()
from outlet where code='WORKER';

-- Approved T1 and T6 profile versions.
insert into source_profile(
  id,organisation_id,outlet_id,template_code,source_label
)
select
  'e0000000-0000-0000-0000-000000000101',
  organisation_id,id,'T1','Worker actual'
from outlet where code='WORKER';

insert into source_profile(
  id,organisation_id,outlet_id,template_code,source_label
)
select
  'e0000000-0000-0000-0000-000000000102',
  organisation_id,id,'T6','Worker budget'
from outlet where code='WORKER';

insert into profile_version(
  id,organisation_id,outlet_id,source_profile_id,version_no,
  layout_json,fingerprint_hash,fingerprint_components_json,
  transform_config_json,status,approved_by,approved_at
)
select
  'e0000000-0000-0000-0000-000000000111',
  organisation_id,outlet_id,id,1,'{}',repeat('a',64),'{}','[]',
  'approved','e0000000-0000-0000-0000-000000000001',now()
from source_profile where id='e0000000-0000-0000-0000-000000000101';

insert into profile_version(
  id,organisation_id,outlet_id,source_profile_id,version_no,
  layout_json,fingerprint_hash,fingerprint_components_json,
  transform_config_json,status,approved_by,approved_at
)
select
  'e0000000-0000-0000-0000-000000000112',
  organisation_id,outlet_id,id,1,'{}',repeat('b',64),'{}','[]',
  'approved','e0000000-0000-0000-0000-000000000001',now()
from source_profile where id='e0000000-0000-0000-0000-000000000102';

update source_profile
set active_profile_version_id='e0000000-0000-0000-0000-000000000111'
where id='e0000000-0000-0000-0000-000000000101';

update source_profile
set active_profile_version_id='e0000000-0000-0000-0000-000000000112'
where id='e0000000-0000-0000-0000-000000000102';

-- Immutable source-file metadata.
insert into source_file(
  id,organisation_id,outlet_id,template_code,
  storage_bucket,storage_path,original_filename,sha256,
  content_type,size_bytes,uploaded_by,
  detected_file_type,row_count,malware_scan_status,
  malware_scanner,malware_scanned_at,inspection_json
)
select
  'e0000000-0000-0000-0000-000000000121',
  o.organisation_id,o.id,'T1','uploads',
  'org/'||o.organisation_id::text||'/outlet/'||o.id::text||
    '/source/e0000000-0000-0000-0000-000000000121/actual.csv',
  'actual.csv',repeat('c',64),'text/csv',100,
  'e0000000-0000-0000-0000-000000000001',
  'csv',7,'clean','ci',now(),'{}'
from outlet o where o.code='WORKER';

insert into source_file(
  id,organisation_id,outlet_id,template_code,
  storage_bucket,storage_path,original_filename,sha256,
  content_type,size_bytes,uploaded_by,
  detected_file_type,row_count,malware_scan_status,
  malware_scanner,malware_scanned_at,inspection_json
)
select
  'e0000000-0000-0000-0000-000000000122',
  o.organisation_id,o.id,'T6','uploads',
  'org/'||o.organisation_id::text||'/outlet/'||o.id::text||
    '/source/e0000000-0000-0000-0000-000000000122/budget.csv',
  'budget.csv',repeat('d',64),'text/csv',100,
  'e0000000-0000-0000-0000-000000000001',
  'csv',7,'clean','ci',now(),'{}'
from outlet o where o.code='WORKER';

insert into import_batch(
  id,organisation_id,outlet_id,source_file_id,template_code,
  profile_version_id,period_id,scenario,status,detected_fingerprint
)
select
  'e0000000-0000-0000-0000-000000000131',
  sf.organisation_id,sf.outlet_id,sf.id,'T1',
  'e0000000-0000-0000-0000-000000000111',
  'e0000000-0000-0000-0000-000000000010',
  'actual','uploaded',repeat('a',64)
from source_file sf
where sf.id='e0000000-0000-0000-0000-000000000121';

insert into import_batch(
  id,organisation_id,outlet_id,source_file_id,template_code,
  profile_version_id,period_id,scenario,status,detected_fingerprint
)
select
  'e0000000-0000-0000-0000-000000000132',
  sf.organisation_id,sf.outlet_id,sf.id,'T6',
  'e0000000-0000-0000-0000-000000000112',
  'e0000000-0000-0000-0000-000000000010',
  'budget','uploaded',repeat('b',64)
from source_file sf
where sf.id='e0000000-0000-0000-0000-000000000122';

-- Seven canonical actual accounts, one per non-calculated ladder source line.
insert into account(
  id,organisation_id,outlet_id,account_code,account_name
)
select seed.id,o.organisation_id,o.id,seed.code,seed.name
from outlet o
cross join (
  values
    ('e0000000-0000-0000-0000-000000000201'::uuid,'4000','Net sales'),
    ('e0000000-0000-0000-0000-000000000202'::uuid,'5000','Product cost'),
    ('e0000000-0000-0000-0000-000000000203'::uuid,'5500','Channel cost'),
    ('e0000000-0000-0000-0000-000000000204'::uuid,'6000','Direct labour'),
    ('e0000000-0000-0000-0000-000000000205'::uuid,'6100','Other direct operating'),
    ('e0000000-0000-0000-0000-000000000206'::uuid,'7000','Shared restaurant cost'),
    ('e0000000-0000-0000-0000-000000000207'::uuid,'8000','Owner structural cost')
) as seed(id,code,name)
where o.code='WORKER';

insert into financial_fact(
  id,organisation_id,outlet_id,period_id,scenario,
  account_id,ladder_line_id,amount,currency_code,
  batch_id,profile_version_id
)
select
  seed.fact_id,o.organisation_id,o.id,
  'e0000000-0000-0000-0000-000000000010',
  'actual',seed.account_id,ll.id,seed.amount,'USD',
  'e0000000-0000-0000-0000-000000000131',
  'e0000000-0000-0000-0000-000000000111'
from outlet o
join (
  values
    ('e0000000-0000-0000-0000-000000000301'::uuid,'e0000000-0000-0000-0000-000000000201'::uuid,'NET_SALES',228500::numeric),
    ('e0000000-0000-0000-0000-000000000302'::uuid,'e0000000-0000-0000-0000-000000000202'::uuid,'PRODUCT_COST',70282::numeric),
    ('e0000000-0000-0000-0000-000000000303'::uuid,'e0000000-0000-0000-0000-000000000203'::uuid,'CHANNEL_COST',3600::numeric),
    ('e0000000-0000-0000-0000-000000000304'::uuid,'e0000000-0000-0000-0000-000000000204'::uuid,'DIRECT_LABOUR',84317::numeric),
    ('e0000000-0000-0000-0000-000000000305'::uuid,'e0000000-0000-0000-0000-000000000205'::uuid,'OTHER_DIRECT_OPERATING',2500::numeric),
    ('e0000000-0000-0000-0000-000000000306'::uuid,'e0000000-0000-0000-0000-000000000206'::uuid,'SHARED_RESTAURANT_COST',14252::numeric),
    ('e0000000-0000-0000-0000-000000000307'::uuid,'e0000000-0000-0000-0000-000000000207'::uuid,'OWNER_STRUCTURAL_COST',26000::numeric)
) as seed(fact_id,account_id,line_code,amount) on true
join ladder_line ll on ll.code=seed.line_code
where o.code='WORKER';

insert into financial_fact(
  id,organisation_id,outlet_id,period_id,scenario,
  account_id,ladder_line_id,amount,currency_code,
  batch_id,profile_version_id
)
select
  seed.fact_id,o.organisation_id,o.id,
  'e0000000-0000-0000-0000-000000000010',
  'budget',null,ll.id,seed.amount,'USD',
  'e0000000-0000-0000-0000-000000000132',
  'e0000000-0000-0000-0000-000000000112'
from outlet o
join (
  values
    ('e0000000-0000-0000-0000-000000000311'::uuid,'NET_SALES',232000::numeric),
    ('e0000000-0000-0000-0000-000000000312'::uuid,'PRODUCT_COST',66908::numeric),
    ('e0000000-0000-0000-0000-000000000313'::uuid,'CHANNEL_COST',3300::numeric),
    ('e0000000-0000-0000-0000-000000000314'::uuid,'DIRECT_LABOUR',79112::numeric),
    ('e0000000-0000-0000-0000-000000000315'::uuid,'OTHER_DIRECT_OPERATING',2300::numeric),
    ('e0000000-0000-0000-0000-000000000316'::uuid,'SHARED_RESTAURANT_COST',12160::numeric),
    ('e0000000-0000-0000-0000-000000000317'::uuid,'OWNER_STRUCTURAL_COST',26000::numeric)
) as seed(fact_id,line_code,amount) on true
join ladder_line ll on ll.code=seed.line_code
where o.code='WORKER';

update import_batch
set status='committed',
    committed_by='e0000000-0000-0000-0000-000000000001',
    committed_at=now(),
    canonical_commit_hash=repeat('1',64),
    canonical_commit_summary='{"fact_count":7}'
where id='e0000000-0000-0000-0000-000000000131';

update import_batch
set status='committed',
    committed_by='e0000000-0000-0000-0000-000000000001',
    committed_at=now(),
    canonical_commit_hash=repeat('2',64),
    canonical_commit_summary='{"fact_count":7}'
where id='e0000000-0000-0000-0000-000000000132';

-- Two independent requests prove a rerun receives a new calc_run id while
-- preserving an identical deterministic result hash.
insert into calculation_request_queue(
  id,organisation_id,outlet_id,period_id,source_batch_id,reason,status,created_at
)
select
  'e0000000-0000-0000-0000-000000000401',
  organisation_id,outlet_id,period_id,id,
  'ci_first_run','pending',clock_timestamp()
from import_batch
where id='e0000000-0000-0000-0000-000000000132';

insert into calculation_request_queue(
  id,organisation_id,outlet_id,period_id,source_batch_id,reason,status,created_at
)
select
  'e0000000-0000-0000-0000-000000000402',
  organisation_id,outlet_id,period_id,id,
  'ci_repeat_run','pending',clock_timestamp() + interval '1 millisecond'
from import_batch
where id='e0000000-0000-0000-0000-000000000132';
