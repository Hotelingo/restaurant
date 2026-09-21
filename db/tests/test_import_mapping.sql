\set ON_ERROR_STOP on

begin;

create or replace function test_assert_eq6(actual bigint, expected bigint, label text)
returns void language plpgsql as $$
begin
  if actual <> expected then
    raise exception 'FAIL % -- expected %, got %', label, expected, actual;
  end if;
  raise notice 'PASS  %', label;
end $$;

create or replace function test_assert_rejects6(stmt text, label text)
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

insert into neon_auth."user" (id,name,email) values
  ('60000000-0000-0000-0000-000000000001','Mapping Admin A','mapping-a@example.com'),
  ('60000000-0000-0000-0000-000000000002','Mapping Admin B','mapping-b@example.com');

insert into ladder_framework(code,name) values ('RPR-MAP-TEST','Mapping test framework');
insert into ladder_line(framework_id,code,name,kind,display_order,is_calculated)
select id,'MAP.TEST.NET_SALES','Net Sales','revenue',1,false
from ladder_framework where code='RPR-MAP-TEST';

set role restaurant_app;
select set_config('app.user_id','60000000-0000-0000-0000-000000000001',true);

select * from bootstrap_organisation(
  'Mapping Org A','mapping-org-a','Outlet A','MA',
  'USD'::char(3),'UTC',1::smallint,'mapping-bootstrap-a','mapping-test'
);

insert into source_profile(
  organisation_id,outlet_id,template_code,source_label
)
select o.organisation_id,o.id,'T1','Customer P&L'
from outlet o where o.code='MA';

insert into profile_version(
  organisation_id,outlet_id,source_profile_id,version_no,
  layout_json,fingerprint_hash,fingerprint_components_json,transform_config_json
)
select sp.organisation_id,sp.outlet_id,sp.id,1,
       '{"orientation":"wide_months"}'::jsonb,
       repeat('a',64),
       '{"sheet_name":"csv","headers":["account code","account name","july 2026"]}'::jsonb,
       '[]'::jsonb
from source_profile sp where sp.source_label='Customer P&L';

insert into column_mapping(
  organisation_id,outlet_id,profile_version_id,source_column,canonical_field,required
)
select pv.organisation_id,pv.outlet_id,pv.id,'Account_Name','account_name',true
from profile_version pv where pv.version_no=1;

insert into account_mapping(
  organisation_id,outlet_id,profile_version_id,
  source_account_code,source_account_name,ladder_line_id,mapping_basis,approved_by
)
select pv.organisation_id,pv.outlet_id,pv.id,
       null,'Food sales',
       ll.id,'confirmed','60000000-0000-0000-0000-000000000001'
from profile_version pv
cross join ladder_line ll
where pv.version_no=1 and ll.code='MAP.TEST.NET_SALES';

select test_assert_rejects6($q$
  insert into account_mapping(
    organisation_id,outlet_id,profile_version_id,
    source_account_code,source_account_name,ladder_line_id,mapping_basis,approved_by
  )
  select pv.organisation_id,pv.outlet_id,pv.id,
         null,'Food sales',
         ll.id,'confirmed','60000000-0000-0000-0000-000000000001'
  from profile_version pv
  cross join ladder_line ll
  where pv.version_no=1 and ll.code='MAP.TEST.NET_SALES'
$q$, 'duplicate name-only account mapping is rejected with NULLS NOT DISTINCT');

insert into item_mapping(
  organisation_id,outlet_id,profile_version_id,
  source_item_code,source_item_name,canonical_item_key,mapping_basis,approved_by
)
select pv.organisation_id,pv.outlet_id,pv.id,
       'F01','Ribeye Steak','ITEM:RIBEYE','confirmed',
       '60000000-0000-0000-0000-000000000001'
from profile_version pv where pv.version_no=1;

insert into value_mapping(
  organisation_id,outlet_id,profile_version_id,
  field_name,source_value,canonical_value
)
select pv.organisation_id,pv.outlet_id,pv.id,
       'Population','Bev','Beverage'
from profile_version pv where pv.version_no=1;

insert into transform_rule(
  organisation_id,outlet_id,profile_version_id,
  sequence_no,transform_code,target_field,params_json
)
select pv.organisation_id,pv.outlet_id,pv.id,
       1,'unpivot_month_columns',null,'{}'::jsonb
from profile_version pv where pv.version_no=1;

select test_assert_rejects6($q$
  insert into transform_rule(
    organisation_id,outlet_id,profile_version_id,
    sequence_no,transform_code,target_field,params_json
  )
  select pv.organisation_id,pv.outlet_id,pv.id,
         2,'python','Amount','{}'::jsonb
  from profile_version pv where pv.version_no=1
$q$, 'transform table rejects arbitrary executable transform code');

select test_assert_eq6(
  (select count(*) from information_schema.columns
   where table_schema='public'
     and table_name in ('account_mapping','item_mapping')
     and column_name ilike '%amount%'),
  0,
  'mapping persistence has no amount-based identity column'
);

select test_assert_rejects6($q$
  update source_profile sp
  set active_profile_version_id = pv.id
  from profile_version pv
  where pv.source_profile_id=sp.id and pv.version_no=1
$q$, 'draft profile version cannot become active');

update profile_version
set status='approved',
    approved_by='60000000-0000-0000-0000-000000000001',
    approved_at=now()
where version_no=1;

update source_profile sp
set active_profile_version_id=pv.id
from profile_version pv
where pv.source_profile_id=sp.id and pv.version_no=1;

select test_assert_eq6(
  (select count(*) from source_profile where active_profile_version_id is not null),
  1,
  'approved profile version can become active'
);

reset role;

select test_assert_rejects6($q$
  update profile_version set fingerprint_hash=repeat('b',64) where version_no=1
$q$, 'approved profile version is immutable even for owner/service path');

select test_assert_rejects6($q$
  update account_mapping set source_account_name='Changed' where source_account_name='Food sales'
$q$, 'approved account mapping is immutable even for owner/service path');

select test_assert_rejects6($q$
  delete from value_mapping where source_value='Bev'
$q$, 'approved value mapping cannot be deleted even for owner/service path');

select test_assert_rejects6($q$
  insert into column_mapping(
    organisation_id,outlet_id,profile_version_id,source_column,canonical_field,required
  )
  select pv.organisation_id,pv.outlet_id,pv.id,'Amount','amount',true
  from profile_version pv where pv.version_no=1
$q$, 'approved profile cannot receive a new mapping child');

set role restaurant_app;
select set_config('app.user_id','60000000-0000-0000-0000-000000000001',true);

insert into profile_version(
  organisation_id,outlet_id,source_profile_id,version_no,
  layout_json,fingerprint_hash,fingerprint_components_json,transform_config_json,
  supersedes_profile_version_id
)
select sp.organisation_id,sp.outlet_id,sp.id,2,
       '{"orientation":"wide_months"}'::jsonb,
       repeat('c',64),
       '{"sheet_name":"csv","headers":["account code","account name","august 2026"]}'::jsonb,
       '[]'::jsonb,
       sp.active_profile_version_id
from source_profile sp where sp.source_label='Customer P&L';

select test_assert_rejects6($q$
  update source_profile sp
  set active_profile_version_id = pv.id
  from profile_version pv
  where pv.source_profile_id=sp.id and pv.version_no=2
$q$, 'unapproved successor cannot replace active approved profile');

reset role;

-- Composite tenancy must reject cross-organisation/outlet rows independently of RLS.
select set_config('app.user_id','60000000-0000-0000-0000-000000000002',true);
set role restaurant_app;
select * from bootstrap_organisation(
  'Mapping Org B','mapping-org-b','Outlet B','MB',
  'USD'::char(3),'UTC',1::smallint,'mapping-bootstrap-b','mapping-test'
);
reset role;

select test_assert_rejects6($q$
  insert into source_profile(
    organisation_id,outlet_id,template_code,source_label
  )
  select
    (select id from organisation where slug='mapping-org-a'),
    (select id from outlet where code='MB'),
    'T1','Cross tenant'
$q$, 'source profile rejects cross-organisation outlet');

rollback;
