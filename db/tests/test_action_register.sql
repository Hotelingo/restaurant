\set ON_ERROR_STOP on
begin;

create or replace function t18_eq(actual bigint, expected bigint, label text)
returns void language plpgsql as $$
begin
  if actual <> expected then
    raise exception 'FAIL % expected % got %',label,expected,actual;
  end if;
  raise notice 'PASS %',label;
end $$;

create or replace function t18_text(actual text, expected text, label text)
returns void language plpgsql as $$
begin
  if actual is distinct from expected then
    raise exception 'FAIL % expected % got %',label,expected,actual;
  end if;
  raise notice 'PASS %',label;
end $$;

create or replace function t18_rejects(stmt text, label text)
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
values ('18000000-0000-0000-0000-000000000001','Action Admin','action@example.com',false);

set role restaurant_app;
select set_config('app.user_id','18000000-0000-0000-0000-000000000001',true);

select * from bootstrap_organisation(
  'Action Org','action-org','Action Outlet','ACTION',
  'USD'::char(3),'UTC',1::smallint,'action-bootstrap-1','action-test'
);

insert into reporting_period(
  organisation_id,outlet_id,period_start,period_end,label
)
select organisation_id,id,'2026-07-01','2026-07-31','July 2026'
from outlet where code='ACTION';

reset role;

insert into restaurant_context(
  id,organisation_id,outlet_id,version_no,effective_from,created_by
)
select
  '18000000-0000-0000-0000-000000000101',
  organisation_id,id,1,'2026-01-01',
  '18000000-0000-0000-0000-000000000001'
from outlet where code='ACTION';

insert into calc_run(
  id,organisation_id,outlet_id,period_id,engine_version,
  settings_snapshot,comparator_scenario,status
)
select
  '18000000-0000-0000-0000-000000000201',
  o.organisation_id,o.id,rp.id,'pl-v1',
  '{"materiality":{"general":{"absolute_threshold":"1000","percent_threshold":"0.10"}}}',
  'budget','queued'
from outlet o
join reporting_period rp
  on rp.organisation_id=o.organisation_id and rp.outlet_id=o.id
where o.code='ACTION';

update calc_run
set status='running',started_at=now()
where id='18000000-0000-0000-0000-000000000201';

insert into calc_result(
  id,organisation_id,outlet_id,run_id,
  calc_id,grain_type,grain_key,value_numeric,unit,currency_code,
  calculation_status,evidence_status,result_metadata,raw_delta,profit_effect
)
select
  '18000000-0000-0000-0000-000000000301',
  organisation_id,id,'18000000-0000-0000-0000-000000000201',
  'PL.VAR.DIRECT_LABOUR','management_pl_variance',
  '{"ladder_code":"DIRECT_LABOUR","actual_scenario":"actual","comparator_scenario":"budget"}',
  -5205,'currency','USD','CALCULATED','supported','{}',-5205,-5205
from outlet where code='ACTION';

update calc_run
set status='completed',completed_at=now(),result_hash=repeat('1',64)
where id='18000000-0000-0000-0000-000000000201';

insert into review(
  id,organisation_id,outlet_id,period_id,status,comparator_scenario,
  context_version_id,materiality_snapshot,active_calc_run_id,
  review_leader_id,frame_confirmed_at
)
select
  '18000000-0000-0000-0000-000000000401',
  o.organisation_id,o.id,rp.id,'in_review','budget',
  '18000000-0000-0000-0000-000000000101',
  '{"general":{"absolute_threshold":"1000","percent_threshold":"0.10"}}',
  '18000000-0000-0000-0000-000000000201',
  '18000000-0000-0000-0000-000000000001',
  now()
from outlet o
join reporting_period rp
  on rp.organisation_id=o.organisation_id and rp.outlet_id=o.id
where o.code='ACTION';

insert into review_issue(
  id,organisation_id,outlet_id,review_id,
  source_calc_run_id,source_calc_result_id,title,
  movement_amount,movement_rate,ladder_code,module,
  materiality_reason,materiality_rules,shortlist_order,
  evidence_status,created_by
)
select
  '18000000-0000-0000-0000-000000000501',
  organisation_id,id,
  '18000000-0000-0000-0000-000000000401',
  '18000000-0000-0000-0000-000000000201',
  '18000000-0000-0000-0000-000000000301',
  'Labour',-5205,0.10,'DIRECT_LABOUR','PL',
  'amount_test','["amount_test"]',1,'supported',
  '18000000-0000-0000-0000-000000000001'
from outlet where code='ACTION';

insert into decision(
  id,organisation_id,outlet_id,review_issue_id,version_no,
  disposition,decision_text,target_trigger,cadence,decided_by
)
select
  '18000000-0000-0000-0000-000000000601',
  organisation_id,outlet_id,id,1,
  'MONITOR',
  'Monitor overtime and reopen if the agreed trigger is exceeded',
  'Overtime exceeds 160 hours',
  'weekly',
  '18000000-0000-0000-0000-000000000001'
from review_issue
where id='18000000-0000-0000-0000-000000000501';

update review_issue
set active_decision_id='18000000-0000-0000-0000-000000000601'
where id='18000000-0000-0000-0000-000000000501';


set role restaurant_app;
select set_config('app.user_id','18000000-0000-0000-0000-000000000001',true);

select * from create_action_from_decision(
  '18000000-0000-0000-0000-000000000601',
  'General Manager',
  '18000000-0000-0000-0000-000000000001',
  'No forecast change unless the trigger fires',
  'action-create-0001',
  'action-test'
);

select t18_eq(
  (select count(*) from action),
  1,
  'active decision creates one action-register row'
);

select t18_text(
  (select owner from action limit 1),
  'General Manager',
  'action register carries accountable owner'
);

select t18_text(
  (select target_trigger from action limit 1),
  'Overtime exceeds 160 hours',
  'action copies the decision trigger'
);

select t18_text(
  (select cadence from action limit 1),
  'weekly',
  'action copies review cadence'
);

select t18_text(
  (select status::text from action limit 1),
  'OPEN_ON_TRACK',
  'new action starts open and on track'
);

-- Same key returns the same action without duplication.
select * from create_action_from_decision(
  '18000000-0000-0000-0000-000000000601',
  'Ignored owner',
  null,
  null,
  'action-create-0001',
  'action-retry'
);

select t18_eq(
  (select count(*) from action),
  1,
  'action creation retry is idempotent'
);

select t18_rejects($q$
  insert into action(
    organisation_id,outlet_id,review_id,review_issue_id,decision_id,
    owner,created_by
  )
  select
    organisation_id,outlet_id,review_id,id,active_decision_id,
    'Injected owner',
    '18000000-0000-0000-0000-000000000001'
  from review_issue
  where id='18000000-0000-0000-0000-000000000501'
$q$,'application role cannot bypass controlled action creation');

select t18_rejects($q$
  select * from transition_action_status(
    (select id from action limit 1),
    'CLOSED',null,null,'Attempt close',
    'action-close-bad1','action-test'
  )
$q$,'closing without closure evidence is refused');

select * from transition_action_status(
  (select id from action limit 1),
  'CLOSED','follow_up_monitor',
  'Roster review and overtime report verified the trigger did not recur',
  'Close with supporting evidence',
  'action-close-good1','action-test'
);

select t18_text(
  (select status::text from action limit 1),
  'CLOSED',
  'action closes when closure evidence is present'
);

select t18_eq(
  (select count(*) from action_event where event_type='status_change'),
  1,
  'closure appends one status event'
);

select t18_text(
  (select evidence from action_event order by created_at,id limit 1),
  'Roster review and overtime report verified the trigger did not recur',
  'closure evidence is retained in action history'
);

select * from transition_action_status(
  (select id from action limit 1),
  'REOPENED','follow_up_monitor',null,
  'Overtime trigger exceeded again in the next review period',
  'action-reopen-0001','action-test'
);

select t18_text(
  (select status::text from action limit 1),
  'REOPENED',
  'closed action can be reopened when evidence changes'
);

select t18_eq(
  (select count(*) from action_event where event_type='status_change'),
  2,
  'reopen appends a second history event'
);

select t18_text(
  (select status_tag from action limit 1),
  'follow_up_monitor',
  'action keeps the supported follow-up tag vocabulary'
);

reset role;

select t18_rejects($q$
  update action
  set lever='rewrite original agreement'
$q$,'action definition cannot be rewritten');

select t18_rejects($q$
  delete from action
$q$,'action history cannot be deleted');

select t18_rejects($q$
  update action_event
  set note='rewrite history'
$q$,'action event history is immutable');

rollback;
