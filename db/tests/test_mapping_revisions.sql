\set ON_ERROR_STOP on
begin;

create or replace function test_assert_eq41(actual bigint, expected bigint, label text)
returns void language plpgsql as $$
begin
  if actual <> expected then
    raise exception 'FAIL % -- expected %, got %', label, expected, actual;
  end if;
  raise notice 'PASS %', label;
end $$;

create or replace function test_assert_text41(actual text, expected text, label text)
returns void language plpgsql as $$
begin
  if actual is distinct from expected then
    raise exception 'FAIL % -- expected %, got %', label, expected, actual;
  end if;
  raise notice 'PASS %', label;
end $$;

-- Runs a statement that must fail with the given SQLSTATE. Any other outcome,
-- including success, fails the test.
create or replace function test_expect_error41(statement text, expected_state text, label text)
returns void language plpgsql as $$
declare
  v_state text;
begin
  begin
    execute statement;
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate;
    if v_state <> expected_state then
      raise exception 'FAIL % -- expected SQLSTATE %, got % (%)', label, expected_state, v_state, sqlerrm;
    end if;
    raise notice 'PASS %', label;
    return;
  end;
  raise exception 'FAIL % -- statement succeeded but should have failed', label;
end $$;

grant execute on function test_expect_error41(text,text,text) to restaurant_app;

insert into neon_auth."user"(id,name,email,"emailVerified") values
('d0000000-0000-0000-0000-000000000001','Revision Admin','revision@example.com',false),
('d0000000-0000-0000-0000-000000000002','Revision Viewer','viewer@example.com',false),
('d0000000-0000-0000-0000-000000000003','Other Tenant','other@example.com',false);

set role restaurant_app;
select set_config('app.user_id','d0000000-0000-0000-0000-000000000001',true);

select * from bootstrap_organisation(
  'Revision Org','revision-org','Revision Outlet','REV',
  'USD'::char(3),'UTC',1::smallint,'revision-bootstrap-1','revision-test'
);

insert into reporting_period(organisation_id,outlet_id,period_start,period_end,label)
select organisation_id,id,'2026-07-01','2026-07-31','July 2026'
from outlet where code='REV';

-- Version 1 of a T1 layout: two accounts, created through the normal upload path.
insert into source_file(
  id,organisation_id,outlet_id,template_code,storage_bucket,storage_path,
  original_filename,sha256,content_type,size_bytes,uploaded_by,
  detected_file_type,row_count,malware_scan_status,malware_scanner,
  malware_scanned_at,inspection_json
)
select
  'd0000000-0000-0000-0000-000000000101',organisation_id,id,'T1','uploads',
  'org/'||organisation_id::text||'/outlet/'||id::text||
  '/source/d0000000-0000-0000-0000-000000000101/pnl.csv',
  'pnl.csv',repeat('1',64),'text/csv',200,
  'd0000000-0000-0000-0000-000000000001',
  'csv',3,'clean','clamav',now(),'{}'
from outlet where code='REV';

insert into import_batch(
  id,organisation_id,outlet_id,source_file_id,template_code,period_id,scenario,
  status,detected_fingerprint,parse_metadata_json,
  profile_match_tier,profile_match_message,parse_completed_at
)
select
  'd0000000-0000-0000-0000-000000000201',
  sf.organisation_id,sf.outlet_id,sf.id,'T1',rp.id,'actual','needs_mapping',
  repeat('a',64),
  jsonb_build_object(
    'headers',jsonb_build_array('Account_Code','Account_Name','July_2026'),
    'selected_sheet_name','__csv__',
    'field_map',jsonb_build_object('Account_Code','account_code','Account_Name','account_name'),
    'month_columns',jsonb_build_array('July_2026'),
    'target_period','2026-07',
    'fingerprint_components',jsonb_build_object(
      'sheet_name','__csv__',
      'ordered_headers',jsonb_build_array('account code','account name','july 2026'),
      'header_row',1,'orientation','wide_months',
      'key_set_hash',repeat('f',64),'column_count',3,'template_code','T1',
      'source_keys',jsonb_build_array('code:4000','code:5000')
    )
  ),
  'different_layout','No approved profile matched',now()
from source_file sf
join reporting_period rp
  on rp.organisation_id=sf.organisation_id and rp.outlet_id=sf.outlet_id
where sf.id='d0000000-0000-0000-0000-000000000101';

insert into staging_row(
  organisation_id,outlet_id,batch_id,source_row_no,raw_jsonb,parsed_jsonb,row_status
)
select b.organisation_id,b.outlet_id,b.id,v.n,'{}',v.parsed,'parsed'
from import_batch b
cross join (values
  (2,'{"period":"2026-07","account_code":"4000","account_name":"Food sales","amount":"100"}'::jsonb),
  (3,'{"period":"2026-07","account_code":"5000","account_name":"Packaging","amount":"30"}'::jsonb)
) v(n,parsed)
where b.id='d0000000-0000-0000-0000-000000000201';

select * from confirm_financial_mapping(
  'd0000000-0000-0000-0000-000000000201',
  'revision-first-run-1','Main P&L',null,
  jsonb_build_array(
    jsonb_build_object('source_account_code','4000','source_account_name','Food sales','ladder_line_code','NET_SALES'),
    jsonb_build_object('source_account_code','5000','source_account_name','Packaging','ladder_line_code','PRODUCT_COST')
  ),
  '[]'::jsonb,'revision-test'
);

create temporary table v1 on commit drop as
select pv.id, pv.source_profile_id
from profile_version pv
join source_profile sp on sp.id=pv.source_profile_id
where sp.source_label='Main P&L' and pv.version_no=1;

-- A revision moves "Packaging" from Product Cost to Other Direct Operating.
create temporary table rev on commit drop as
select * from revise_profile_mappings(
  (select id from v1),
  'revision-change-1',
  jsonb_build_array(jsonb_build_object(
    'source_identity_key','code:5000','ladder_line_code','OTHER_DIRECT_OPERATING'
  )),
  '[]'::jsonb,
  'revision-test'
);

select test_assert_eq41((select revised_version_no from rev), 2, 'revision creates version 2');
select test_assert_text41((select reused::text from rev), 'false', 'first revision is not a replay');

select test_assert_text41(
  (select pv.status from profile_version pv where pv.id=(select revised_profile_version_id from rev)),
  'approved','revised version is approved'
);

select test_assert_text41(
  (select sp.active_profile_version_id::text from source_profile sp where sp.id=(select source_profile_id from v1)),
  (select revised_profile_version_id::text from rev),
  'revised version becomes the active version for future uploads'
);

select test_assert_text41(
  (select supersedes_profile_version_id::text from profile_version where id=(select revised_profile_version_id from rev)),
  (select id::text from v1),
  'revised version records the version it supersedes'
);

select test_assert_text41(
  (select fingerprint_hash from profile_version where id=(select revised_profile_version_id from rev)),
  (select fingerprint_hash from profile_version where id=(select id from v1)),
  'revision keeps the layout fingerprint so the same file still matches'
);

select test_assert_text41(
  (select ll.code from account_mapping am join ladder_line ll on ll.id=am.ladder_line_id
   where am.profile_version_id=(select revised_profile_version_id from rev)
     and am.source_identity_key='code:5000'),
  'OTHER_DIRECT_OPERATING','changed account carries the new P&L line'
);

select test_assert_text41(
  (select ll.code from account_mapping am join ladder_line ll on ll.id=am.ladder_line_id
   where am.profile_version_id=(select revised_profile_version_id from rev)
     and am.source_identity_key='code:4000'),
  'NET_SALES','unchanged account is carried over'
);

select test_assert_text41(
  (select ll.code from account_mapping am join ladder_line ll on ll.id=am.ladder_line_id
   where am.profile_version_id=(select id from v1)
     and am.source_identity_key='code:5000'),
  'PRODUCT_COST','version 1 is untouched, so committed months keep their mapping'
);

select test_assert_eq41(
  (select count(*) from column_mapping where profile_version_id=(select revised_profile_version_id from rev)),
  (select count(*) from column_mapping where profile_version_id=(select id from v1)),
  'column mappings are carried over'
);

select test_assert_eq41(
  (select count(*) from transform_rule where profile_version_id=(select revised_profile_version_id from rev)),
  1,'layout transforms are carried over'
);

select test_assert_eq41(
  (select count(*) from audit_log
   where action_code='IMPORT_MAPPING_REVISED'
     and object_id=(select revised_profile_version_id::text from rev)),
  1,'revision is audited'
);

-- Replaying the same request returns the same version and creates nothing.
select test_assert_text41(
  (select revised_profile_version_id::text || ':' || reused::text from revise_profile_mappings(
     (select id from v1),'revision-change-1',
     jsonb_build_array(jsonb_build_object(
       'source_identity_key','code:5000','ladder_line_code','OTHER_DIRECT_OPERATING')),
     '[]'::jsonb,'revision-test-retry')),
  (select revised_profile_version_id::text from rev) || ':true',
  'revision is idempotent'
);

select test_assert_eq41(
  (select count(*) from profile_version where source_profile_id=(select source_profile_id from v1)),
  2,'idempotent replay creates no extra version'
);

-- Revising a version that is no longer active is refused (stale screen).
select test_expect_error41(
  format($s$select * from revise_profile_mappings(%L,'revision-stale-1',
    jsonb_build_array(jsonb_build_object('source_identity_key','code:4000','ladder_line_code','PRODUCT_COST')),
    '[]'::jsonb,null)$s$, (select id from v1)),
  '23514','a superseded version cannot be revised'
);

-- A change that changes nothing is refused.
select test_expect_error41(
  format($s$select * from revise_profile_mappings(%L,'revision-noop-1',
    jsonb_build_array(jsonb_build_object('source_identity_key','code:4000','ladder_line_code','NET_SALES')),
    '[]'::jsonb,null)$s$, (select revised_profile_version_id from rev)),
  '23514','a revision with no effective change is refused'
);

-- An empty revision is refused.
select test_expect_error41(
  format($s$select * from revise_profile_mappings(%L,'revision-empty-1','[]'::jsonb,'[]'::jsonb,null)$s$,
    (select revised_profile_version_id from rev)),
  '23514','an empty revision is refused'
);

-- Calculated lines (subtotals) can never be a mapping target.
select test_expect_error41(
  format($s$select * from revise_profile_mappings(%L,'revision-calc-1',
    jsonb_build_array(jsonb_build_object('source_identity_key','code:4000','ladder_line_code','CONTRIBUTION')),
    '[]'::jsonb,null)$s$, (select revised_profile_version_id from rev)),
  '23514','a calculated P&L line is refused'
);

-- Only identities already in the version can be changed; new ones come from uploads.
select test_expect_error41(
  format($s$select * from revise_profile_mappings(%L,'revision-unknown-1',
    jsonb_build_array(jsonb_build_object('source_identity_key','code:9999','ladder_line_code','NET_SALES')),
    '[]'::jsonb,null)$s$, (select revised_profile_version_id from rev)),
  '23514','an account not in the version is refused'
);

select test_expect_error41(
  format($s$select * from revise_profile_mappings(%L,'revision-dup-1',
    jsonb_build_array(
      jsonb_build_object('source_identity_key','code:4000','ladder_line_code','PRODUCT_COST'),
      jsonb_build_object('source_identity_key','code:4000','ladder_line_code','CHANNEL_COST')),
    '[]'::jsonb,null)$s$, (select revised_profile_version_id from rev)),
  '23514','the same account twice in one revision is refused'
);

select test_expect_error41(
  format($s$select * from revise_profile_mappings(%L,'revision-field-1','[]'::jsonb,
    jsonb_build_array(jsonb_build_object('field_name','account_name','source_value','x','canonical_value','y')),
    null)$s$, (select revised_profile_version_id from rev)),
  '23514','an unsupported value field is refused'
);

select test_expect_error41(
  format($s$select * from revise_profile_mappings(%L,'short',
    jsonb_build_array(jsonb_build_object('source_identity_key','code:4000','ladder_line_code','PRODUCT_COST')),
    '[]'::jsonb,null)$s$, (select revised_profile_version_id from rev)),
  '22023','a short idempotency key is refused'
);

-- The approved history itself stays immutable.
select test_expect_error41(
  format($s$update account_mapping set source_account_name='Tampered' where profile_version_id=%L$s$,
    (select revised_profile_version_id from rev)),
  '23001','approved revision mappings cannot be edited in place'
);

-- A viewer of the same organisation can read but cannot revise.
reset role;
insert into membership(organisation_id,user_id,role)
select organisation_id,'d0000000-0000-0000-0000-000000000002','viewer'
from outlet where code='REV';
set role restaurant_app;
select set_config('app.user_id','d0000000-0000-0000-0000-000000000002',true);

select test_assert_eq41(
  (select count(*) from profile_version where id=(select revised_profile_version_id from rev)),
  1,'viewer can read the mapping version'
);

select test_expect_error41(
  format($s$select * from revise_profile_mappings(%L,'revision-viewer-1',
    jsonb_build_array(jsonb_build_object('source_identity_key','code:4000','ladder_line_code','PRODUCT_COST')),
    '[]'::jsonb,null)$s$, (select revised_profile_version_id from rev)),
  '42501','a viewer cannot revise mappings'
);

-- An admin of another organisation cannot see or revise this one.
select set_config('app.user_id','d0000000-0000-0000-0000-000000000003',true);
select * from bootstrap_organisation(
  'Other Org','other-org','Other Outlet','OTH',
  'USD'::char(3),'UTC',1::smallint,'revision-bootstrap-2','revision-test'
);

select test_assert_eq41(
  (select count(*) from profile_version where id=(select revised_profile_version_id from rev)),
  0,'another tenant cannot read the mapping version'
);

select test_expect_error41(
  format($s$select * from revise_profile_mappings(%L,'revision-tenant-1',
    jsonb_build_array(jsonb_build_object('source_identity_key','code:4000','ladder_line_code','PRODUCT_COST')),
    '[]'::jsonb,null)$s$, (select revised_profile_version_id from rev)),
  '42501','another tenant cannot revise mappings'
);

-- restaurant_app has no read access to request_idempotency; check as owner.
reset role;
select test_assert_eq41(
  (select count(*) from request_idempotency where operation like 'mapping.revise:%'
     and user_id in ('d0000000-0000-0000-0000-000000000002','d0000000-0000-0000-0000-000000000003')),
  0,'refused callers leave no idempotency record'
);
set role restaurant_app;

-- Ladder-grain (T6) management-line values can be revised too.
select set_config('app.user_id','d0000000-0000-0000-0000-000000000001',true);

insert into source_file(
  id,organisation_id,outlet_id,template_code,storage_bucket,storage_path,
  original_filename,sha256,content_type,size_bytes,uploaded_by,
  detected_file_type,row_count,malware_scan_status,malware_scanner,
  malware_scanned_at,inspection_json
)
select
  'd0000000-0000-0000-0000-000000000102',organisation_id,id,'T6','uploads',
  'org/'||organisation_id::text||'/outlet/'||id::text||
  '/source/d0000000-0000-0000-0000-000000000102/budget.csv',
  'budget.csv',repeat('2',64),'text/csv',200,
  'd0000000-0000-0000-0000-000000000001',
  'csv',3,'clean','clamav',now(),'{}'
from outlet where code='REV';

insert into import_batch(
  id,organisation_id,outlet_id,source_file_id,template_code,period_id,scenario,
  status,detected_fingerprint,parse_metadata_json,
  profile_match_tier,profile_match_message,parse_completed_at
)
select
  'd0000000-0000-0000-0000-000000000202',
  sf.organisation_id,sf.outlet_id,sf.id,'T6',rp.id,'budget','needs_mapping',
  repeat('c',64),
  jsonb_build_object(
    'headers',jsonb_build_array('Line','July_2026'),
    'selected_sheet_name','__csv__',
    'field_map',jsonb_build_object('Line','management_line'),
    'month_columns',jsonb_build_array('July_2026'),
    'target_period','2026-07',
    'fingerprint_components',jsonb_build_object(
      'sheet_name','__csv__',
      'ordered_headers',jsonb_build_array('line','july 2026'),
      'header_row',1,'orientation','wide_months',
      'key_set_hash',repeat('d',64),'column_count',2,'template_code','T6',
      'source_keys',jsonb_build_array('name:sales','name:cogs')
    )
  ),
  'different_layout','No approved profile matched',now()
from source_file sf
join reporting_period rp
  on rp.organisation_id=sf.organisation_id and rp.outlet_id=sf.outlet_id
where sf.id='d0000000-0000-0000-0000-000000000102';

insert into staging_row(
  organisation_id,outlet_id,batch_id,source_row_no,raw_jsonb,parsed_jsonb,row_status
)
select b.organisation_id,b.outlet_id,b.id,v.n,'{}',v.parsed,'parsed'
from import_batch b
cross join (values
  (2,'{"period":"2026-07","management_line":"Sales","amount":"100"}'::jsonb),
  (3,'{"period":"2026-07","management_line":"COGS","amount":"30"}'::jsonb)
) v(n,parsed)
where b.id='d0000000-0000-0000-0000-000000000202';

select * from confirm_financial_mapping(
  'd0000000-0000-0000-0000-000000000202',
  'revision-budget-1','Budget lines',null,'[]'::jsonb,
  jsonb_build_array(
    jsonb_build_object('source_value','Sales','ladder_line_code','NET_SALES'),
    jsonb_build_object('source_value','COGS','ladder_line_code','CHANNEL_COST')
  ),
  'revision-test'
);

create temporary table budget_rev on commit drop as
select * from revise_profile_mappings(
  (select sp.active_profile_version_id from source_profile sp where sp.source_label='Budget lines'),
  'revision-budget-change-1','[]'::jsonb,
  jsonb_build_array(jsonb_build_object(
    'field_name','management_line','source_value','COGS','canonical_value','PRODUCT_COST'
  )),
  'revision-test'
);

select test_assert_text41(
  (select canonical_value from value_mapping
   where profile_version_id=(select revised_profile_version_id from budget_rev)
     and field_name='management_line' and source_value='COGS'),
  'PRODUCT_COST','management-line value revision is applied'
);

select test_assert_text41(
  (select canonical_value from value_mapping
   where profile_version_id=(select revised_profile_version_id from budget_rev)
     and field_name='management_line' and source_value='Sales'),
  'NET_SALES','unchanged management-line value is carried over'
);

select test_expect_error41(
  format($s$select * from revise_profile_mappings(%L,'revision-budget-bad-1','[]'::jsonb,
    jsonb_build_array(jsonb_build_object('field_name','management_line','source_value','Sales','canonical_value','OPERATING_PROFIT')),
    null)$s$, (select revised_profile_version_id from budget_rev)),
  '23514','a management line cannot target a calculated P&L line'
);

rollback;
