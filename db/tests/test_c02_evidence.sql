\set ON_ERROR_STOP on
begin;

create or replace function s82_eq(actual bigint, expected bigint, label text)
returns void language plpgsql as $$
begin
  if actual is distinct from expected then
    raise exception 'FAIL % -- expected %, got %',label,expected,actual;
  end if;
  raise notice 'PASS %',label;
end $$;

create or replace function s82_text(actual text, expected text, label text)
returns void language plpgsql as $$
begin
  if actual is distinct from expected then
    raise exception 'FAIL % -- expected %, got %',label,expected,actual;
  end if;
  raise notice 'PASS %',label;
end $$;

create or replace function s82_num(actual numeric, expected numeric, label text)
returns void language plpgsql as $$
begin
  if actual is distinct from expected then
    raise exception 'FAIL % -- expected %, got %',label,expected,actual;
  end if;
  raise notice 'PASS %',label;
end $$;

create or replace function s82_rejects(stmt text, label text)
returns void language plpgsql as $$
begin
  begin
    execute stmt;
  exception when others then
    raise notice 'PASS % (%)',label,sqlerrm;
    return;
  end;
  raise exception 'FAIL % -- statement accepted unexpectedly',label;
end $$;


insert into neon_auth."user"(id,name,email,"emailVerified")
values
  ('82000000-0000-0000-0000-000000000001','C02 Admin','c02-admin@example.com',false),
  ('82000000-0000-0000-0000-000000000002','C02 Stranger','c02-stranger@example.com',false);

set role restaurant_app;
select set_config('app.user_id','82000000-0000-0000-0000-000000000001',true);

select * from bootstrap_organisation(
  'C02 Org','c02-org',
  'C02 Outlet','C02',
  'USD'::char(3),'UTC',1::smallint,
  'c02-bootstrap-1','slice8-c02'
);

insert into reporting_period(
  id,organisation_id,outlet_id,period_start,period_end,label
)
select
  '82000000-0000-0000-0000-000000000010',
  organisation_id,id,'2026-07-01','2026-07-31','July 2026'
from outlet where code='C02';

reset role;


insert into restaurant_context(
  id,organisation_id,outlet_id,version_no,effective_from,created_by
)
select
  '82000000-0000-0000-0000-000000000101',
  organisation_id,id,1,'2026-01-01',
  '82000000-0000-0000-0000-000000000001'
from outlet where code='C02';

insert into calc_run(
  id,organisation_id,outlet_id,period_id,engine_version,
  settings_snapshot,comparator_scenario,status
)
select
  '82000000-0000-0000-0000-000000000201',
  o.organisation_id,o.id,rp.id,'pl-v1',
  '{"materiality":{"general":{"absolute_threshold":"1000","percent_threshold":"0.10"}}}',
  'budget','queued'
from outlet o
join reporting_period rp
  on rp.organisation_id=o.organisation_id and rp.outlet_id=o.id
where o.code='C02';

update calc_run
set status='running',started_at=now()
where id='82000000-0000-0000-0000-000000000201';

insert into calc_result(
  id,organisation_id,outlet_id,run_id,
  calc_id,grain_type,grain_key,value_numeric,unit,currency_code,
  calculation_status,evidence_status,result_metadata,raw_delta,profit_effect
)
select
  '82000000-0000-0000-0000-000000000301',
  organisation_id,id,'82000000-0000-0000-0000-000000000201',
  'PL.VAR.PRODUCT_COST','management_pl_variance',
  '{"ladder_code":"PRODUCT_COST","actual_scenario":"actual","comparator_scenario":"budget"}',
  943,'currency','USD','CALCULATED','supported','{}',943,-943
from outlet where code='C02';

update calc_run
set status='completed',completed_at=now(),result_hash=repeat('8',64)
where id='82000000-0000-0000-0000-000000000201';

insert into review(
  id,organisation_id,outlet_id,period_id,status,comparator_scenario,
  context_version_id,materiality_snapshot,active_calc_run_id,
  review_leader_id,frame_confirmed_at
)
select
  '82000000-0000-0000-0000-000000000401',
  o.organisation_id,o.id,rp.id,'in_review','budget',
  '82000000-0000-0000-0000-000000000101',
  '{"general":{"absolute_threshold":"1000","percent_threshold":"0.10"}}',
  '82000000-0000-0000-0000-000000000201',
  '82000000-0000-0000-0000-000000000001',
  now()
from outlet o
join reporting_period rp
  on rp.organisation_id=o.organisation_id and rp.outlet_id=o.id
where o.code='C02';

insert into review_issue(
  id,organisation_id,outlet_id,review_id,
  source_calc_run_id,source_calc_result_id,title,
  movement_amount,movement_rate,ladder_code,module,
  materiality_reason,materiality_rules,shortlist_order,
  evidence_status,created_by
)
select
  '82000000-0000-0000-0000-000000000501',
  o.organisation_id,o.id,
  '82000000-0000-0000-0000-000000000401',
  '82000000-0000-0000-0000-000000000201',
  '82000000-0000-0000-0000-000000000301',
  'Food cost bridge',943,0.01,'PRODUCT_COST','PL',
  'amount_test','["amount_test"]',1,'supported',
  '82000000-0000-0000-0000-000000000001'
from outlet o where o.code='C02';


set role restaurant_app;
select set_config('app.user_id','82000000-0000-0000-0000-000000000001',true);

select * from record_issue_diagnosis(
  '82000000-0000-0000-0000-000000000501',
  'supported','food_waste','validated',
  'Food-cost movement has supported operational evidence',
  null,null,
  's82-diagnosis-1','slice8-c02'
);


-- Legacy generic/non-food evidence remains valid with null coverage fields.
select * from add_driver_evidence(
  '82000000-0000-0000-0000-000000000501',
  'rate_price','validated_bridge','legacy-generic-bridge',
  'validated',943,'Legacy generic evidence remains forward-compatible',
  's82-legacy-evidence','slice8-c02'
);

select s82_num(
  (select reconciliation_impact from driver_evidence
   where evidence_source_id='legacy-generic-bridge'),
  943,
  'legacy generic evidence remains quantitatively valid'
);

select s82_text(
  (select coverage_key from driver_evidence
   where evidence_source_id='legacy-generic-bridge'),
  null,
  'forward-fix migration does not invent coverage for legacy rows'
);


-- Generic controlled writes cannot bypass the new food coverage contract.
select s82_rejects($q$
  select * from add_driver_evidence(
    '82000000-0000-0000-0000-000000000501',
    'food_yield','yield_sheet','generic-food-no-coverage',
    'supported',6,'Must use typed C02 path',
    's82-generic-food-supported','slice8-c02'
  )
$q$,'supported quantified food evidence cannot bypass coverage contract');

select s82_rejects($q$
  select * from add_driver_evidence(
    '82000000-0000-0000-0000-000000000501',
    'food_yield','yield_sheet','generic-food-unsupported-quant',
    'partly_supported',6,'Unsupported food observation cannot reconcile',
    's82-generic-food-partial','slice8-c02'
  )
$q$,'unsupported food evidence cannot carry quantified reconciliation');


-- Observational yield evidence stores physical inputs but contributes zero.
select * from add_c02_driver_evidence(
  '82000000-0000-0000-0000-000000000501',
  'yield','food','food:ribeye:july:yield-observation',
  'yield_test','ribeye-yield-july',
  'partly_supported',null,
  '["yield_test:ribeye-july"]'::jsonb,
  '{
    "ap_quantity":"20",
    "approved_yield":"0.72",
    "observed_usable_quantity":"14.2",
    "approved_usable_unit_cost":"30"
  }'::jsonb,
  null,
  'Observed yield 71% versus approved 72%; not yet supported for reconciliation',
  's82-yield-observation','slice8-c02'
);

select s82_num(
  (select de.reconciliation_impact
   from driver_evidence de
   where de.evidence_source_id='ribeye-yield-july'),
  0,
  'partly-supported yield observation contributes zero'
);

select s82_num(
  (select e.approved_yield
   from c02_test_evidence e
   join driver_evidence de on de.id=e.driver_evidence_id
   where de.evidence_source_id='ribeye-yield-july'),
  0.72,
  'typed yield evidence preserves approved yield'
);

select s82_num(
  (select e.observed_usable_quantity
   from c02_test_evidence e
   join driver_evidence de on de.id=e.driver_evidence_id
   where de.evidence_source_id='ribeye-yield-july'),
  14.2,
  'typed yield evidence preserves observed usable quantity'
);


-- Amberside supported kitchen-error comps/waste = 620.
select * from add_c02_driver_evidence(
  '82000000-0000-0000-0000-000000000501',
  'waste','food','food:july:kitchen-error-comps',
  'waste_log','kitchen-error-comps-july',
  'validated',620,
  '["pos_comp:KE-7","waste_log:july"]'::jsonb,
  '{
    "quantity":"620",
    "unit_cost":"1",
    "reason_code":"kitchen_error_comp",
    "already_in_approved_standard":false
  }'::jsonb,
  null,
  'Validated kitchen-error comps/waste',
  's82-waste-620','slice8-c02'
);

select s82_num(
  (select reconciliation_impact from driver_evidence
   where evidence_source_id='kitchen-error-comps-july'),
  620,
  'validated C02 waste enters reconciliation once'
);

select s82_text(
  (select coverage_key from driver_evidence
   where evidence_source_id='kitchen-error-comps-july'),
  'food:july:kitchen-error-comps',
  'validated C02 evidence persists nonblank coverage key'
);

select s82_eq(
  (select jsonb_array_length(source_refs)
   from c02_test_evidence e
   join driver_evidence de on de.id=e.driver_evidence_id
   where de.evidence_source_id='kitchen-error-comps-july'),
  2,
  'validated C02 evidence retains direct source refs'
);


-- Retry is idempotent.
select * from add_c02_driver_evidence(
  '82000000-0000-0000-0000-000000000501',
  'waste','food','food:july:kitchen-error-comps',
  'waste_log','kitchen-error-comps-july',
  'validated',620,
  '["pos_comp:KE-7","waste_log:july"]'::jsonb,
  '{
    "quantity":"620",
    "unit_cost":"1",
    "reason_code":"kitchen_error_comp",
    "already_in_approved_standard":false
  }'::jsonb,
  null,
  'Validated kitchen-error comps/waste',
  's82-waste-620','slice8-c02'
);

select s82_eq(
  (select count(*) from c02_test_evidence
   where coverage_key='food:july:kitchen-error-comps'
     and test_type='waste'),
  1,
  'C02 evidence retry does not duplicate immutable evidence'
);


-- Quantified supported evidence must be reproducible from exact typed inputs.
select s82_rejects($q$
  select * from add_c02_driver_evidence(
    '82000000-0000-0000-0000-000000000501',
    'yield','food','food:ribeye:july:yield-supported',
    'yield_test','ribeye-yield-supported',
    'supported',6,
    '["yield_test:ribeye-supported"]'::jsonb,
    '{"approved_yield":"0.72","observed_usable_quantity":"14.2"}'::jsonb,
    null,'Missing AP quantity and unit cost',
    's82-yield-missing-inputs','slice8-c02'
  )
$q$,'quantified C02 evidence requires reproducible typed inputs');

select s82_rejects($q$
  select * from add_c02_driver_evidence(
    '82000000-0000-0000-0000-000000000501',
    'waste','food','food:ribeye:july:normal-trim',
    'waste_log','normal-trim',
    'validated',20,
    '["waste_log:normal-trim"]'::jsonb,
    '{
      "quantity":"5","unit_cost":"4",
      "reason_code":"normal_trim",
      "already_in_approved_standard":true
    }'::jsonb,
    null,'Normal loss already embedded',
    's82-normal-loss','slice8-c02'
  )
$q$,'normal loss already in approved standard cannot be quantified twice');

select s82_rejects($q$
  select * from add_c02_driver_evidence(
    '82000000-0000-0000-0000-000000000501',
    'transfer_nonrevenue','food','food:july:internal-transfer',
    'transfer_log','internal-transfer-1',
    'validated',40,
    '["transfer:1"]'::jsonb,
    '{
      "quantity":"10","unit_cost":"4",
      "movement_classification":"internal_transfer"
    }'::jsonb,
    null,'Internal boundary transfer',
    's82-internal-transfer','slice8-c02'
  )
$q$,'internal transfers inside review boundary cannot be quantified');


-- Duplicate active supported coverage is blocked without reviewer override.
select s82_rejects($q$
  select * from add_c02_driver_evidence(
    '82000000-0000-0000-0000-000000000501',
    'transfer_nonrevenue','food','food:july:kitchen-error-comps',
    'transfer_log','duplicate-kitchen-error',
    'supported',620,
    '["transfer:duplicate"]'::jsonb,
    '{
      "quantity":"620","unit_cost":"1",
      "movement_classification":"approved_nonrevenue"
    }'::jsonb,
    null,'Overlapping coverage must be reviewed',
    's82-overlap-reject','slice8-c02'
  )
$q$,'overlapping active supported coverage is rejected without override');


select * from record_c02_coverage_override(
  '82000000-0000-0000-0000-000000000401',
  'food','food:july:kitchen-error-comps',
  'Reviewer confirms the two supported records intentionally cover distinct approved subcomponents despite the shared coverage key.',
  's82-overlap-override','slice8-c02'
);

select * from add_c02_driver_evidence(
  '82000000-0000-0000-0000-000000000501',
  'transfer_nonrevenue','food','food:july:kitchen-error-comps',
  'transfer_log','duplicate-kitchen-error-approved',
  'supported',620,
  '["transfer:duplicate-approved"]'::jsonb,
  '{
    "quantity":"620","unit_cost":"1",
    "movement_classification":"approved_nonrevenue"
  }'::jsonb,
  null,'Reviewer-approved overlap',
  's82-overlap-approved','slice8-c02'
);

select s82_eq(
  (select count(*) from c02_test_evidence
   where review_id='82000000-0000-0000-0000-000000000401'
     and product_group='food'
     and coverage_key='food:july:kitchen-error-comps'
     and evidence_status in ('supported','validated')),
  2,
  'immutable reviewer override permits explicit overlapping supported coverage'
);

select s82_eq(
  (select count(*) from c02_coverage_override
   where review_id='82000000-0000-0000-0000-000000000401'
     and coverage_key='food:july:kitchen-error-comps'),
  1,
  'coverage override is persisted exactly once'
);


-- Customer application role cannot bypass controlled writes.
select s82_rejects($q$
  insert into c02_test_evidence(
    organisation_id,outlet_id,review_id,review_issue_id,diagnosis_id,
    driver_evidence_id,test_type,product_group,coverage_key,evidence_status,
    created_by
  )
  select
    de.organisation_id,de.outlet_id,
    '82000000-0000-0000-0000-000000000401',
    de.review_issue_id,de.diagnosis_id,de.id,
    'waste','food','injected','validated',
    '82000000-0000-0000-0000-000000000001'
  from driver_evidence de
  where de.evidence_source_id='kitchen-error-comps-july'
$q$,'application role cannot bypass controlled C02 evidence writes');

reset role;


select s82_rejects($q$
  update c02_test_evidence
  set quantity=999
  where coverage_key='food:july:kitchen-error-comps'
$q$,'typed C02 evidence is immutable');

select s82_rejects($q$
  update c02_coverage_override
  set reason='rewritten'
  where coverage_key='food:july:kitchen-error-comps'
$q$,'coverage override is immutable');


-- Tenant isolation: a non-member application user cannot read C02 evidence.
set role restaurant_app;
select set_config('app.user_id','82000000-0000-0000-0000-000000000002',true);

select s82_eq(
  (select count(*) from c02_test_evidence),
  0,
  'C02 evidence RLS hides another tenant from a non-member'
);

select s82_eq(
  (select count(*) from c02_coverage_override),
  0,
  'C02 override RLS hides another tenant from a non-member'
);

reset role;

rollback;
