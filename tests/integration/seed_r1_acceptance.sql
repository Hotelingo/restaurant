\set ON_ERROR_STOP on

-- R1 first-vertical-slice acceptance fixture.
-- This intentionally persists until the ephemeral GitHub Actions database is
-- destroyed because the real worker runs in a separate process between phases.

insert into neon_auth."user"(id,name,email,"emailVerified")
values
  ('29000000-0000-0000-0000-000000000001','R1 Manager','r1-manager@example.com',false),
  ('29000000-0000-0000-0000-000000000002','R1 Reviewer','r1-reviewer@example.com',false);

set role restaurant_app;
select set_config('app.user_id','29000000-0000-0000-0000-000000000001',false);

-- Step 1 · brand-new organisation/outlet/context/period.
select * from bootstrap_organisation(
  'R1 Acceptance Org','r1-acceptance-org',
  'R1 Acceptance Outlet','R1ACC',
  'USD'::char(3),'UTC',1::smallint,
  'r1-bootstrap-0001','r1-acceptance'
);

select * from create_restaurant_context_version(
  (select id from outlet where code='R1ACC'),
  'casual dining',
  '{"seats":80}'::jsonb,
  '["breakfast","lunch","dinner"]'::jsonb,
  '["dine-in","delivery"]'::jsonb,
  '["walk-in","online"]'::jsonb,
  'partial',
  'clocked-hours',
  'moderate',
  'developing',
  '2026-01-01',
  'r1-context-0001',
  'r1-acceptance'
);

select * from create_reporting_period(
  (select id from outlet where code='R1ACC'),
  '2026-07-01','2026-07-31','July 2026',
  'r1-period-0001','r1-acceptance'
);

select * from put_outlet_setting(
  (select id from outlet where code='R1ACC'),
  'primary_comparator',
  '"budget"'::jsonb,
  'r1-comparator-001',
  'r1-acceptance'
);

select * from create_materiality_version(
  (select id from outlet where code='R1ACC'),
  'general',
  1000,
  0.10,
  '{"basis":"R1 acceptance"}'::jsonb,
  '{}'::jsonb,
  false,
  '2026-01-01',
  'r1-materiality-01',
  'r1-acceptance'
);

reset role;

-- Independent reviewer is part of the same brand-new organisation.
insert into membership(
  organisation_id,user_id,role,outlet_scope_mode,active
)
select
  id,
  '29000000-0000-0000-0000-000000000002',
  'reviewer',
  'all_outlets',
  true
from organisation
where slug='r1-acceptance-org';


-- Step 2 / 3 foundation · an approved T1 profile exists with six known account
-- identities. The uploaded R1 file introduces one new identity (8000), so
-- confirm_financial_mapping must reuse the profile and resolve exactly that row.
insert into source_profile(
  organisation_id,outlet_id,template_code,source_label
)
select organisation_id,id,'T1','R1 P&L profile'
from outlet where code='R1ACC';

insert into profile_version(
  organisation_id,outlet_id,source_profile_id,version_no,
  layout_json,fingerprint_hash,fingerprint_components_json,
  transform_config_json,status,approved_by,approved_at
)
select
  sp.organisation_id,sp.outlet_id,sp.id,1,
  '{"headers":["Account_Code","Account_Name","July_2026"]}',
  repeat('a',64),
  '{"header_set":["account_code","account_name","july_2026"]}',
  '[{"code":"unpivot_month_columns"}]',
  'draft',
  null,
  null
from source_profile sp
where sp.source_label='R1 P&L profile';

insert into account_mapping(
  organisation_id,outlet_id,profile_version_id,
  source_account_code,source_account_name,ladder_line_id,
  mapping_basis,approved_by
)
select
  pv.organisation_id,pv.outlet_id,pv.id,
  v.account_code,v.account_name,ll.id,
  'confirmed',
  '29000000-0000-0000-0000-000000000001'
from profile_version pv
join source_profile sp on sp.id=pv.source_profile_id
cross join (values
  ('4000','Net sales','NET_SALES'),
  ('5000','Product cost','PRODUCT_COST'),
  ('5500','Channel cost','CHANNEL_COST'),
  ('6000','Direct labour','DIRECT_LABOUR'),
  ('6100','Other direct operating','OTHER_DIRECT_OPERATING'),
  ('7000','Shared restaurant cost','SHARED_RESTAURANT_COST')
) v(account_code,account_name,ladder_code)
join ladder_line ll on ll.code=v.ladder_code
where sp.source_label='R1 P&L profile'
  and pv.version_no=1;

update profile_version pv
set status='approved',
    approved_by='29000000-0000-0000-0000-000000000001',
    approved_at=now()
from source_profile sp
where sp.id=pv.source_profile_id
  and sp.source_label='R1 P&L profile'
  and pv.version_no=1;

update source_profile sp
set active_profile_version_id=pv.id
from profile_version pv
where pv.source_profile_id=sp.id
  and sp.source_label='R1 P&L profile'
  and pv.version_no=1;


-- T6 comparator profile is already approved and maps directly at ladder grain.
insert into source_profile(
  organisation_id,outlet_id,template_code,source_label
)
select organisation_id,id,'T6','R1 Budget profile'
from outlet where code='R1ACC';

insert into profile_version(
  organisation_id,outlet_id,source_profile_id,version_no,
  layout_json,fingerprint_hash,fingerprint_components_json,
  transform_config_json,status,approved_by,approved_at
)
select
  sp.organisation_id,sp.outlet_id,sp.id,1,
  '{"headers":["Management_Line","Budget_July_2026"]}',
  repeat('b',64),
  '{"header_set":["management_line","budget_july_2026"]}',
  '[{"code":"unpivot_month_columns"}]',
  'draft',
  null,
  null
from source_profile sp
where sp.source_label='R1 Budget profile';

insert into value_mapping(
  organisation_id,outlet_id,profile_version_id,
  field_name,source_value,canonical_value
)
select
  pv.organisation_id,pv.outlet_id,pv.id,
  'management_line',v.source_value,v.ladder_code
from profile_version pv
join source_profile sp on sp.id=pv.source_profile_id
cross join (values
  ('Net Sales','NET_SALES'),
  ('Product Cost','PRODUCT_COST'),
  ('Channel Cost','CHANNEL_COST'),
  ('Direct Labour','DIRECT_LABOUR'),
  ('Other Direct Operating','OTHER_DIRECT_OPERATING'),
  ('Shared Restaurant Cost','SHARED_RESTAURANT_COST'),
  ('Owner Structural Cost','OWNER_STRUCTURAL_COST')
) v(source_value,ladder_code)
where sp.source_label='R1 Budget profile'
  and pv.version_no=1;

update profile_version pv
set status='approved',
    approved_by='29000000-0000-0000-0000-000000000001',
    approved_at=now()
from source_profile sp
where sp.id=pv.source_profile_id
  and sp.source_label='R1 Budget profile'
  and pv.version_no=1;

update source_profile sp
set active_profile_version_id=pv.id
from profile_version pv
where pv.source_profile_id=sp.id
  and sp.source_label='R1 Budget profile'
  and pv.version_no=1;


-- Step 2 · source-file metadata for the two uploaded financial files.
insert into source_file(
  id,organisation_id,outlet_id,template_code,
  storage_bucket,storage_path,original_filename,sha256,
  content_type,size_bytes,uploaded_by,
  detected_file_type,row_count,malware_scan_status,
  malware_scanner,malware_scanned_at,inspection_json
)
select
  '29000000-0000-0000-0000-000000000101',
  o.organisation_id,o.id,'T1','uploads',
  'org/'||o.organisation_id::text||'/outlet/'||o.id::text||
    '/source/29000000-0000-0000-0000-000000000101/r1-pnl.csv',
  'r1-pnl.csv',repeat('c',64),'text/csv',700,
  '29000000-0000-0000-0000-000000000001',
  'csv',7,'clean','ci',now(),'{"acceptance":"R1"}'
from outlet o where o.code='R1ACC';

insert into source_file(
  id,organisation_id,outlet_id,template_code,
  storage_bucket,storage_path,original_filename,sha256,
  content_type,size_bytes,uploaded_by,
  detected_file_type,row_count,malware_scan_status,
  malware_scanner,malware_scanned_at,inspection_json
)
select
  '29000000-0000-0000-0000-000000000102',
  o.organisation_id,o.id,'T6','uploads',
  'org/'||o.organisation_id::text||'/outlet/'||o.id::text||
    '/source/29000000-0000-0000-0000-000000000102/r1-budget.csv',
  'r1-budget.csv',repeat('d',64),'text/csv',700,
  '29000000-0000-0000-0000-000000000001',
  'csv',7,'clean','ci',now(),'{"acceptance":"R1"}'
from outlet o where o.code='R1ACC';


-- Actual batch deliberately enters needs_mapping: the prior approved profile
-- is the candidate, but account 8000 is new.
insert into import_batch(
  id,organisation_id,outlet_id,source_file_id,template_code,
  period_id,scenario,status,detected_fingerprint,
  parse_metadata_json,profile_match_tier,profile_match_message,
  candidate_profile_version_id,parse_completed_at
)
select
  '29000000-0000-0000-0000-000000000201',
  sf.organisation_id,sf.outlet_id,sf.id,'T1',
  rp.id,'actual','needs_mapping',repeat('e',64),
  jsonb_build_object(
    'headers',jsonb_build_array('Account_Code','Account_Name','July_2026'),
    'selected_sheet_name',null,
    'field_map',jsonb_build_object(
      'Account_Code','account_code',
      'Account_Name','account_name'
    ),
    'month_columns',jsonb_build_array('July_2026'),
    'target_period','2026-07',
    'fingerprint_components',jsonb_build_object(
      'header_set',jsonb_build_array('account_code','account_name','july_2026')
    )
  ),
  'new_rows_only',
  'Known P&L layout with one new account identity',
  sp.active_profile_version_id,
  now()
from source_file sf
join reporting_period rp
  on rp.organisation_id=sf.organisation_id
 and rp.outlet_id=sf.outlet_id
join source_profile sp
  on sp.organisation_id=sf.organisation_id
 and sp.outlet_id=sf.outlet_id
 and sp.source_label='R1 P&L profile'
where sf.id='29000000-0000-0000-0000-000000000101';

insert into staging_row(
  organisation_id,outlet_id,batch_id,source_row_no,
  raw_jsonb,parsed_jsonb,row_status
)
select
  b.organisation_id,b.outlet_id,b.id,v.row_no,
  jsonb_build_object(
    'Account_Code',v.account_code,
    'Account_Name',v.account_name,
    'July_2026',v.amount::text
  ),
  jsonb_build_object(
    'period','2026-07',
    'account_code',v.account_code,
    'account_name',v.account_name,
    'amount',v.amount::text
  ),
  'parsed'
from import_batch b
cross join (values
  (2,'4000','Net sales',228500::numeric),
  (3,'5000','Product cost',70282::numeric),
  (4,'5500','Channel cost',3600::numeric),
  (5,'6000','Direct labour',84317::numeric),
  (6,'6100','Other direct operating',2500::numeric),
  (7,'7000','Shared restaurant cost',14252::numeric),
  (8,'8000','Owner structural cost',26000::numeric)
) v(row_no,account_code,account_name,amount)
where b.id='29000000-0000-0000-0000-000000000201';


-- Budget batch reuses its approved T6 profile without mapping drift.
insert into import_batch(
  id,organisation_id,outlet_id,source_file_id,template_code,
  profile_version_id,period_id,scenario,status,detected_fingerprint,
  parse_metadata_json,profile_match_tier,profile_match_message,
  candidate_profile_version_id,parse_completed_at
)
select
  '29000000-0000-0000-0000-000000000202',
  sf.organisation_id,sf.outlet_id,sf.id,'T6',
  sp.active_profile_version_id,rp.id,'budget','validating',repeat('b',64),
  '{"headers":["Management_Line","Budget_July_2026"],"target_period":"2026-07","fingerprint_components":{"header_set":["management_line","budget_july_2026"]}}',
  'exact',
  'Exact approved Budget profile reused',
  sp.active_profile_version_id,
  now()
from source_file sf
join reporting_period rp
  on rp.organisation_id=sf.organisation_id
 and rp.outlet_id=sf.outlet_id
join source_profile sp
  on sp.organisation_id=sf.organisation_id
 and sp.outlet_id=sf.outlet_id
 and sp.source_label='R1 Budget profile'
where sf.id='29000000-0000-0000-0000-000000000102';

insert into staging_row(
  organisation_id,outlet_id,batch_id,source_row_no,
  raw_jsonb,parsed_jsonb,row_status
)
select
  b.organisation_id,b.outlet_id,b.id,v.row_no,
  jsonb_build_object(
    'Management_Line',v.source_value,
    'Budget_July_2026',v.amount::text
  ),
  jsonb_build_object(
    'period','2026-07',
    'management_line',v.source_value,
    'amount',v.amount::text
  ),
  'parsed'
from import_batch b
cross join (values
  (2,'Net Sales',232000::numeric),
  (3,'Product Cost',66908::numeric),
  (4,'Channel Cost',3300::numeric),
  (5,'Direct Labour',79112::numeric),
  (6,'Other Direct Operating',2300::numeric),
  (7,'Shared Restaurant Cost',12160::numeric),
  (8,'Owner Structural Cost',26000::numeric)
) v(row_no,source_value,amount)
where b.id='29000000-0000-0000-0000-000000000202';


-- Step 3 · reuse the T1 profile and resolve the single new account.
set role restaurant_app;
select set_config('app.user_id','29000000-0000-0000-0000-000000000001',false);

select * from confirm_financial_mapping(
  '29000000-0000-0000-0000-000000000201',
  'r1-mapping-confirm1',
  null,
  (select candidate_profile_version_id
   from import_batch
   where id='29000000-0000-0000-0000-000000000201'),
  '[{
    "source_account_code":"8000",
    "source_account_name":"Owner structural cost",
    "ladder_line_code":"OWNER_STRUCTURAL_COST"
  }]'::jsonb,
  '[]'::jsonb,
  'r1-acceptance'
);

-- Step 4 · validation persists its evidence before the two batches are allowed
-- into the atomic canonical commit path.
insert into validation_result(
  organisation_id,outlet_id,batch_id,
  rule_code,severity,object_scope,
  message,remediation,reconciliation_status
)
select
  organisation_id,outlet_id,id,
  'R1.ACCEPTANCE.VALIDATED','info','batch',
  'R1 acceptance validation passed',
  'No remediation required',
  'reconciled'
from import_batch
where id in (
  '29000000-0000-0000-0000-000000000201',
  '29000000-0000-0000-0000-000000000202'
);

update import_batch
set status='ready'
where id in (
  '29000000-0000-0000-0000-000000000201',
  '29000000-0000-0000-0000-000000000202'
);

-- Commit comparator first so the actual-source request can execute immediately
-- with both pinned inputs.
select * from commit_financial_import_batch(
  '29000000-0000-0000-0000-000000000202',
  'r1-commit-budget01',
  'r1-acceptance',
  false
);

select * from commit_financial_import_batch(
  '29000000-0000-0000-0000-000000000201',
  'r1-commit-actual01',
  'r1-acceptance',
  true
);

reset role;

-- Pre-worker assertions: these fail before a calculation can hide an ingestion
-- defect.
do $$
declare
  v_actual_profile uuid;
  v_base_profile uuid;
begin
  select profile_version_id into v_actual_profile
  from import_batch
  where id='29000000-0000-0000-0000-000000000201';

  select pv.id into v_base_profile
  from profile_version pv
  join source_profile sp on sp.id=pv.source_profile_id
  where sp.source_label='R1 P&L profile'
    and pv.version_no=1;

  if not exists (
    select 1
    from profile_version
    where id=v_actual_profile
      and version_no=2
      and supersedes_profile_version_id=v_base_profile
      and status='approved'
  ) then
    raise exception 'FAIL R1 mapping profile was not reused as immutable v2';
  end if;

  if (select count(*) from account_mapping where profile_version_id=v_actual_profile) <> 7 then
    raise exception 'FAIL R1 mapped profile must contain seven source accounts';
  end if;

  if not exists (
    select 1
    from account_mapping am
    join ladder_line ll on ll.id=am.ladder_line_id
    where am.profile_version_id=v_actual_profile
      and am.source_account_code='8000'
      and ll.code='OWNER_STRUCTURAL_COST'
  ) then
    raise exception 'FAIL R1 new account 8000 was not explicitly resolved';
  end if;

  if (select count(*) from import_batch
      where id in (
        '29000000-0000-0000-0000-000000000201',
        '29000000-0000-0000-0000-000000000202'
      ) and status='committed') <> 2 then
    raise exception 'FAIL R1 T1/T6 batches were not atomically committed';
  end if;

  if (select count(*) from financial_fact
      where batch_id in (
        '29000000-0000-0000-0000-000000000201',
        '29000000-0000-0000-0000-000000000202'
      )) <> 14 then
    raise exception 'FAIL R1 canonical financial facts expected 14 rows';
  end if;

  if not exists (
    select 1
    from calculation_request_queue
    where source_batch_id='29000000-0000-0000-0000-000000000201'
      and status='pending'
  ) then
    raise exception 'FAIL R1 actual commit did not enqueue the calculation run';
  end if;

  raise notice 'PASS R1 setup, upload, profile reuse, validation and atomic commit';
end
$$;
