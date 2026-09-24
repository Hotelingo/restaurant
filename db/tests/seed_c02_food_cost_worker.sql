\set ON_ERROR_STOP on

-- Persistent CI fixture layered onto seed_fc_worker.sql. It creates a real
-- Management P&L review anchor and review-scoped C02 evidence without changing
-- the existing food-cost-v1 snapshots.

insert into restaurant_context(
  id,organisation_id,outlet_id,version_no,
  service_style,capacity_json,meal_periods_json,business_formats_json,
  customer_sources_json,recipe_costing_status,labour_recording_basis,
  source_tracking_quality,evidence_maturity,effective_from,created_by
)
select
  'f8000000-0000-0000-0000-000000000101',
  o.organisation_id,o.id,1,
  'casual dining','{}','[]','[]','[]',
  'recipe_costed','hours','structured','validated',
  '2026-07-01',
  'f0000000-0000-0000-0000-000000000001'
from outlet o
where o.code='FCWORKER'
  and not exists(
    select 1 from restaurant_context rc
    where rc.outlet_id=o.id and rc.version_no=1
  );

insert into calc_run(
  id,organisation_id,outlet_id,period_id,
  engine_version,settings_snapshot,comparator_scenario,status
)
select
  'f8000000-0000-0000-0000-000000000201',
  o.organisation_id,o.id,rp.id,
  'pl-v1',
  '{"materiality":{"general":{"absolute_threshold":"1000","percent_threshold":"0.10"}}}',
  'budget','queued'
from outlet o
join reporting_period rp
  on rp.organisation_id=o.organisation_id
 and rp.outlet_id=o.id
where o.code='FCWORKER';

update calc_run
set status='running',started_at=now()
where id='f8000000-0000-0000-0000-000000000201';

insert into calc_result(
  id,organisation_id,outlet_id,run_id,
  calc_id,grain_type,grain_key,value_numeric,
  unit,currency_code,calculation_status,evidence_status,
  result_metadata,input_refs,raw_delta,profit_effect
)
select
  'f8000000-0000-0000-0000-000000000301',
  o.organisation_id,o.id,
  'f8000000-0000-0000-0000-000000000201',
  'PL.VAR.PRODUCT_COST',
  'management_pl_variance',
  '{"ladder_code":"PRODUCT_COST","actual_scenario":"actual","comparator_scenario":"budget"}',
  943,'currency','USD','CALCULATED','supported',
  '{}','[]',943,-943
from outlet o where o.code='FCWORKER';

update calc_run
set status='completed',
    completed_at=now(),
    result_hash=repeat('8',64)
where id='f8000000-0000-0000-0000-000000000201';

insert into review(
  id,organisation_id,outlet_id,period_id,status,
  comparator_scenario,context_version_id,materiality_snapshot,
  active_calc_run_id,review_leader_id,frame_confirmed_at
)
select
  'f8000000-0000-0000-0000-000000000401',
  o.organisation_id,o.id,rp.id,'in_review',
  'budget',
  'f8000000-0000-0000-0000-000000000101',
  '{"general":{"absolute_threshold":"1000","percent_threshold":"0.10"}}',
  'f8000000-0000-0000-0000-000000000201',
  'f0000000-0000-0000-0000-000000000001',
  now()
from outlet o
join reporting_period rp
  on rp.organisation_id=o.organisation_id
 and rp.outlet_id=o.id
where o.code='FCWORKER';

insert into review_issue(
  id,organisation_id,outlet_id,review_id,
  source_calc_run_id,source_calc_result_id,title,
  movement_amount,movement_rate,ladder_code,module,
  materiality_reason,materiality_rules,shortlist_order,
  evidence_status,created_by
)
select
  'f8000000-0000-0000-0000-000000000501',
  o.organisation_id,o.id,
  'f8000000-0000-0000-0000-000000000401',
  'f8000000-0000-0000-0000-000000000201',
  'f8000000-0000-0000-0000-000000000301',
  'Food Cost operational bridge',
  943,0.0156,'PRODUCT_COST','PL',
  'amount_test','["amount_test"]',1,
  'supported',
  'f0000000-0000-0000-0000-000000000001'
from outlet o where o.code='FCWORKER';


set role restaurant_app;
select set_config(
  'app.user_id',
  'f0000000-0000-0000-0000-000000000001',
  false
);

select * from record_issue_diagnosis(
  'f8000000-0000-0000-0000-000000000501',
  'supported','food_waste','validated',
  'Food actual-vs-expected requires C02 physical evidence reconciliation.',
  null,null,
  'fc-c02-diagnosis','fc-c02-worker'
);

-- Supported/validated Amberside kitchen-error waste/comps.
select * from add_c02_driver_evidence(
  'f8000000-0000-0000-0000-000000000501',
  'waste',
  'food',
  'food:july:kitchen-error-comps',
  'waste_log',
  'amberside-kitchen-error-comps-july',
  'validated',
  620,
  '["pos_comp:KE-JUL","waste_log:JUL-2026"]'::jsonb,
  '{
    "quantity":"620",
    "unit_cost":"1",
    "reason_code":"kitchen_error_comp",
    "already_in_approved_standard":false
  }'::jsonb,
  null,
  'Validated kitchen-error comps/waste',
  'fc-c02-waste-620',
  'fc-c02-worker'
);

-- Observational yield evidence: 14.2 / 20 = 71% versus approved 72%.
-- It is deliberately not a quantified reconciliation driver yet.
select * from add_c02_driver_evidence(
  'f8000000-0000-0000-0000-000000000501',
  'yield',
  'food',
  'food:ribeye:july:yield-observation',
  'yield_test',
  'amberside-ribeye-yield-july',
  'partly_supported',
  null,
  '["yield_test:ribeye-july"]'::jsonb,
  '{
    "ap_quantity":"20",
    "approved_yield":"0.72",
    "observed_usable_quantity":"14.2",
    "approved_usable_unit_cost":"30"
  }'::jsonb,
  null,
  'Observed yield 71% versus approved 72%; observation only.',
  'fc-c02-yield-observation',
  'fc-c02-worker'
);

-- Observational portion evidence: 283g versus approved 280g.
select * from add_c02_driver_evidence(
  'f8000000-0000-0000-0000-000000000501',
  'portion',
  'food',
  'food:ribeye:july:portion-observation',
  'portion_test',
  'amberside-ribeye-portion-july',
  'partly_supported',
  null,
  '["portion_test:ribeye-july"]'::jsonb,
  '{
    "approved_portion":"0.280",
    "observed_avg_portion":"0.283",
    "representative_portions":"50",
    "approved_usable_unit_cost":"30"
  }'::jsonb,
  null,
  'Observed average portion 283g versus approved 280g; observation only.',
  'fc-c02-portion-observation',
  'fc-c02-worker'
);

-- Production observation intentionally lacks served/closing/non-revenue balance
-- inputs. Accounting values must never be reverse-engineered into those quantities.
select * from add_c02_driver_evidence(
  'f8000000-0000-0000-0000-000000000501',
  'production',
  'food',
  'food:july:production-observation',
  'production_sheet',
  'amberside-production-july',
  'partly_supported',
  null,
  '["production_sheet:july"]'::jsonb,
  '{"produced_quantity":"100"}'::jsonb,
  null,
  'Production quantity observed; remaining physical balance is not evidenced.',
  'fc-c02-production-observation',
  'fc-c02-worker'
);

select request_food_cost_c02_calculation(
  'f8000000-0000-0000-0000-000000000401',
  'fc-c02-run-first',
  'fc-c02-worker'
);

select request_food_cost_c02_calculation(
  'f8000000-0000-0000-0000-000000000401',
  'fc-c02-run-repeat',
  'fc-c02-worker'
);

reset role;
