\set ON_ERROR_STOP on
begin;

create or replace function t19_eq(actual bigint, expected bigint, label text)
returns void language plpgsql as $$
begin
  if actual <> expected then
    raise exception 'FAIL % expected % got %',label,expected,actual;
  end if;
  raise notice 'PASS %',label;
end $$;

create or replace function t19_text(actual text, expected text, label text)
returns void language plpgsql as $$
begin
  if actual is distinct from expected then
    raise exception 'FAIL % expected % got %',label,expected,actual;
  end if;
  raise notice 'PASS %',label;
end $$;

create or replace function t19_rejects(stmt text, label text)
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
values
  ('19000000-0000-0000-0000-000000000001','Verification Admin','verify@example.com',false),
  ('19000000-0000-0000-0000-000000000002','Other Admin','other-verify@example.com',false);

set role restaurant_app;
select set_config('app.user_id','19000000-0000-0000-0000-000000000001',true);

select * from bootstrap_organisation(
  'Verification Org','verification-org','Verification Outlet','VERIFY',
  'USD'::char(3),'UTC',1::smallint,'verification-bootstrap-1','verification-test'
);

insert into reporting_period(
  organisation_id,outlet_id,period_start,period_end,label
)
select organisation_id,id,v.period_start,v.period_end,v.label
from outlet
cross join (
  values
    ('2026-07-01'::date,'2026-07-31'::date,'July 2026'::text),
    ('2026-08-01'::date,'2026-08-31'::date,'August 2026'::text),
    ('2026-09-01'::date,'2026-09-30'::date,'September 2026'::text)
) v(period_start,period_end,label)
where code='VERIFY';

reset role;

insert into restaurant_context(
  id,organisation_id,outlet_id,version_no,effective_from,created_by
)
select
  '19000000-0000-0000-0000-000000000101',
  organisation_id,id,1,'2026-01-01',
  '19000000-0000-0000-0000-000000000001'
from outlet where code='VERIFY';

insert into calc_run(
  id,organisation_id,outlet_id,period_id,engine_version,
  settings_snapshot,comparator_scenario,status
)
select
  '19000000-0000-0000-0000-000000000201',
  o.organisation_id,o.id,rp.id,'pl-v1',
  '{"materiality":{"general":{"absolute_threshold":"1000","percent_threshold":"0.10"}}}',
  'budget','queued'
from outlet o
join reporting_period rp
  on rp.organisation_id=o.organisation_id
 and rp.outlet_id=o.id
 and rp.label='July 2026'
where o.code='VERIFY';

update calc_run
set status='running',started_at=now()
where id='19000000-0000-0000-0000-000000000201';

insert into calc_result(
  id,organisation_id,outlet_id,run_id,
  calc_id,grain_type,grain_key,value_numeric,unit,currency_code,
  calculation_status,evidence_status,result_metadata,raw_delta,profit_effect
)
select
  '19000000-0000-0000-0000-000000000301',
  organisation_id,id,'19000000-0000-0000-0000-000000000201',
  'PL.VAR.DIRECT_LABOUR','management_pl_variance',
  '{"ladder_code":"DIRECT_LABOUR","actual_scenario":"actual","comparator_scenario":"budget"}',
  -5205,'currency','USD','CALCULATED','supported','{}',-5205,-5205
from outlet where code='VERIFY';

update calc_run
set status='completed',completed_at=now(),result_hash=repeat('1',64)
where id='19000000-0000-0000-0000-000000000201';

insert into review(
  id,organisation_id,outlet_id,period_id,status,comparator_scenario,
  context_version_id,materiality_snapshot,active_calc_run_id,
  review_leader_id,frame_confirmed_at
)
select
  '19000000-0000-0000-0000-000000000401',
  o.organisation_id,o.id,rp.id,'in_review','budget',
  '19000000-0000-0000-0000-000000000101',
  '{"general":{"absolute_threshold":"1000","percent_threshold":"0.10"}}',
  '19000000-0000-0000-0000-000000000201',
  '19000000-0000-0000-0000-000000000001',
  now()
from outlet o
join reporting_period rp
  on rp.organisation_id=o.organisation_id
 and rp.outlet_id=o.id
 and rp.label='July 2026'
where o.code='VERIFY';

insert into review_issue(
  id,organisation_id,outlet_id,review_id,
  source_calc_run_id,source_calc_result_id,title,
  movement_amount,movement_rate,ladder_code,module,
  materiality_reason,materiality_rules,shortlist_order,
  evidence_status,created_by
)
select
  '19000000-0000-0000-0000-000000000501',
  organisation_id,id,
  '19000000-0000-0000-0000-000000000401',
  '19000000-0000-0000-0000-000000000201',
  '19000000-0000-0000-0000-000000000301',
  'Labour',-5205,0.10,'DIRECT_LABOUR','PL',
  'amount_test','["amount_test"]',1,'supported',
  '19000000-0000-0000-0000-000000000001'
from outlet where code='VERIFY';

insert into decision(
  id,organisation_id,outlet_id,review_issue_id,version_no,
  disposition,decision_text,target_trigger,cadence,decided_by
)
select
  '19000000-0000-0000-0000-000000000601',
  organisation_id,outlet_id,id,1,
  'MONITOR',
  'Monitor overtime and reopen if the agreed trigger is exceeded',
  'Overtime exceeds 160 hours',
  'weekly',
  '19000000-0000-0000-0000-000000000001'
from review_issue
where id='19000000-0000-0000-0000-000000000501';

update review_issue
set active_decision_id='19000000-0000-0000-0000-000000000601'
where id='19000000-0000-0000-0000-000000000501';


set role restaurant_app;
select set_config('app.user_id','19000000-0000-0000-0000-000000000001',true);

select * from create_action_from_decision(
  '19000000-0000-0000-0000-000000000601',
  'General Manager',
  '19000000-0000-0000-0000-000000000001',
  'No forecast change unless the trigger fires',
  'verify-action-create-1',
  'verification-test'
);

select t19_text(
  (select status::text from action limit 1),
  'OPEN_ON_TRACK',
  'verification fixture starts with an open action'
);


-- Same-period verification is not a prior-action check.
select t19_rejects($q$
  select * from record_prior_action_check(
    (select id from action limit 1),
    (select id from reporting_period where label='July 2026'),
    'YES','Action completed',
    'YES','Driver improved',
    'YES','Result improved',
    'CLOSE',null,'Verified','',null,
    'verify-same-period-1','verification-test'
  )
$q$,'same-period verification is refused');


-- YES / NO assertions require evidence, rather than accepting bare answers.
select t19_rejects($q$
  select * from record_prior_action_check(
    (select id from action limit 1),
    (select id from reporting_period where label='August 2026'),
    'YES',null,
    'YES','Overtime fell',
    'YES','Labour cost improved',
    'CLOSE','follow_up_monitor','Verified in August',null,null,
    'verify-missing-evidence-1','verification-test'
  )
$q$,'verification answer without its evidence is refused');


-- August closes the July action and deliberately retains follow-up monitoring.
select * from record_prior_action_check(
  (select id from action limit 1),
  (select id from reporting_period where label='August 2026'),
  'YES','The revised roster was issued and used for the August cycle',
  'YES','Overtime reduced from 220 to 125 hours',
  'YES','Labour cost reduced while service remained stable',
  'CLOSE','follow_up_monitor',
  'Roster, overtime and service evidence verified the July action',
  null,
  'Close after checking completion, driver movement and result response',
  'verify-august-0001',
  'verification-test'
);

select t19_eq(
  (select count(*) from prior_action_check),
  1,
  'August creates one immutable prior-action check'
);

select t19_text(
  (select status::text from action limit 1),
  'CLOSED',
  'verified August action closes'
);

select t19_text(
  (select status_tag from action limit 1),
  'follow_up_monitor',
  'closed action can retain the follow-up-monitor tag'
);

select t19_text(
  (select action_status_before::text from prior_action_check limit 1),
  'OPEN_ON_TRACK',
  'verification snapshots the action status before the check'
);

select t19_text(
  (select action_status_after::text from prior_action_check limit 1),
  'CLOSED',
  'verification snapshots the action status after the check'
);

select t19_eq(
  (select count(*) from action_event where event_type='verification'),
  1,
  'verification appends one action-event history row'
);

select t19_text(
  (select event_type from action_event where event_type='verification' limit 1),
  'verification',
  'action history labels verification separately from status edits'
);


-- Same idempotency key returns the first immutable check, not another row.
select * from record_prior_action_check(
  (select id from action limit 1),
  (select id from reporting_period where label='August 2026'),
  'NO','ignored on retry',
  'NO','ignored on retry',
  'NO','ignored on retry',
  'REOPEN',null,null,'ignored on retry',null,
  'verify-august-0001',
  'verification-retry'
);

select t19_eq(
  (select count(*) from prior_action_check),
  1,
  'same verification idempotency key does not duplicate history'
);


-- A different request cannot rewrite/replace the same action-period check.
select t19_rejects($q$
  select * from record_prior_action_check(
    (select id from action limit 1),
    (select id from reporting_period where label='August 2026'),
    'NO','Different claim',
    'NO','Different claim',
    'NO','Different claim',
    'REOPEN',null,null,'Different conclusion',null,
    'verify-august-other1','verification-test'
  )
$q$,'one immutable verification is allowed per action and period');


-- September evidence contradicts the prior closure and explicitly reopens.
select * from record_prior_action_check(
  (select id from action limit 1),
  (select id from reporting_period where label='September 2026'),
  'YES','The revised roster remains in use',
  'NO','Overtime rose above the agreed trigger again',
  'NO','Labour cost per cover deteriorated again',
  'REOPEN',null,null,
  'The monitored trigger recurred; reopen the action for a new decision',
  'Verification tests the previous explanation rather than protecting it',
  'verify-september-1',
  'verification-test'
);

select t19_eq(
  (select count(*) from prior_action_check),
  2,
  'September appends a second-period verification'
);

select t19_text(
  (select status::text from action limit 1),
  'REOPENED',
  'changed evidence reopens the action'
);

select t19_text(
  (
    select action_status_before::text
    from prior_action_check pac
    join reporting_period rp on rp.id=pac.verification_period_id
    where rp.label='September 2026'
  ),
  'CLOSED',
  'September verification records the prior closed state'
);

select t19_text(
  (
    select action_status_after::text
    from prior_action_check pac
    join reporting_period rp on rp.id=pac.verification_period_id
    where rp.label='September 2026'
  ),
  'REOPENED',
  'September verification records the reopened state'
);

select t19_eq(
  (select count(*) from action_event where event_type='verification'),
  2,
  'each period verification appends its own history event'
);


-- Customer sessions cannot bypass the controlled verification function.
select t19_rejects($q$
  insert into prior_action_check(
    organisation_id,outlet_id,action_id,verification_period_id,
    completed_answer,driver_moved_answer,result_responded_answer,
    outcome,action_status_before,action_status_after,created_by,note
  )
  select
    a.organisation_id,a.outlet_id,a.id,rp.id,
    'UNKNOWN','UNKNOWN','UNKNOWN',
    'CONTINUE',a.status,a.status,
    '19000000-0000-0000-0000-000000000001',
    'Injected directly'
  from action a
  join reporting_period rp
    on rp.organisation_id=a.organisation_id
   and rp.outlet_id=a.outlet_id
   and rp.label='September 2026'
  limit 1
$q$,'application role cannot directly insert verification history');


reset role;

select t19_rejects($q$
  update prior_action_check
  set note='rewrite prior verification'
$q$,'prior-action checks cannot be rewritten');

select t19_rejects($q$
  delete from prior_action_check
$q$,'prior-action checks cannot be deleted');


-- RLS: a second tenant sees none of the first tenant's verification history.
set role restaurant_app;
select set_config('app.user_id','19000000-0000-0000-0000-000000000002',true);

select * from bootstrap_organisation(
  'Other Verification Org','other-verification-org',
  'Other Verification Outlet','OTHERVERIFY',
  'USD'::char(3),'UTC',1::smallint,
  'other-verification-bootstrap','verification-rls-test'
);

select t19_eq(
  (select count(*) from prior_action_check),
  0,
  'other tenant reads zero prior-action checks'
);

rollback;
