\set ON_ERROR_STOP on

-- Persistent CI fixture for the Food Cost worker. The surrounding database is
-- ephemeral, so this seed intentionally commits.

insert into neon_auth."user"(id,name,email,"emailVerified")
values ('f0000000-0000-0000-0000-000000000001','FC Worker Admin','fc-worker@example.com',false);

set role restaurant_app;
select set_config('app.user_id','f0000000-0000-0000-0000-000000000001',false);

select * from bootstrap_organisation(
  'FC Worker Org','fc-worker-org','FC Worker Outlet','FCWORKER',
  'USD'::char(3),'UTC',1::smallint,'fc-worker-bootstrap','fc-worker-ci'
);

insert into reporting_period(
  id,organisation_id,outlet_id,period_start,period_end,label
)
select
  'f0000000-0000-0000-0000-000000000010',
  organisation_id,id,'2026-07-01','2026-07-31','July 2026'
from outlet where code='FCWORKER';

reset role;

insert into materiality_setting(
  id,organisation_id,outlet_id,scope_type,
  absolute_threshold,percent_threshold,source_kind,
  proposal_basis,recurrence_rule,risk_override_enabled,
  effective_from,approved_by,approved_at
)
select
  'f0000000-0000-0000-0000-000000000020',
  organisation_id,id,'general',
  1000,0.10,'user_confirmed',
  '{"basis":"fc_worker_ci"}','{}',false,
  '2026-07-01',
  'f0000000-0000-0000-0000-000000000001',now()
from outlet where code='FCWORKER';

-- Three approved source profiles.
insert into source_profile(
  id,organisation_id,outlet_id,template_code,source_label
)
select v.id,o.organisation_id,o.id,v.template_code,v.source_label
from outlet o
cross join (values
  ('f0000000-0000-0000-0000-000000000101'::uuid,'T2','FC POS'),
  ('f0000000-0000-0000-0000-000000000102'::uuid,'T3','FC Stock'),
  ('f0000000-0000-0000-0000-000000000103'::uuid,'T4A','FC Item Cost')
) v(id,template_code,source_label)
where o.code='FCWORKER';

insert into profile_version(
  id,organisation_id,outlet_id,source_profile_id,version_no,
  layout_json,fingerprint_hash,fingerprint_components_json,transform_config_json
)
select
  v.profile_id,sp.organisation_id,sp.outlet_id,sp.id,1,
  '{}'::jsonb,v.hash,'{}'::jsonb,'[]'::jsonb
from source_profile sp
join (values
  ('f0000000-0000-0000-0000-000000000101'::uuid,'f0000000-0000-0000-0000-000000000111'::uuid,repeat('2',64)),
  ('f0000000-0000-0000-0000-000000000102'::uuid,'f0000000-0000-0000-0000-000000000112'::uuid,repeat('3',64)),
  ('f0000000-0000-0000-0000-000000000103'::uuid,'f0000000-0000-0000-0000-000000000113'::uuid,repeat('4',64))
) v(source_id,profile_id,hash)
  on v.source_id=sp.id;

insert into value_mapping(
  organisation_id,outlet_id,profile_version_id,
  field_name,source_value,canonical_value
)
select
  pv.organisation_id,pv.outlet_id,pv.id,
  'product_group',v.source_value,v.canonical_value
from profile_version pv
cross join (values
  ('Mains','food'),
  ('Starters & Desserts','food'),
  ('Beverages','beverage')
) v(source_value,canonical_value)
where pv.id='f0000000-0000-0000-0000-000000000111';

update profile_version
set status='approved',
    approved_by='f0000000-0000-0000-0000-000000000001',
    approved_at=now()
where id in (
  'f0000000-0000-0000-0000-000000000111',
  'f0000000-0000-0000-0000-000000000112',
  'f0000000-0000-0000-0000-000000000113'
);

update source_profile sp
set active_profile_version_id=pv.id
from profile_version pv
where pv.source_profile_id=sp.id
  and sp.id in (
    'f0000000-0000-0000-0000-000000000101',
    'f0000000-0000-0000-0000-000000000102',
    'f0000000-0000-0000-0000-000000000103'
  );

-- Immutable source-file metadata.
insert into source_file(
  id,organisation_id,outlet_id,template_code,
  storage_bucket,storage_path,original_filename,sha256,
  content_type,size_bytes,uploaded_by,
  detected_file_type,row_count,malware_scan_status,
  malware_scanner,malware_scanned_at,inspection_json
)
select
  v.id,o.organisation_id,o.id,v.template_code,'uploads',
  'org/'||o.organisation_id::text||'/outlet/'||o.id::text||
    '/source/'||v.id::text||'/'||lower(v.template_code)||'.csv',
  lower(v.template_code)||'.csv',v.hash,'text/csv',1000,
  'f0000000-0000-0000-0000-000000000001',
  'csv',v.row_count,'clean','ci',now(),'{}'
from outlet o
cross join (values
  ('f0000000-0000-0000-0000-000000000121'::uuid,'T2',repeat('a',64),12),
  ('f0000000-0000-0000-0000-000000000122'::uuid,'T3',repeat('b',64),2),
  ('f0000000-0000-0000-0000-000000000123'::uuid,'T4A',repeat('c',64),12)
) v(id,template_code,hash,row_count)
where o.code='FCWORKER';

insert into import_batch(
  id,organisation_id,outlet_id,source_file_id,template_code,
  profile_version_id,period_id,scenario,status,detected_fingerprint
)
select
  v.batch_id,sf.organisation_id,sf.outlet_id,sf.id,sf.template_code,
  v.profile_id,'f0000000-0000-0000-0000-000000000010',
  'actual','ready',v.fingerprint
from source_file sf
join (values
  ('f0000000-0000-0000-0000-000000000121'::uuid,'f0000000-0000-0000-0000-000000000131'::uuid,'f0000000-0000-0000-0000-000000000111'::uuid,repeat('2',64)),
  ('f0000000-0000-0000-0000-000000000122'::uuid,'f0000000-0000-0000-0000-000000000132'::uuid,'f0000000-0000-0000-0000-000000000112'::uuid,repeat('3',64)),
  ('f0000000-0000-0000-0000-000000000123'::uuid,'f0000000-0000-0000-0000-000000000133'::uuid,'f0000000-0000-0000-0000-000000000113'::uuid,repeat('4',64))
) v(source_id,batch_id,profile_id,fingerprint)
  on v.source_id=sf.id;

-- Amberside item fixture.
create temporary table fc_worker_items(
  code text,
  item_name text,
  population text,
  units numeric,
  net_revenue numeric,
  approved_cost numeric
);

insert into fc_worker_items values
  ('F01','Ribeye Steak','Mains',900,40500,17.0),
  ('F02','House Burger','Mains',1600,35200,7.0),
  ('F03','Club Sandwich','Mains',1500,27000,5.5),
  ('F04','Grilled Chicken','Mains',1400,33600,6.5),
  ('F05','Local Seafood Plate','Mains',700,26600,12.5),
  ('F06','Vegan Curry','Mains',800,15200,5.0),
  ('F07','Seasonal Soup','Starters & Desserts',500,6000,3.0),
  ('F08','Chocolate Tart','Starters & Desserts',500,7000,4.6),
  ('B01','House Beer','Beverages',900,7200,1.8),
  ('B02','Local Wine','Beverages',500,9000,4.8),
  ('B03','Soft Drinks','Beverages',800,4000,0.9),
  ('B04','Cocktails','Beverages',400,7200,3.6);

insert into item(
  organisation_id,outlet_id,canonical_item_key,item_code,item_name,population
)
select
  o.organisation_id,o.id,lower(v.code),v.code,v.item_name,v.population
from outlet o
cross join fc_worker_items v
where o.code='FCWORKER';

-- One immutable staging row per T2 item.
insert into staging_row(
  organisation_id,outlet_id,batch_id,source_row_no,
  raw_jsonb,parsed_jsonb,row_status
)
select
  b.organisation_id,b.outlet_id,b.id,
  row_number() over(order by v.code)+1,
  jsonb_build_object(
    'Item_Code',v.code,'Item',v.item_name,'Population',v.population,
    'Units',v.units,'Net_Revenue',v.net_revenue
  ),
  jsonb_build_object(
    'period','2026-07','item_code',v.code,'item_name',v.item_name,
    'population',v.population,'units_sold',v.units::text,
    'net_revenue',v.net_revenue::text
  ),
  'parsed'
from import_batch b
cross join fc_worker_items v
where b.id='f0000000-0000-0000-0000-000000000131';

insert into item_sales_fact(
  organisation_id,outlet_id,period_id,item_id,
  population,units_sold,net_revenue,
  batch_id,profile_version_id,staging_row_id
)
select
  b.organisation_id,b.outlet_id,b.period_id,i.id,
  v.population,v.units,v.net_revenue,
  b.id,b.profile_version_id,s.id
from import_batch b
cross join fc_worker_items v
join item i
  on i.organisation_id=b.organisation_id
 and i.outlet_id=b.outlet_id
 and i.canonical_item_key=lower(v.code)
join staging_row s
  on s.batch_id=b.id
 and s.parsed_jsonb->>'item_code'=v.code
where b.id='f0000000-0000-0000-0000-000000000131';

-- T3 stock rows.
insert into staging_row(
  organisation_id,outlet_id,batch_id,source_row_no,
  raw_jsonb,parsed_jsonb,row_status
)
select b.organisation_id,b.outlet_id,b.id,v.row_no,v.raw_json,v.parsed_json,'parsed'
from import_batch b
cross join (values
  (
    2,
    '{"Product_Group":"Food","Opening_Inventory":"9800","Purchases":"62900","Closing_Inventory":"11357","Revenue":"191100","Budget_Cost_Pct":"0.30","Expected_Usage":"60400"}'::jsonb,
    '{"period":"2026-07","product_group":"food","opening_inventory":"9800","purchases":"62900","closing_inventory":"11357","source_product_revenue":"191100","source_budget_cost_pct":"0.30"}'::jsonb
  ),
  (
    3,
    '{"Product_Group":"Beverage","Opening_Inventory":"3500","Purchases":"5900","Closing_Inventory":"2961","Revenue":"27400","Budget_Cost_Pct":"0.22","Expected_Usage":"6180"}'::jsonb,
    '{"period":"2026-07","product_group":"beverage","opening_inventory":"3500","purchases":"5900","closing_inventory":"2961","source_product_revenue":"27400","source_budget_cost_pct":"0.22"}'::jsonb
  )
) v(row_no,raw_json,parsed_json)
where b.id='f0000000-0000-0000-0000-000000000132';

insert into stock_fact(
  organisation_id,outlet_id,period_id,product_group,
  opening_inventory,purchases,closing_inventory,
  source_product_revenue,source_budget_cost_pct,
  batch_id,profile_version_id,staging_row_id
)
select
  b.organisation_id,b.outlet_id,b.period_id,
  s.parsed_jsonb->>'product_group',
  (s.parsed_jsonb->>'opening_inventory')::numeric,
  (s.parsed_jsonb->>'purchases')::numeric,
  (s.parsed_jsonb->>'closing_inventory')::numeric,
  (s.parsed_jsonb->>'source_product_revenue')::numeric,
  (s.parsed_jsonb->>'source_budget_cost_pct')::numeric,
  b.id,b.profile_version_id,s.id
from import_batch b
join staging_row s on s.batch_id=b.id
where b.id='f0000000-0000-0000-0000-000000000132';

-- T4A item cost rows.
insert into staging_row(
  organisation_id,outlet_id,batch_id,source_row_no,
  raw_jsonb,parsed_jsonb,row_status
)
select
  b.organisation_id,b.outlet_id,b.id,
  row_number() over(order by v.code)+1,
  jsonb_build_object(
    'Item_Code',v.code,'Item',v.item_name,'Population',v.population,
    'Approved_Cost_per_Unit',v.approved_cost
  ),
  jsonb_build_object(
    'period','2026-07','item_code',v.code,'item_name',v.item_name,
    'population',v.population,'effective_from','2026-07-01',
    'effective_from_basis','fixed_default',
    'approved_cost_per_unit',v.approved_cost::text
  ),
  'parsed'
from import_batch b
cross join fc_worker_items v
where b.id='f0000000-0000-0000-0000-000000000133';

insert into item_cost_snapshot(
  organisation_id,outlet_id,period_id,item_id,effective_from,
  approved_cost_per_unit,effective_from_basis,
  batch_id,profile_version_id,staging_row_id
)
select
  b.organisation_id,b.outlet_id,b.period_id,i.id,'2026-07-01',
  v.approved_cost,'fixed_default',
  b.id,b.profile_version_id,s.id
from import_batch b
cross join fc_worker_items v
join item i
  on i.organisation_id=b.organisation_id
 and i.outlet_id=b.outlet_id
 and i.canonical_item_key=lower(v.code)
join staging_row s
  on s.batch_id=b.id
 and s.parsed_jsonb->>'item_code'=v.code
where b.id='f0000000-0000-0000-0000-000000000133';

update import_batch
set status='committed',
    committed_by='f0000000-0000-0000-0000-000000000001',
    committed_at=now(),
    canonical_commit_hash=repeat('5',64),
    canonical_commit_summary='{"fact_count":12}'
where id='f0000000-0000-0000-0000-000000000131';

update import_batch
set status='committed',
    committed_by='f0000000-0000-0000-0000-000000000001',
    committed_at=now(),
    canonical_commit_hash=repeat('6',64),
    canonical_commit_summary='{"fact_count":2}'
where id='f0000000-0000-0000-0000-000000000132';

update import_batch
set status='committed',
    committed_by='f0000000-0000-0000-0000-000000000001',
    committed_at=now(),
    canonical_commit_hash=repeat('7',64),
    canonical_commit_summary='{"fact_count":12}'
where id='f0000000-0000-0000-0000-000000000133';

insert into data_readiness(
  organisation_id,outlet_id,period_id,capability_code,status,latest_batch_id,details_json
)
select
  organisation_id,outlet_id,period_id,'food_cost_inputs','ready',id,
  '{"t2_item_sales_committed":true,"t3_stock_committed":true,"t4a_item_cost_committed":true,"expected_usage_source":"DERIVED_T2_X_T4A"}'
from import_batch
where id='f0000000-0000-0000-0000-000000000132';

-- Two requests prove immutable reruns with deterministic hashes.
insert into calculation_request_queue(
  id,organisation_id,outlet_id,period_id,source_batch_id,reason,status,created_at
)
select
  'f0000000-0000-0000-0000-000000000401',
  organisation_id,outlet_id,period_id,id,
  'food_cost_ci_first','pending',clock_timestamp()
from import_batch
where id='f0000000-0000-0000-0000-000000000132';

insert into calculation_request_queue(
  id,organisation_id,outlet_id,period_id,source_batch_id,reason,status,created_at
)
select
  'f0000000-0000-0000-0000-000000000402',
  organisation_id,outlet_id,period_id,id,
  'food_cost_ci_repeat','pending',clock_timestamp()+interval '1 millisecond'
from import_batch
where id='f0000000-0000-0000-0000-000000000132';
