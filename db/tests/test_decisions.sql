\set ON_ERROR_STOP on
begin;

create or replace function t17_eq(actual bigint, expected bigint, label text)
returns void language plpgsql as $$
begin
  if actual <> expected then
    raise exception 'FAIL % expected % got %',label,expected,actual;
  end if;
  raise notice 'PASS %',label;
end $$;

create or replace function t17_text(actual text, expected text, label text)
returns void language plpgsql as $$
begin
  if actual is distinct from expected then
    raise exception 'FAIL % expected % got %',label,expected,actual;
  end if;
  raise notice 'PASS %',label;
end $$;

create or replace function t17_rejects(stmt text, label text)
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
values ('17000000-0000-0000-0000-000000000001','Decision Admin','decision@example.com',false);

set role restaurant_app;
select set_config('app.user_id','17000000-0000-0000-0000-000000000001',true);

select * from bootstrap_organisation(
  'Decision Org','decision-org','Decision Outlet','DEC',
  'USD'::char(3),'UTC',1::smallint,'decision-bootstrap-1','decision-test'
);

insert into reporting_period(
  organisation_id,outlet_id,period_start,period_end,label
)
select organisation_id,id,'2026-07-01','2026-07-31','July 2026'
from outlet where code='DEC';

reset role;

insert into restaurant_context(
  id,organisation_id,outlet_id,version_no,effective_from,created_by
)
select
  '17000000-0000-0000-0000-000000000101',
  organisation_id,id,1,'2026-01-01',
  '17000000-0000-0000-0000-000000000001'
from outlet where code='DEC';

insert into calc_run(
  id,organisation_id,outlet_id,period_id,engine_version,
  settings_snapshot,comparator_scenario,status
)
select
  '17000000-0000-0000-0000-000000000201',
  o.organisation_id,o.id,rp.id,'pl-v1',
  '{"materiality":{"general":{"absolute_threshold":"1000","percent_threshold":"0.10"}}}',
  'budget','queued'
from outlet o
join reporting_period rp
  on rp.organisation_id=o.organisation_id and rp.outlet_id=o.id
where o.code='DEC';

update calc_run
set status='running',started_at=now()
where id='17000000-0000-0000-0000-000000000201';

insert into calc_result(
  id,organisation_id,outlet_id,run_id,
  calc_id,grain_type,grain_key,value_numeric,unit,currency_code,
  calculation_status,evidence_status,result_metadata,raw_delta,profit_effect
)
select
  v.id,o.organisation_id,o.id,
  '17000000-0000-0000-0000-000000000201',
  v.calc_id,'management_pl_variance',
  jsonb_build_object(
    'ladder_code',v.ladder_code,
    'actual_scenario','actual',
    'comparator_scenario','budget'
  ),
  v.effect,'currency','USD','CALCULATED','supported','{}',
  v.effect,v.effect
from outlet o
cross join (values
  ('17000000-0000-0000-0000-000000000301'::uuid,'PL.VAR.NET_SALES','NET_SALES',-3500::numeric),
  ('17000000-0000-0000-0000-000000000302'::uuid,'PL.VAR.PRODUCT_COST','PRODUCT_COST',-3374::numeric),
  ('17000000-0000-0000-0000-000000000303'::uuid,'PL.VAR.DIRECT_LABOUR','DIRECT_LABOUR',-5205::numeric),
  ('17000000-0000-0000-0000-000000000304'::uuid,'PL.VAR.SHARED_RESTAURANT_COST','SHARED_RESTAURANT_COST',-2092::numeric),
  ('17000000-0000-0000-0000-000000000305'::uuid,'PL.VAR.OWNER_STRUCTURAL_COST','OWNER_STRUCTURAL_COST',0::numeric)
) v(id,calc_id,ladder_code,effect)
where o.code='DEC';

update calc_run
set status='completed',completed_at=now(),result_hash=repeat('1',64)
where id='17000000-0000-0000-0000-000000000201';

insert into review(
  id,organisation_id,outlet_id,period_id,status,comparator_scenario,
  context_version_id,materiality_snapshot,active_calc_run_id,
  review_leader_id,frame_confirmed_at
)
select
  '17000000-0000-0000-0000-000000000401',
  o.organisation_id,o.id,rp.id,'in_review','budget',
  '17000000-0000-0000-0000-000000000101',
  '{"general":{"absolute_threshold":"1000","percent_threshold":"0.10"}}',
  '17000000-0000-0000-0000-000000000201',
  '17000000-0000-0000-0000-000000000001',
  now()
from outlet o
join reporting_period rp
  on rp.organisation_id=o.organisation_id and rp.outlet_id=o.id
where o.code='DEC';

insert into review_issue(
  id,organisation_id,outlet_id,review_id,
  source_calc_run_id,source_calc_result_id,title,
  movement_amount,movement_rate,ladder_code,module,
  materiality_reason,materiality_rules,shortlist_order,
  evidence_status,created_by
)
select
  v.issue_id,o.organisation_id,o.id,
  '17000000-0000-0000-0000-000000000401',
  '17000000-0000-0000-0000-000000000201',
  v.result_id,v.title,v.effect,0.10,v.ladder_code,'PL',
  'amount_test','["amount_test"]',v.ord,v.evidence_status,
  '17000000-0000-0000-0000-000000000001'
from outlet o
cross join (values
  ('17000000-0000-0000-0000-000000000501'::uuid,'17000000-0000-0000-0000-000000000301'::uuid,'Net sales',-3500::numeric,'NET_SALES',1,'supported'),
  ('17000000-0000-0000-0000-000000000502'::uuid,'17000000-0000-0000-0000-000000000302'::uuid,'Product cost',-3374::numeric,'PRODUCT_COST',2,'evidence_required'),
  ('17000000-0000-0000-0000-000000000503'::uuid,'17000000-0000-0000-0000-000000000303'::uuid,'Labour',-5205::numeric,'DIRECT_LABOUR',3,'supported'),
  ('17000000-0000-0000-0000-000000000504'::uuid,'17000000-0000-0000-0000-000000000304'::uuid,'Shared costs',-2092::numeric,'SHARED_RESTAURANT_COST',4,'evidence_required'),
  ('17000000-0000-0000-0000-000000000505'::uuid,'17000000-0000-0000-0000-000000000305'::uuid,'Owner costs',0::numeric,'OWNER_STRUCTURAL_COST',5,'supported')
) v(issue_id,result_id,title,effect,ladder_code,ord,evidence_status)
where o.code='DEC';


set role restaurant_app;
select set_config('app.user_id','17000000-0000-0000-0000-000000000001',true);

select * from record_issue_diagnosis(
  '17000000-0000-0000-0000-000000000501',
  'supported','rate_price','validated',
  'Validated rate/price bridge supports the diagnosed movement',
  null,null,
  'decision-diagnosis-act-1','decision-test'
);

select * from create_evidence_request(
  '17000000-0000-0000-0000-000000000502',
  'Daily purchasing and usage detail',
  'Establish whether the product-cost movement is operating or mix related',
  '["business_date","item","quantity","cost"]'::jsonb,
  'Kitchen Manager','2026-08-10',
  'decision-evidence-request-1','decision-test'
);


reset role;

select t17_rejects($q$
  insert into decision(
    organisation_id,outlet_id,review_issue_id,version_no,disposition,
    diagnosis_id,decision_text,owner,lever,verification_metric,due_date,decided_by
  )
  select
    ri.organisation_id,ri.outlet_id,ri.id,1,'ACT',
    (select id from diagnosis d where d.review_issue_id=ri.id order by version_no desc limit 1),
    'Act on the supported driver','General Manager','Adjust price','Food cost %','2026-08-15',
    '17000000-0000-0000-0000-000000000001'
  from review_issue ri where ri.id='17000000-0000-0000-0000-000000000501'
$q$,'ACT without guardrail is rejected by database constraint');

select t17_rejects($q$
  insert into decision(
    organisation_id,outlet_id,review_issue_id,version_no,disposition,
    decision_text,owner,due_date,decided_by
  )
  select
    organisation_id,outlet_id,id,1,'INVESTIGATE',
    'Collect evidence before acting','Kitchen Manager','2026-08-10',
    '17000000-0000-0000-0000-000000000001'
  from review_issue where id='17000000-0000-0000-0000-000000000502'
$q$,'INVESTIGATE without evidence request is rejected');

select t17_rejects($q$
  insert into decision(
    organisation_id,outlet_id,review_issue_id,version_no,disposition,
    decision_text,cadence,decided_by
  )
  select
    organisation_id,outlet_id,id,1,'MONITOR',
    'Monitor without acting','weekly',
    '17000000-0000-0000-0000-000000000001'
  from review_issue where id='17000000-0000-0000-0000-000000000503'
$q$,'MONITOR without trigger is rejected');

select t17_rejects($q$
  insert into decision(
    organisation_id,outlet_id,review_issue_id,version_no,disposition,
    decision_text,owner,consequence_of_waiting,due_date,decided_by
  )
  select
    organisation_id,outlet_id,id,1,'ESCALATE',
    'Escalate to owner','Finance Director','Tariff exposure continues','2026-08-05',
    '17000000-0000-0000-0000-000000000001'
  from review_issue where id='17000000-0000-0000-0000-000000000504'
$q$,'ESCALATE without decision-required field is rejected');

select t17_rejects($q$
  insert into decision(
    organisation_id,outlet_id,review_issue_id,version_no,disposition,
    decision_text,forecast_treatment,decided_by
  )
  select
    organisation_id,outlet_id,id,1,'CLOSE',
    'Explained one-off movement','Return to normal level',
    '17000000-0000-0000-0000-000000000001'
  from review_issue where id='17000000-0000-0000-0000-000000000505'
$q$,'CLOSE without closure evidence is rejected');


set role restaurant_app;
select set_config('app.user_id','17000000-0000-0000-0000-000000000001',true);

select t17_rejects($q$
  select * from record_issue_decision(
    '17000000-0000-0000-0000-000000000502',
    'ACT',
    'Do not act until evidence exists',
    'Kitchen Manager',
    'Change purchasing',
    'Protect guest quality',
    'Product cost %',
    null,
    '2026-08-15',
    'weekly',
    null,null,null,null,null,
    'decision-bad-evidence-act',
    'decision-test'
  )
$q$,'evidence-required issue cannot be ACT');


select * from record_issue_decision(
  '17000000-0000-0000-0000-000000000501',
  'ACT',
  'Adjust the supported pricing lever and verify the result',
  'General Manager',
  'Adjust price architecture',
  'Protect guest value score',
  'Net sales and contribution',
  null,
  '2026-08-15',
  'weekly',
  null,null,null,null,null,
  'decision-act-valid-1',
  'decision-test'
);

select * from record_issue_decision(
  '17000000-0000-0000-0000-000000000502',
  'INVESTIGATE',
  'Collect the evidence needed to resolve the product-cost cause',
  'Kitchen Manager',
  null,null,null,null,
  '2026-08-10',
  null,
  (select id from evidence_request
   where review_issue_id='17000000-0000-0000-0000-000000000502'),
  null,null,null,null,
  'decision-investigate-valid-1',
  'decision-test'
);

select * from record_issue_decision(
  '17000000-0000-0000-0000-000000000503',
  'MONITOR',
  'No intervention now; reopen if overtime exceeds the agreed trigger',
  null,null,null,null,
  'Overtime exceeds 160 hours',
  null,
  'weekly',
  null,null,null,null,null,
  'decision-monitor-valid-1',
  'decision-test'
);

select * from record_issue_decision(
  '17000000-0000-0000-0000-000000000504',
  'ESCALATE',
  'Escalate the tariff decision beyond outlet authority',
  'Finance Director',
  null,null,null,null,
  '2026-08-05',
  null,null,
  'Approve fixed-rate contract option',
  'Current tariff exposure continues until renewal',
  null,null,
  'decision-escalate-valid-1',
  'decision-test'
);

select * from record_issue_decision(
  '17000000-0000-0000-0000-000000000505',
  'CLOSE',
  'Close as an explained structural cost with no local action',
  null,null,null,null,null,
  null,null,null,null,null,
  'Keep structural cost in forecast',
  'Supported contract schedule and invoice',
  'decision-close-valid-1',
  'decision-test'
);

select t17_eq(
  (select count(*) from decision),
  5,
  'five shortlisted issues each have one decision revision'
);

select t17_eq(
  (select count(*) from review_issue where active_decision_id is not null),
  5,
  'each shortlisted issue exposes exactly one active disposition'
);

select t17_text(
  (select disposition::text
   from decision
   where id=(select active_decision_id from review_issue
             where id='17000000-0000-0000-0000-000000000502')),
  'INVESTIGATE',
  'active decision points to the selected disposition'
);

select * from record_issue_decision(
  '17000000-0000-0000-0000-000000000501',
  'ACT','ignored on idempotent retry',
  null,null,null,null,null,null,null,null,null,null,null,null,
  'decision-act-valid-1',
  'decision-retry'
);

select t17_eq(
  (select count(*) from decision
   where review_issue_id='17000000-0000-0000-0000-000000000501'),
  1,
  'decision retry is idempotent'
);

select * from record_issue_decision(
  '17000000-0000-0000-0000-000000000501',
  'MONITOR',
  'Supported issue now moves to monitor with a reopening trigger',
  null,null,null,null,
  'Net sales adverse movement exceeds 2 percent next month',
  null,
  'monthly',
  null,null,null,null,null,
  'decision-monitor-revision-2',
  'decision-test'
);

select t17_eq(
  (select count(*) from decision
   where review_issue_id='17000000-0000-0000-0000-000000000501'),
  2,
  'decision revision appends rather than rewriting history'
);

select t17_text(
  (select disposition::text
   from decision
   where id=(select active_decision_id from review_issue
             where id='17000000-0000-0000-0000-000000000501')),
  'MONITOR',
  'latest revision becomes the one active disposition'
);

reset role;

select t17_rejects($q$
  update decision
  set decision_text='rewritten history'
  where review_issue_id='17000000-0000-0000-0000-000000000501'
    and version_no=1
$q$,'decision history is immutable');

rollback;
