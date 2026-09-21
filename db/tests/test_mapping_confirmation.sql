\set ON_ERROR_STOP on
begin;

create or replace function test_assert_eq12(actual bigint, expected bigint, label text)
returns void language plpgsql as $$
begin
  if actual <> expected then
    raise exception 'FAIL % -- expected %, got %', label, expected, actual;
  end if;
  raise notice 'PASS %', label;
end $$;

create or replace function test_assert_text12(actual text, expected text, label text)
returns void language plpgsql as $$
begin
  if actual is distinct from expected then
    raise exception 'FAIL % -- expected %, got %', label, expected, actual;
  end if;
  raise notice 'PASS %', label;
end $$;

insert into neon_auth."user"(id,name,email,"emailVerified") values
('c0000000-0000-0000-0000-000000000001','Mapping Admin','mapping@example.com',false);

set role restaurant_app;
select set_config('app.user_id','c0000000-0000-0000-0000-000000000001',true);

select * from bootstrap_organisation(
  'Mapping Org','mapping-org','Mapping Outlet','MAP',
  'USD'::char(3),'UTC',1::smallint,'mapping-bootstrap-1','mapping-test'
);

insert into reporting_period(organisation_id,outlet_id,period_start,period_end,label)
select organisation_id,id,'2026-07-01','2026-07-31','July 2026'
from outlet where code='MAP';

insert into source_file(
  id,organisation_id,outlet_id,template_code,storage_bucket,storage_path,
  original_filename,sha256,content_type,size_bytes,uploaded_by,
  detected_file_type,row_count,malware_scan_status,malware_scanner,
  malware_scanned_at,inspection_json
)
select
  'c0000000-0000-0000-0000-000000000101',organisation_id,id,'T1','uploads',
  'org/'||organisation_id::text||'/outlet/'||id::text||
  '/source/c0000000-0000-0000-0000-000000000101/pnl.csv',
  'pnl.csv',repeat('1',64),'text/csv',200,
  'c0000000-0000-0000-0000-000000000001',
  'csv',3,'clean','clamav',now(),'{}'
from outlet where code='MAP';

insert into import_batch(
  id,organisation_id,outlet_id,source_file_id,template_code,period_id,scenario,
  status,detected_fingerprint,parse_metadata_json,
  profile_match_tier,profile_match_message,parse_completed_at
)
select
  'c0000000-0000-0000-0000-000000000201',
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
where sf.id='c0000000-0000-0000-0000-000000000101';

insert into staging_row(
  organisation_id,outlet_id,batch_id,source_row_no,raw_jsonb,parsed_jsonb,row_status
)
select b.organisation_id,b.outlet_id,b.id,v.n,v.raw,v.parsed,'parsed'
from import_batch b
cross join (values
  (2,'{}'::jsonb,'{"period":"2026-07","account_code":"4000","account_name":"Food sales","amount":"100"}'::jsonb),
  (3,'{}'::jsonb,'{"period":"2026-07","account_code":"5000","account_name":"Food cost","amount":"30"}'::jsonb)
) v(n,raw,parsed)
where b.id='c0000000-0000-0000-0000-000000000201';

select * from confirm_financial_mapping(
  'c0000000-0000-0000-0000-000000000201',
  'mapping-first-run-1','Main P&L',null,
  jsonb_build_array(
    jsonb_build_object('source_account_code','4000','source_account_name','Food sales','ladder_line_code','NET_SALES'),
    jsonb_build_object('source_account_code','5000','source_account_name','Food cost','ladder_line_code','PRODUCT_COST')
  ),
  '[]'::jsonb,'mapping-test'
);

select test_assert_eq12(
  (select count(*) from profile_version pv join source_profile sp on sp.id=pv.source_profile_id
   where sp.source_label='Main P&L' and pv.status='approved'),
  1,'first-run mapping creates one approved profile'
);

select test_assert_eq12(
  (select count(*) from account_mapping am join profile_version pv on pv.id=am.profile_version_id
   join source_profile sp on sp.id=pv.source_profile_id where sp.source_label='Main P&L'),
  2,'approved profile covers both source identities'
);

select test_assert_text12(
  (select status::text from import_batch where id='c0000000-0000-0000-0000-000000000201'),
  'validating','mapping confirmation advances batch'
);

select test_assert_eq12(
  (select count(*) from transform_rule tr join profile_version pv on pv.id=tr.profile_version_id
   join source_profile sp on sp.id=pv.source_profile_id
   where sp.source_label='Main P&L' and tr.transform_code='unpivot_month_columns'),
  1,'wide profile records the closed unpivot transform'
);

-- Retry with the same idempotency key cannot make another version.
select * from confirm_financial_mapping(
  'c0000000-0000-0000-0000-000000000201',
  'mapping-first-run-1',null,null,'[]','[]','mapping-retry'
);

select test_assert_eq12(
  (select count(*) from profile_version pv join source_profile sp on sp.id=pv.source_profile_id
   where sp.source_label='Main P&L'),
  1,'mapping confirmation is idempotent'
);

-- Drift/new-row path: base mappings are cloned; only the new identity is supplied.
insert into source_file(
  id,organisation_id,outlet_id,template_code,storage_bucket,storage_path,
  original_filename,sha256,content_type,size_bytes,uploaded_by,
  detected_file_type,row_count,malware_scan_status,malware_scanner,
  malware_scanned_at,inspection_json
)
select
  'c0000000-0000-0000-0000-000000000102',organisation_id,id,'T1','uploads',
  'org/'||organisation_id::text||'/outlet/'||id::text||
  '/source/c0000000-0000-0000-0000-000000000102/pnl2.csv',
  'pnl2.csv',repeat('2',64),'text/csv',250,
  'c0000000-0000-0000-0000-000000000001',
  'csv',4,'clean','clamav',now(),'{}'
from outlet where code='MAP';

insert into import_batch(
  id,organisation_id,outlet_id,source_file_id,template_code,period_id,scenario,
  status,detected_fingerprint,parse_metadata_json,profile_match_tier,
  profile_match_message,candidate_profile_version_id,parse_completed_at
)
select
  'c0000000-0000-0000-0000-000000000202',
  sf.organisation_id,sf.outlet_id,sf.id,'T1',rp.id,'actual','needs_mapping',
  repeat('b',64),
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
      'key_set_hash',repeat('e',64),'column_count',3,'template_code','T1',
      'source_keys',jsonb_build_array('code:4000','code:5000','code:6100')
    )
  ),
  'new_rows_only','New row',sp.active_profile_version_id,now()
from source_file sf
join reporting_period rp on rp.organisation_id=sf.organisation_id and rp.outlet_id=sf.outlet_id
join source_profile sp on sp.organisation_id=sf.organisation_id
 and sp.outlet_id=sf.outlet_id and sp.source_label='Main P&L'
where sf.id='c0000000-0000-0000-0000-000000000102';

insert into staging_row(
  organisation_id,outlet_id,batch_id,source_row_no,raw_jsonb,parsed_jsonb,row_status
)
select b.organisation_id,b.outlet_id,b.id,v.n,'{}',v.parsed,'parsed'
from import_batch b
cross join (values
  (2,'{"period":"2026-07","account_code":"4000","account_name":"Food sales","amount":"100"}'::jsonb),
  (3,'{"period":"2026-07","account_code":"5000","account_name":"Food cost","amount":"30"}'::jsonb),
  (4,'{"period":"2026-07","account_code":"6100","account_name":"Packaging","amount":"5"}'::jsonb)
) v(n,parsed)
where b.id='c0000000-0000-0000-0000-000000000202';

select * from confirm_financial_mapping(
  'c0000000-0000-0000-0000-000000000202',
  'mapping-new-row-1',null,null,
  jsonb_build_array(
    jsonb_build_object('source_account_code','6100','source_account_name','Packaging',
                       'ladder_line_code','OTHER_DIRECT_OPERATING')
  ),
  '[]','mapping-new-row-test'
);

select test_assert_eq12(
  (select count(*) from profile_version pv join source_profile sp on sp.id=pv.source_profile_id
   where sp.source_label='Main P&L'),
  2,'drift creates version 2'
);

select test_assert_eq12(
  (select count(*) from account_mapping am join profile_version pv on pv.id=am.profile_version_id
   join source_profile sp on sp.id=pv.source_profile_id
   where sp.source_label='Main P&L' and pv.version_no=2),
  3,'version 2 clones old mappings and adds the new identity'
);

select test_assert_eq12(
  (select count(*) from account_mapping am join profile_version pv on pv.id=am.profile_version_id
   join source_profile sp on sp.id=pv.source_profile_id
   where sp.source_label='Main P&L' and pv.version_no=1),
  2,'version 1 remains unchanged'
);

rollback;
