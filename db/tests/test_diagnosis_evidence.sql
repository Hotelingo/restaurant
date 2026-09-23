\set ON_ERROR_STOP on
begin;

create or replace function t16_eq(actual bigint, expected bigint, label text)
returns void language plpgsql as $$
begin
  if actual <> expected then
    raise exception 'FAIL % expected % got %',label,expected,actual;
  end if;
  raise notice 'PASS %',label;
end $$;

create or replace function t16_text(actual text, expected text, label text)
returns void language plpgsql as $$
begin
  if actual is distinct from expected then
    raise exception 'FAIL % expected % got %',label,expected,actual;
  end if;
  raise notice 'PASS %',label;
end $$;

create or replace function t16_rejects(stmt text, label text)
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
values ('16000000-0000-0000-0000-000000000001','Evidence Admin','evidence@example.com',false);

set role restaurant_app;
select set_config('app.user_id','16000000-0000-0000-0000-000000000001',true);

select * from bootstrap_organisation(
  'Evidence Org','evidence-org','Evidence Outlet','EVID',
  'USD'::char(3),'UTC',1::smallint,'evidence-bootstrap-1','evidence-test'
);

insert into reporting_period(
  organisation_id,outlet_id,period_start,period_end,label
)
select organisation_id,id,'2026-07-01','2026-07-31','July 2026'
from outlet where code='EVID';

reset role;

insert into restaurant_context(
  id,organisation_id,outlet_id,version_no,effective_from,created_by
)
select
  '16000000-0000-0000-0000-000000000101',
  organisation_id,id,1,'2026-01-01',
  '16000000-0000-0000-0000-000000000001'
from outlet where code='EVID';

insert into calc_run(
  id,organisation_id,outlet_id,period_id,engine_version,
  settings_snapshot,comparator_scenario,status
)
select
  '16000000-0000-0000-0000-000000000201',
  o.organisation_id,o.id,rp.id,'pl-v1',
  '{"materiality":{"general":{"absolute_threshold":"1000","percent_threshold":"0.10"}}}',
  'budget','queued'
from outlet o
join reporting_period rp
  on rp.organisation_id=o.organisation_id and rp.outlet_id=o.id
where o.code='EVID';

update calc_run
set status='running',started_at=now()
where id='16000000-0000-0000-0000-000000000201';

insert into calc_result(
  id,organisation_id,outlet_id,run_id,
  calc_id,grain_type,grain_key,value_numeric,unit,currency_code,
  calculation_status,evidence_status,result_metadata,raw_delta,profit_effect
)
select
  '16000000-0000-0000-0000-000000000301',
  organisation_id,id,'16000000-0000-0000-0000-000000000201',
  'PL.VAR.NET_SALES','management_pl_variance',
  '{"ladder_code":"NET_SALES","actual_scenario":"actual","comparator_scenario":"budget"}',
  -3500,'currency','USD','CALCULATED','supported','{}',-3500,-3500
from outlet where code='EVID';

update calc_run
set status='completed',completed_at=now(),result_hash=repeat('1',64)
where id='16000000-0000-0000-0000-000000000201';

insert into review(
  id,organisation_id,outlet_id,period_id,status,comparator_scenario,
  context_version_id,materiality_snapshot,active_calc_run_id,
  review_leader_id,frame_confirmed_at
)
select
  '16000000-0000-0000-0000-000000000401',
  o.organisation_id,o.id,rp.id,'in_review','budget',
  '16000000-0000-0000-0000-000000000101',
  '{"general":{"absolute_threshold":"1000","percent_threshold":"0.10"}}',
  '16000000-0000-0000-0000-000000000201',
  '16000000-0000-0000-0000-000000000001',
  now()
from outlet o
join reporting_period rp
  on rp.organisation_id=o.organisation_id and rp.outlet_id=o.id
where o.code='EVID';

insert into review_issue(
  id,organisation_id,outlet_id,review_id,
  source_calc_run_id,source_calc_result_id,title,
  movement_amount,movement_rate,ladder_code,module,
  materiality_reason,materiality_rules,shortlist_order,
  evidence_status,created_by
)
select
  '16000000-0000-0000-0000-000000000501',
  o.organisation_id,o.id,
  '16000000-0000-0000-0000-000000000401',
  '16000000-0000-0000-0000-000000000201',
  '16000000-0000-0000-0000-000000000301',
  'Net Sales',-3500,0.01508621,'NET_SALES','PL',
  'amount_test','["amount_test"]',1,'supported',
  '16000000-0000-0000-0000-000000000001'
from outlet o where o.code='EVID';


set role restaurant_app;
select set_config('app.user_id','16000000-0000-0000-0000-000000000001',true);

-- Hypotheses stay explicitly unconfirmed.
select * from record_issue_diagnosis(
  '16000000-0000-0000-0000-000000000501',
  'hypothesis','mix','partly_supported',
  null,'Lower dinner mix may explain part of the sales movement',
  'Need meal-period sales evidence',
  'diagnosis-hypothesis-1','evidence-test'
);

select t16_text(
  (select diagnosis_state from diagnosis
   where review_issue_id='16000000-0000-0000-0000-000000000501'
   and version_no=1),
  'hypothesis',
  'diagnosis distinguishes a hypothesis from a supported conclusion'
);

select t16_text(
  (select diagnostic_status from diagnosis
   where review_issue_id='16000000-0000-0000-0000-000000000501'
   and version_no=1),
  'in_progress',
  'partly supported hypothesis is not decision-ready'
);

-- Retry is idempotent.
select * from record_issue_diagnosis(
  '16000000-0000-0000-0000-000000000501',
  'hypothesis','mix','partly_supported',
  null,'Lower dinner mix may explain part of the sales movement',
  'Need meal-period sales evidence',
  'diagnosis-hypothesis-1','evidence-test-retry'
);

select t16_eq(
  (select count(*) from diagnosis
   where review_issue_id='16000000-0000-0000-0000-000000000501'),
  1,
  'diagnosis retry does not append another version'
);

-- Unsupported/partly-supported evidence may be recorded but contributes zero.
select * from add_driver_evidence(
  '16000000-0000-0000-0000-000000000501',
  'mix','management_report','meal-period-sales',
  'partly_supported',500,'Observed movement, not yet validated',
  'driver-evidence-partly-1','evidence-test'
);

select t16_text(
  (select reconciliation_impact::text from driver_evidence
   where evidence_source_id='meal-period-sales'),
  '0.0000',
  'partly-supported evidence contributes zero quantitatively'
);

select * from add_driver_evidence(
  '16000000-0000-0000-0000-000000000501',
  'mix','requested_dataset','meal-period-detail',
  'evidence_required',null,'Evidence still required',
  'driver-evidence-required-1','evidence-test'
);

select t16_text(
  (select reconciliation_impact::text from driver_evidence
   where evidence_source_id='meal-period-detail'),
  '0.0000',
  'evidence-required evidence contributes zero'
);

select t16_rejects($q$
  select * from add_driver_evidence(
    '16000000-0000-0000-0000-000000000501',
    'mix','requested_dataset','bad-quantification',
    'evidence_required',100,'Must be disabled',
    'driver-evidence-bad-1','evidence-test'
  )
$q$,'evidence-required input cannot store a quantified impact');

-- New management reasoning appends version 2; it never rewrites version 1.
select * from record_issue_diagnosis(
  '16000000-0000-0000-0000-000000000501',
  'supported','rate_price','validated',
  'Validated pricing and volume bridge supports a rate/price driver',
  null,null,
  'diagnosis-supported-2','evidence-test'
);

select t16_eq(
  (select count(*) from diagnosis
   where review_issue_id='16000000-0000-0000-0000-000000000501'),
  2,
  'revised diagnosis appends a second immutable version'
);

select t16_text(
  (select diagnosis_state from diagnosis
   where review_issue_id='16000000-0000-0000-0000-000000000501'
   and version_no=1),
  'hypothesis',
  'original diagnosis remains unchanged'
);

select t16_text(
  (select diagnostic_status from diagnosis
   where review_issue_id='16000000-0000-0000-0000-000000000501'
   and version_no=2),
  'ready_for_decision',
  'validated supported diagnosis becomes decision-ready'
);

select * from add_driver_evidence(
  '16000000-0000-0000-0000-000000000501',
  'rate_price','validated_bridge','revenue-bridge-v1',
  'validated',943,'Validated against source reports',
  'driver-evidence-validated-1','evidence-test'
);

select t16_text(
  (select reconciliation_impact::text from driver_evidence
   where evidence_source_id='revenue-bridge-v1'),
  '943.0000',
  'validated evidence can enter quantitative reconciliation'
);


-- Evidence request captures dataset, minimum fields, owner and due date.
select * from create_evidence_request(
  '16000000-0000-0000-0000-000000000501',
  'Daily meal-period sales',
  'Confirm whether the hypothesised mix movement persists by service period',
  '["business_date","meal_period","net_sales","covers"]'::jsonb,
  'Restaurant Manager',
  '2026-08-10',
  'evidence-request-0001','evidence-test'
);

select t16_text(
  (select owner from evidence_request
   where review_issue_id='16000000-0000-0000-0000-000000000501'),
  'Restaurant Manager',
  'evidence request stores an accountable owner'
);

select t16_eq(
  (select jsonb_array_length(minimum_fields) from evidence_request
   where review_issue_id='16000000-0000-0000-0000-000000000501'),
  4,
  'evidence request stores minimum required fields'
);

select t16_text(
  (select evidence_status from review_issue
   where id='16000000-0000-0000-0000-000000000501'),
  'evidence_required',
  'open evidence request makes the issue evidence-required'
);

select t16_rejects($q$
  select * from create_evidence_request(
    '16000000-0000-0000-0000-000000000501',
    'Bad request','Missing field definition','[""]'::jsonb,
    'Restaurant Manager','2026-08-10',
    'evidence-request-bad1','evidence-test'
  )
$q$,'blank minimum-field entries are rejected');

reset role;

-- Build a committed evidence batch from the same outlet. It may be from a
-- different reporting period; evidence fulfillment is not falsely restricted
-- to the reviewed accounting month.
insert into source_profile(organisation_id,outlet_id,template_code,source_label)
select organisation_id,id,'T6','Evidence support'
from outlet where code='EVID';

insert into profile_version(
  organisation_id,outlet_id,source_profile_id,version_no,
  layout_json,fingerprint_hash,fingerprint_components_json,
  transform_config_json,status,approved_by,approved_at
)
select
  organisation_id,outlet_id,id,1,'{}',repeat('2',64),'{}','[]',
  'approved','16000000-0000-0000-0000-000000000001',now()
from source_profile where source_label='Evidence support';

insert into source_file(
  id,organisation_id,outlet_id,template_code,
  storage_bucket,storage_path,original_filename,sha256,
  content_type,size_bytes,uploaded_by,
  detected_file_type,row_count,malware_scan_status,
  malware_scanner,malware_scanned_at,inspection_json
)
select
  '16000000-0000-0000-0000-000000000601',
  o.organisation_id,o.id,'T6','uploads',
  'org/'||o.organisation_id::text||'/outlet/'||o.id::text||
    '/source/16000000-0000-0000-0000-000000000601/evidence.csv',
  'evidence.csv',repeat('3',64),'text/csv',100,
  '16000000-0000-0000-0000-000000000001',
  'csv',1,'clean','clamav',now(),'{}'
from outlet o where o.code='EVID';

insert into import_batch(
  id,organisation_id,outlet_id,source_file_id,template_code,
  profile_version_id,period_id,scenario,status,detected_fingerprint,
  committed_by,committed_at,canonical_commit_hash,canonical_commit_summary
)
select
  '16000000-0000-0000-0000-000000000701',
  sf.organisation_id,sf.outlet_id,sf.id,'T6',
  pv.id,rp.id,'budget','committed',repeat('2',64),
  '16000000-0000-0000-0000-000000000001',now(),repeat('4',64),
  '{"evidence_fixture":true}'
from source_file sf
join source_profile sp
  on sp.organisation_id=sf.organisation_id
 and sp.outlet_id=sf.outlet_id
 and sp.source_label='Evidence support'
join profile_version pv on pv.source_profile_id=sp.id
join reporting_period rp
  on rp.organisation_id=sf.organisation_id and rp.outlet_id=sf.outlet_id
where sf.id='16000000-0000-0000-0000-000000000601';

set role restaurant_app;
select set_config('app.user_id','16000000-0000-0000-0000-000000000001',true);

select * from fulfill_evidence_request(
  (select id from evidence_request
   where review_issue_id='16000000-0000-0000-0000-000000000501'),
  '16000000-0000-0000-0000-000000000701',
  'evidence-fulfill-0001','evidence-test'
);

select t16_text(
  (select status from evidence_request
   where review_issue_id='16000000-0000-0000-0000-000000000501'),
  'fulfilled',
  'evidence request links to a committed fulfilling batch'
);

select t16_eq(
  (select count(*) from evidence_request
   where fulfilled_batch_id='16000000-0000-0000-0000-000000000701'),
  1,
  'fulfilling batch linkage persists'
);

-- Application sessions are read-only on evidence history.
select t16_rejects($q$
  insert into driver_evidence(
    organisation_id,outlet_id,review_issue_id,diagnosis_id,
    driver_taxonomy_id,evidence_source_type,evidence_source_id,
    evidence_status,created_by
  )
  select
    ri.organisation_id,ri.outlet_id,ri.id,
    (select id from diagnosis d where d.review_issue_id=ri.id order by version_no desc limit 1),
    (select id from driver_taxonomy where code='mix'),
    'injected','injected','evidence_required',
    '16000000-0000-0000-0000-000000000001'
  from review_issue ri
  where ri.id='16000000-0000-0000-0000-000000000501'
$q$,'application role cannot bypass controlled evidence writes');

reset role;

select t16_rejects($q$
  update diagnosis
  set hypothesis_summary='rewritten'
  where review_issue_id='16000000-0000-0000-0000-000000000501'
    and version_no=1
$q$,'diagnosis history is immutable');

select t16_rejects($q$
  update driver_evidence
  set quantified_impact=1
  where evidence_source_id='revenue-bridge-v1'
$q$,'driver evidence is immutable');

rollback;
