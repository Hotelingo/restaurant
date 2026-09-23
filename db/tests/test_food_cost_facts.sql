\set ON_ERROR_STOP on
begin;

create or replace function fc30_eq(actual bigint, expected bigint, label text)
returns void language plpgsql as $$
begin
  if actual is distinct from expected then
    raise exception 'FAIL % -- expected %, got %',label,expected,actual;
  end if;
  raise notice 'PASS %',label;
end $$;

create or replace function fc30_text(actual text, expected text, label text)
returns void language plpgsql as $$
begin
  if actual is distinct from expected then
    raise exception 'FAIL % -- expected %, got %',label,expected,actual;
  end if;
  raise notice 'PASS %',label;
end $$;

create or replace function fc30_true(actual boolean, label text)
returns void language plpgsql as $$
begin
  if not coalesce(actual,false) then
    raise exception 'FAIL %',label;
  end if;
  raise notice 'PASS %',label;
end $$;

create or replace function fc30_rejects(stmt text, label text)
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
values('30000000-0000-0000-0000-000000000001','Food Admin','food-admin@example.com',false);

set role restaurant_app;
select set_config('app.user_id','30000000-0000-0000-0000-000000000001',true);

select * from bootstrap_organisation(
  'Food Cost Org','food-cost-org',
  'Food Cost Outlet','FOOD30',
  'USD'::char(3),'UTC',1::smallint,
  'fc30-bootstrap','fc30-test'
);

insert into reporting_period(
  organisation_id,outlet_id,period_start,period_end,label
)
select organisation_id,id,'2026-07-01','2026-07-31','July 2026'
from outlet where code='FOOD30';

insert into reporting_period(
  organisation_id,outlet_id,period_start,period_end,label
)
select organisation_id,id,'2026-08-01','2026-08-31','August 2026'
from outlet where code='FOOD30';

reset role;

-- Approved profiles: T2/T4A use item identity mapping; T3 uses controlled
-- product-group values. Build mappings while draft, approve only afterward.
insert into source_profile(organisation_id,outlet_id,template_code,source_label)
select organisation_id,id,v.code,v.label
from outlet
cross join (values
  ('T2','Food POS'),
  ('T3','Food Stock'),
  ('T4A','Food Item Cost')
) v(code,label)
where outlet.code='FOOD30';

insert into profile_version(
  organisation_id,outlet_id,source_profile_id,version_no,
  layout_json,fingerprint_hash,fingerprint_components_json,
  transform_config_json
)
select
  sp.organisation_id,sp.outlet_id,sp.id,1,
  '{}'::jsonb,
  case sp.template_code
    when 'T2' then repeat('2',64)
    when 'T3' then repeat('3',64)
    else repeat('4',64)
  end,
  '{}'::jsonb,'[]'::jsonb
from source_profile sp
where sp.organisation_id=(
  select organisation_id from outlet where code='FOOD30'
);

insert into item_mapping(
  organisation_id,outlet_id,profile_version_id,
  source_item_code,source_item_name,canonical_item_key,
  mapping_basis,approved_by
)
select
  pv.organisation_id,pv.outlet_id,pv.id,
  v.code,v.name,lower(v.code),
  'confirmed','30000000-0000-0000-0000-000000000001'
from profile_version pv
join source_profile sp on sp.id=pv.source_profile_id
cross join (values
  ('F01','Food One'),
  ('B01','Beverage One')
) v(code,name)
where sp.template_code in ('T2','T4A')
  and sp.organisation_id=(
    select organisation_id from outlet where code='FOOD30'
  );

insert into value_mapping(
  organisation_id,outlet_id,profile_version_id,
  field_name,source_value,canonical_value
)
select
  pv.organisation_id,pv.outlet_id,pv.id,
  'product_group',v.source_value,v.canonical_value
from profile_version pv
join source_profile sp on sp.id=pv.source_profile_id
cross join (values
  ('Food','food'),
  ('Beverage','beverage')
) v(source_value,canonical_value)
where sp.template_code='T3'
  and sp.organisation_id=(
    select organisation_id from outlet where code='FOOD30'
  );

update profile_version pv
set status='approved',
    approved_by='30000000-0000-0000-0000-000000000001',
    approved_at=now()
from source_profile sp
where sp.id=pv.source_profile_id
  and sp.organisation_id=(
    select organisation_id from outlet where code='FOOD30'
  );

update source_profile sp
set active_profile_version_id=pv.id
from profile_version pv
where pv.source_profile_id=sp.id
  and pv.version_no=1
  and sp.organisation_id=(
    select organisation_id from outlet where code='FOOD30'
  );


-- Source-file + batch helper rows for July.
insert into source_file(
  id,organisation_id,outlet_id,template_code,
  storage_bucket,storage_path,original_filename,sha256,
  content_type,size_bytes,uploaded_by,
  detected_file_type,row_count,malware_scan_status,
  malware_scanner,malware_scanned_at,inspection_json
)
select
  v.id,o.organisation_id,o.id,v.template_code,
  'uploads',
  'org/'||o.organisation_id::text||'/outlet/'||o.id::text||
    '/source/'||v.id::text||'/'||lower(v.template_code)||'.csv',
  lower(v.template_code)||'.csv',
  v.sha,'text/csv',500,
  '30000000-0000-0000-0000-000000000001',
  'csv',2,'clean','ci',now(),'{}'
from outlet o
cross join (values
  ('30000000-0000-0000-0000-000000000101'::uuid,'T2',repeat('a',64)),
  ('30000000-0000-0000-0000-000000000102'::uuid,'T3',repeat('b',64)),
  ('30000000-0000-0000-0000-000000000103'::uuid,'T4A',repeat('c',64))
) v(id,template_code,sha)
where o.code='FOOD30';

insert into import_batch(
  id,organisation_id,outlet_id,source_file_id,template_code,
  profile_version_id,period_id,scenario,status,detected_fingerprint
)
select
  v.batch_id,sf.organisation_id,sf.outlet_id,sf.id,sf.template_code,
  sp.active_profile_version_id,rp.id,'actual','ready',v.fingerprint
from source_file sf
join source_profile sp
  on sp.organisation_id=sf.organisation_id
 and sp.outlet_id=sf.outlet_id
 and sp.template_code=sf.template_code
join reporting_period rp
  on rp.organisation_id=sf.organisation_id
 and rp.outlet_id=sf.outlet_id
 and rp.period_start='2026-07-01'
join (values
  ('30000000-0000-0000-0000-000000000101'::uuid,'30000000-0000-0000-0000-000000000201'::uuid,repeat('2',64)),
  ('30000000-0000-0000-0000-000000000102'::uuid,'30000000-0000-0000-0000-000000000202'::uuid,repeat('3',64)),
  ('30000000-0000-0000-0000-000000000103'::uuid,'30000000-0000-0000-0000-000000000203'::uuid,repeat('4',64))
) v(source_id,batch_id,fingerprint)
  on v.source_id=sf.id
where sf.organisation_id=(
  select organisation_id from outlet where code='FOOD30'
);

-- T2 item sales.
insert into staging_row(
  organisation_id,outlet_id,batch_id,source_row_no,
  raw_jsonb,parsed_jsonb,row_status
)
select b.organisation_id,b.outlet_id,b.id,v.row_no,v.raw_json,v.parsed_json,'parsed'
from import_batch b
cross join (values
  (
    2,
    '{"Item_Code":"F01","Item":"Food One","Units":"10","Net_Revenue":"100"}'::jsonb,
    '{"period":"2026-07","item_code":"F01","item_name":"Food One","product_group":"Food","population":"Food","units_sold":"10","net_revenue":"100"}'::jsonb
  ),
  (
    3,
    '{"Item_Code":"B01","Item":"Beverage One","Units":"5","Net_Revenue":"50"}'::jsonb,
    '{"period":"2026-07","item_code":"B01","item_name":"Beverage One","product_group":"Beverage","population":"Beverage","units_sold":"5","net_revenue":"50"}'::jsonb
  )
) v(row_no,raw_json,parsed_json)
where b.id='30000000-0000-0000-0000-000000000201';

-- T3 stock. Expected_Usage intentionally exists only in raw_jsonb.
insert into staging_row(
  organisation_id,outlet_id,batch_id,source_row_no,
  raw_jsonb,parsed_jsonb,row_status
)
select b.organisation_id,b.outlet_id,b.id,v.row_no,v.raw_json,v.parsed_json,'parsed'
from import_batch b
cross join (values
  (
    2,
    '{"Product_Group":"Food","Opening_Inventory":"10","Purchases":"70","Closing_Inventory":"20","Revenue":"100","Budget_Cost_Pct":"0.30","Expected_Usage":"55"}'::jsonb,
    '{"period":"2026-07","product_group":"Food","opening_inventory":"10","purchases":"70","closing_inventory":"20","source_product_revenue":"100","source_budget_cost_pct":"0.30"}'::jsonb
  ),
  (
    3,
    '{"Product_Group":"Beverage","Opening_Inventory":"5","Purchases":"30","Closing_Inventory":"10","Revenue":"50","Budget_Cost_Pct":"0.20","Expected_Usage":"22"}'::jsonb,
    '{"period":"2026-07","product_group":"Beverage","opening_inventory":"5","purchases":"30","closing_inventory":"10","source_product_revenue":"50","source_budget_cost_pct":"0.20"}'::jsonb
  )
) v(row_no,raw_json,parsed_json)
where b.id='30000000-0000-0000-0000-000000000202';

-- T4A approved item costs.
insert into staging_row(
  organisation_id,outlet_id,batch_id,source_row_no,
  raw_jsonb,parsed_jsonb,row_status
)
select b.organisation_id,b.outlet_id,b.id,v.row_no,v.raw_json,v.parsed_json,'parsed'
from import_batch b
cross join (values
  (
    2,
    '{"Item_Code":"F01","Item":"Food One","Approved_Cost_per_Unit":"5"}'::jsonb,
    '{"period":"2026-07","item_code":"F01","item_name":"Food One","effective_from":"2026-07-01","effective_from_basis":"fixed_default","approved_cost_per_unit":"5"}'::jsonb
  ),
  (
    3,
    '{"Item_Code":"B01","Item":"Beverage One","Approved_Cost_per_Unit":"4"}'::jsonb,
    '{"period":"2026-07","item_code":"B01","item_name":"Beverage One","effective_from":"2026-07-01","effective_from_basis":"fixed_default","approved_cost_per_unit":"4"}'::jsonb
  )
) v(row_no,raw_json,parsed_json)
where b.id='30000000-0000-0000-0000-000000000203';


set role restaurant_app;
select set_config('app.user_id','30000000-0000-0000-0000-000000000001',true);

select * from commit_food_cost_import_batch(
  '30000000-0000-0000-0000-000000000201',
  'fc30-commit-t2-01','fc30-test'
);
select * from commit_food_cost_import_batch(
  '30000000-0000-0000-0000-000000000202',
  'fc30-commit-t3-01','fc30-test'
);
select * from commit_food_cost_import_batch(
  '30000000-0000-0000-0000-000000000203',
  'fc30-commit-t4a1','fc30-test'
);

select fc30_eq(
  (select count(*) from item_sales_fact
   where batch_id='30000000-0000-0000-0000-000000000201'),
  2,'T2 commits two immutable item-sales facts'
);
select fc30_eq(
  (select count(*) from stock_fact
   where batch_id='30000000-0000-0000-0000-000000000202'),
  2,'T3 commits two immutable stock facts'
);
select fc30_eq(
  (select count(*) from item_cost_snapshot
   where batch_id='30000000-0000-0000-0000-000000000203'),
  2,'T4A commits two immutable item-cost snapshots'
);
select fc30_eq(
  (select count(*) from item
   where outlet_id=(select id from outlet where code='FOOD30')),
  2,'canonical item identities are reused across T2 and T4A'
);
select fc30_text(
  (select status from data_readiness
   where outlet_id=(select id from outlet where code='FOOD30')
     and period_id=(select id from reporting_period
       where outlet_id=(select id from outlet where code='FOOD30')
         and period_start='2026-07-01')
     and capability_code='food_cost_inputs'),
  'ready','food-cost input readiness becomes ready after T2 T3 T4A commit'
);
select fc30_text(
  (select details_json->>'expected_usage_source' from data_readiness
   where outlet_id=(select id from outlet where code='FOOD30')
     and period_id=(select id from reporting_period
       where outlet_id=(select id from outlet where code='FOOD30')
         and period_start='2026-07-01')
     and capability_code='food_cost_inputs'),
  'DERIVED_T2_X_T4A','readiness states expected usage derivation explicitly'
);

-- Same idempotency key returns the original commit rather than duplicating facts.
select fc30_true(
  (select reused from commit_food_cost_import_batch(
    '30000000-0000-0000-0000-000000000201',
    'fc30-commit-t2-01','fc30-test'
  )),
  'food-cost commit is idempotent'
);
select fc30_eq(
  (select count(*) from item_sales_fact
   where batch_id='30000000-0000-0000-0000-000000000201'),
  2,'idempotent retry creates no duplicate facts'
);

-- Every canonical fact retains one-to-one staging lineage.
select fc30_eq(
  (
    select count(*)
    from item_sales_fact f
    join staging_row s
      on s.id=f.staging_row_id and s.batch_id=f.batch_id
    where f.batch_id='30000000-0000-0000-0000-000000000201'
  ),
  2,'T2 facts trace to staging rows'
);
select fc30_eq(
  (
    select count(*)
    from stock_fact f
    join staging_row s
      on s.id=f.staging_row_id and s.batch_id=f.batch_id
    where f.batch_id='30000000-0000-0000-0000-000000000202'
  ),
  2,'T3 facts trace to staging rows'
);
select fc30_eq(
  (
    select count(*)
    from item_cost_snapshot f
    join staging_row s
      on s.id=f.staging_row_id and s.batch_id=f.batch_id
    where f.batch_id='30000000-0000-0000-0000-000000000203'
  ),
  2,'T4A facts trace to staging rows'
);

select fc30_true(
  not exists(
    select 1 from information_schema.columns
    where table_schema='public'
      and table_name='stock_fact'
      and column_name='expected_usage'
  ),
  'stock_fact has no canonical Expected Usage field'
);
select fc30_true(
  exists(
    select 1 from staging_row
    where batch_id='30000000-0000-0000-0000-000000000202'
      and raw_jsonb ? 'Expected_Usage'
      and not (parsed_jsonb ? 'expected_usage')
  ),
  'T3 fixture Expected Usage remains raw evidence only'
);

select fc30_rejects(
  $q$ update stock_fact set purchases=0
      where batch_id='30000000-0000-0000-0000-000000000202' $q$,
  'committed stock facts are immutable'
);
select fc30_rejects(
  $q$ update item set item_name='rewrite'
      where outlet_id=(select id from outlet where code='FOOD30') $q$,
  'canonical item identity is immutable'
);
select fc30_rejects(
  $q$ insert into stock_fact(
      organisation_id,outlet_id,period_id,product_group,
      opening_inventory,purchases,closing_inventory,
      batch_id,profile_version_id,staging_row_id
    )
    select organisation_id,outlet_id,period_id,'forged',0,0,0,
      id,profile_version_id,
      (select id from staging_row where batch_id=import_batch.id limit 1)
    from import_batch
    where id='30000000-0000-0000-0000-000000000202' $q$,
  'restaurant_app cannot directly write canonical stock facts'
);

reset role;

-- A parsed expected_usage key is explicitly rejected, even though raw source may
-- contain an Expected_Usage column for demo/reference purposes.
insert into source_file(
  id,organisation_id,outlet_id,template_code,
  storage_bucket,storage_path,original_filename,sha256,
  content_type,size_bytes,uploaded_by,
  detected_file_type,row_count,malware_scan_status,
  malware_scanner,malware_scanned_at,inspection_json
)
select
  '30000000-0000-0000-0000-000000000104',
  o.organisation_id,o.id,'T3','uploads',
  'org/'||o.organisation_id::text||'/outlet/'||o.id::text||
  '/source/30000000-0000-0000-0000-000000000104/bad-t3.csv',
  'bad-t3.csv',repeat('d',64),'text/csv',100,
  '30000000-0000-0000-0000-000000000001',
  'csv',1,'clean','ci',now(),'{}'
from outlet o where o.code='FOOD30';

insert into import_batch(
  id,organisation_id,outlet_id,source_file_id,template_code,
  profile_version_id,period_id,scenario,status,detected_fingerprint
)
select
  '30000000-0000-0000-0000-000000000204',
  sf.organisation_id,sf.outlet_id,sf.id,'T3',
  sp.active_profile_version_id,rp.id,'actual','ready',repeat('3',64)
from source_file sf
join source_profile sp
  on sp.organisation_id=sf.organisation_id
 and sp.outlet_id=sf.outlet_id and sp.template_code='T3'
join reporting_period rp
  on rp.organisation_id=sf.organisation_id
 and rp.outlet_id=sf.outlet_id and rp.period_start='2026-08-01'
where sf.id='30000000-0000-0000-0000-000000000104';

insert into staging_row(
  organisation_id,outlet_id,batch_id,source_row_no,
  raw_jsonb,parsed_jsonb,row_status
)
select organisation_id,outlet_id,id,2,
  '{"Product_Group":"Food","Expected_Usage":"55"}',
  '{"period":"2026-08","product_group":"Food","opening_inventory":"10","purchases":"70","closing_inventory":"20","expected_usage":"55"}',
  'parsed'
from import_batch
where id='30000000-0000-0000-0000-000000000204';

set role restaurant_app;
select set_config('app.user_id','30000000-0000-0000-0000-000000000001',true);
select fc30_rejects(
  $q$ select * from commit_food_cost_import_batch(
    '30000000-0000-0000-0000-000000000204',
    'fc30-bad-t3-key','fc30-test'
  ) $q$,
  'parsed T3 expected_usage cannot enter canonical commit'
);
select fc30_eq(
  (select count(*) from stock_fact
   where batch_id='30000000-0000-0000-0000-000000000204'),
  0,'rejected T3 expected_usage commit leaves zero canonical facts'
);
reset role;


-- Atomicity: use an otherwise valid August T2 batch and inject a failure after
-- every one of the eight transaction stages. Each attempt must roll back facts,
-- commit metadata and idempotency evidence.
insert into source_file(
  id,organisation_id,outlet_id,template_code,
  storage_bucket,storage_path,original_filename,sha256,
  content_type,size_bytes,uploaded_by,
  detected_file_type,row_count,malware_scan_status,
  malware_scanner,malware_scanned_at,inspection_json
)
select
  '30000000-0000-0000-0000-000000000105',
  o.organisation_id,o.id,'T2','uploads',
  'org/'||o.organisation_id::text||'/outlet/'||o.id::text||
  '/source/30000000-0000-0000-0000-000000000105/fault-t2.csv',
  'fault-t2.csv',repeat('e',64),'text/csv',100,
  '30000000-0000-0000-0000-000000000001',
  'csv',1,'clean','ci',now(),'{}'
from outlet o where o.code='FOOD30';

insert into import_batch(
  id,organisation_id,outlet_id,source_file_id,template_code,
  profile_version_id,period_id,scenario,status,detected_fingerprint
)
select
  '30000000-0000-0000-0000-000000000205',
  sf.organisation_id,sf.outlet_id,sf.id,'T2',
  sp.active_profile_version_id,rp.id,'actual','ready',repeat('2',64)
from source_file sf
join source_profile sp
  on sp.organisation_id=sf.organisation_id
 and sp.outlet_id=sf.outlet_id and sp.template_code='T2'
join reporting_period rp
  on rp.organisation_id=sf.organisation_id
 and rp.outlet_id=sf.outlet_id and rp.period_start='2026-08-01'
where sf.id='30000000-0000-0000-0000-000000000105';

insert into staging_row(
  organisation_id,outlet_id,batch_id,source_row_no,
  raw_jsonb,parsed_jsonb,row_status
)
select organisation_id,outlet_id,id,2,
  '{"Item_Code":"F01","Units":"1","Net_Revenue":"10"}',
  '{"period":"2026-08","item_code":"F01","item_name":"Food One","product_group":"Food","units_sold":"1","net_revenue":"10"}',
  'parsed'
from import_batch
where id='30000000-0000-0000-0000-000000000205';

reset role;
do $$
declare
  step_no int;
  rows_now bigint;
  state_now text;
begin
  perform set_config('app.user_id','30000000-0000-0000-0000-000000000001',true);
  for step_no in 1..8 loop
    begin
      perform *
      from public._commit_food_cost_import_batch(
        '30000000-0000-0000-0000-000000000205',
        'fc30-fault-'||step_no::text,
        'fc30-test',
        step_no
      );
      raise exception 'fault step % unexpectedly succeeded',step_no;
    exception when others then
      if sqlerrm not like 'FAULT_STEP_%' then
        raise;
      end if;
    end;

    select count(*) into rows_now
    from item_sales_fact
    where batch_id='30000000-0000-0000-0000-000000000205';

    select status::text into state_now
    from import_batch
    where id='30000000-0000-0000-0000-000000000205';

    if rows_now<>0 or state_now<>'ready' then
      raise exception
        'FAIL atomic rollback at step % -- facts %, state %',
        step_no,rows_now,state_now;
    end if;
  end loop;
  raise notice 'PASS food-cost commit rolls back atomically at all eight stages';
end
$$;

rollback;
