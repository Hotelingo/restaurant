\set ON_ERROR_STOP on

-- Continue the persisted R1 fixture after the real PL worker has processed the
-- queued actual-source request.

do $$
declare
  v_run uuid;
begin
  select completed_run_id into v_run
  from calculation_request_queue
  where source_batch_id='29000000-0000-0000-0000-000000000201'
    and status='completed'
  order by created_at desc
  limit 1;

  if v_run is null then
    raise exception 'FAIL R1 worker did not complete the queued calculation';
  end if;

  if (select count(*) from calc_result where run_id=v_run) <> 34 then
    raise exception 'FAIL R1 completed run must contain 34 PL + sequence results';
  end if;

  if (select count(*) from calc_run_input where run_id=v_run) <> 2 then
    raise exception 'FAIL R1 calc run must pin actual and comparator batches';
  end if;

  if (
    select value_numeric from calc_result
    where run_id=v_run
      and calc_id='PL.OPERATING_PROFIT'
      and grain_key->>'scenario'='actual'
  ) <> 53549 then
    raise exception 'FAIL R1 actual Operating Profit mismatch';
  end if;

  if (
    select value_numeric from calc_result
    where run_id=v_run
      and calc_id='PL.OPERATING_PROFIT'
      and grain_key->>'scenario'='budget'
  ) <> 68220 then
    raise exception 'FAIL R1 budget Operating Profit mismatch';
  end if;

  if (
    select value_numeric from calc_result
    where run_id=v_run
      and calc_id='PL.VAR.OPERATING_PROFIT'
  ) <> -14671 then
    raise exception 'FAIL R1 Operating Profit variance mismatch';
  end if;

  if not exists (
    select 1 from calc_result
    where run_id=v_run
      and calc_id='SEQ.FIRST_MATERIAL_MOVEMENT'
      and calculation_status='CALCULATED'
      and value_text='NET_SALES'
      and result_metadata->>'materiality_reason'='amount_test'
      and (result_metadata->>'impact')::numeric=-3500
  ) then
    raise exception 'FAIL R1 first material movement is not NET_SALES';
  end if;

  if exists (
    with actual_batch as (
      select batch_id
      from calc_run_input
      where run_id=v_run and input_role='actual'
      limit 1
    ),
    accounting as (
      select ll.code,sum(ff.amount) as amount
      from actual_batch ab
      join financial_fact ff on ff.batch_id=ab.batch_id
      join ladder_line ll on ll.id=ff.ladder_line_id
      group by ll.code
    ),
    management as (
      select
        grain_key->>'ladder_code' as line_code,
        value_numeric
      from calc_result
      where run_id=v_run
        and grain_type='management_pl'
        and grain_key->>'scenario'='actual'
        and calculation_status='CALCULATED'
    )
    select 1
    from accounting a
    left join management m on m.line_code=a.code
    where m.line_code is null
       or m.value_numeric is distinct from a.amount
  ) then
    raise exception 'FAIL R1 Management P&L does not reconcile to canonical facts';
  end if;

  raise notice 'PASS R1 worker produced reconciled immutable Management P&L and first movement';
end
$$;


set role restaurant_app;
select set_config('app.user_id','29000000-0000-0000-0000-000000000001',false);

-- Steps 8–9 · open the review on the immutable run, shortlist the first
-- material movement, gather/fulfil evidence, diagnose it and record a valid ACT.
select * from create_review(
  (select id from outlet where code='R1ACC'),
  (select id from reporting_period
   where outlet_id=(select id from outlet where code='R1ACC')
     and period_start='2026-07-01'),
  'r1-review-create01',
  'r1-acceptance'
);

select * from frame_review(
  (select id from review
   where outlet_id=(select id from outlet where code='R1ACC')
     and status='draft'),
  (select id from restaurant_context
   where outlet_id=(select id from outlet where code='R1ACC')
     and effective_from='2026-01-01'
   order by version_no desc limit 1),
  (select cri.run_id
   from calc_run_input cri
   join calc_run r on r.id=cri.run_id
   where cri.batch_id='29000000-0000-0000-0000-000000000201'
     and cri.input_role='actual'
     and r.status='completed'
   order by r.completed_at desc,r.id desc
   limit 1),
  'budget',
  'r1-frame-confirm01',
  'r1-acceptance'
);

select * from add_review_issue(
  (select id from review
   where outlet_id=(select id from outlet where code='R1ACC')
     and status='in_review'),
  (select cr.id
   from calc_result cr
   join calc_run_input cri
     on cri.run_id=cr.run_id
    and cri.input_role='actual'
   join calc_run r on r.id=cr.run_id
   where cri.batch_id='29000000-0000-0000-0000-000000000201'
     and r.status='completed'
     and cr.calc_id='PL.VAR.NET_SALES'
   order by r.completed_at desc,r.id desc
   limit 1),
  'Net Sales',
  'First material movement from the frozen PL ladder',
  'r1-shortlist-net01',
  'r1-acceptance'
);

-- Step 10 · explicitly request evidence, fulfil it with committed source
-- material, then record the supported diagnosis before management decides.
select * from create_evidence_request(
  (select id from review_issue
   where review_id=(
     select id from review
     where outlet_id=(select id from outlet where code='R1ACC')
       and status='in_review'
   )
   and ladder_code='NET_SALES'),
  'Daily revenue bridge',
  'Validate the sales movement before action',
  '["business_date","channel","net_sales"]'::jsonb,
  'General Manager',
  '2026-08-10',
  'r1-evidence-request1',
  'r1-acceptance'
);

select * from fulfill_evidence_request(
  (select id from evidence_request
   where review_issue_id=(
     select id from review_issue
     where review_id=(
       select id from review
       where outlet_id=(select id from outlet where code='R1ACC')
         and status='in_review'
     )
     and ladder_code='NET_SALES'
   )),
  '29000000-0000-0000-0000-000000000202',
  'r1-evidence-fulfil1',
  'r1-acceptance'
);

select * from record_issue_diagnosis(
  (select id from review_issue
   where review_id=(
     select id from review
     where outlet_id=(select id from outlet where code='R1ACC')
       and status='in_review'
   )
   and ladder_code='NET_SALES'),
  'supported',
  'rate_price',
  'validated',
  'Validated revenue bridge supports a rate/price driver for the sales movement',
  null,
  null,
  'r1-diagnosis-0001',
  'r1-acceptance'
);

select * from add_driver_evidence(
  (select id from review_issue
   where review_id=(
     select id from review
     where outlet_id=(select id from outlet where code='R1ACC')
       and status='in_review'
   )
   and ladder_code='NET_SALES'),
  'rate_price',
  'committed_budget_batch',
  '29000000-0000-0000-0000-000000000202',
  'validated',
  -3500,
  'Evidence is pinned to committed source material',
  'r1-driver-evidence1',
  'r1-acceptance'
);

select * from record_issue_decision(
  (select id from review_issue
   where review_id=(
     select id from review
     where outlet_id=(select id from outlet where code='R1ACC')
       and status='in_review'
   )
   and ladder_code='NET_SALES'),
  'ACT',
  'Adjust the supported pricing lever and verify the next-period result',
  'General Manager',
  'Adjust price architecture',
  'Protect guest value score',
  'Net sales and contribution',
  null,
  '2026-08-15',
  'weekly',
  null,
  null,
  null,
  null,
  null,
  'r1-decision-act01',
  'r1-acceptance'
);

select * from create_action_from_decision(
  (select active_decision_id
   from review_issue
   where review_id=(
     select id from review
     where outlet_id=(select id from outlet where code='R1ACC')
       and status='in_review'
   )
   and ladder_code='NET_SALES'),
  'General Manager',
  '29000000-0000-0000-0000-000000000001',
  'Reflect only after verified movement in the next forecast',
  'r1-action-create01',
  'r1-acceptance'
);


-- Step 11 · create Owner Pack v1 with a cited, checkable claim.
select * from create_pack_version(
  (select id from review
   where outlet_id=(select id from outlet where code='R1ACC')
     and status='in_review'),
  'r1-pack-create0001',
  'r1-acceptance'
);

select * from create_pack_claim(
  (select id from pack_version
   where review_id=(
     select id from review
     where outlet_id=(select id from outlet where code='R1ACC')
       and status='in_review'
   )
   and version_no=1),
  'headline',
  'Net sales movement was 3,500 adverse to budget.',
  'validated',
  array[
    (select cr.id
     from calc_result cr
     join pack_version p on p.calc_run_id=cr.run_id
     where p.review_id=(
       select id from review
       where outlet_id=(select id from outlet where code='R1ACC')
         and status='in_review'
     )
       and p.version_no=1
       and cr.calc_id='PL.VAR.NET_SALES'
     limit 1)
  ]::uuid[],
  'r1-pack-claim0001',
  'r1-acceptance'
);

select * from submit_pack_for_review(
  (select id from pack_version
   where review_id=(
     select id from review
     where outlet_id=(select id from outlet where code='R1ACC')
       and status='in_review'
   )
   and version_no=1),
  'r1-pack-submit001',
  'r1-acceptance'
);


-- Reviewer accepts the claim; migration 0028 snapshots all manual reviewer
-- checks so RG can subsequently evaluate without silently upgrading evidence.
select set_config('app.user_id','29000000-0000-0000-0000-000000000002',false);

select * from review_pack_claim(
  (select c.id
   from claim c
   join pack_version p on p.id=c.pack_version_id
   where p.review_id=(
     select id from review
     where outlet_id=(select id from outlet where code='R1ACC')
       and status='in_review'
   )
     and p.version_no=1
     and c.section_code='headline'),
  'accept',
  'r1-claim-accept001',
  'r1-acceptance'
);

reset role;

-- The real deterministic renderer/storage attachment runs in the following
-- Python acceptance phase, before RG sign-off.


do $$
declare
  v_review uuid;
  v_issue uuid;
begin
  select id into v_review
  from review
  where outlet_id=(select id from outlet where code='R1ACC')
    and status='in_review';

  select id into v_issue
  from review_issue
  where review_id=v_review and ladder_code='NET_SALES';

  if (select count(*) from review_issue where review_id=v_review) <> 1 then
    raise exception 'FAIL R1 expected exactly one shortlisted issue';
  end if;

  if not exists (
    select 1 from evidence_request
    where review_issue_id=v_issue
      and status='fulfilled'
      and fulfilled_batch_id='29000000-0000-0000-0000-000000000202'
  ) then
    raise exception 'FAIL R1 evidence request was not fulfilled from committed evidence';
  end if;

  if not exists (
    select 1
    from decision d
    join review_issue ri on ri.active_decision_id=d.id
    where ri.id=v_issue
      and d.disposition='ACT'
      and d.owner='General Manager'
      and d.lever is not null
      and d.guardrail is not null
      and d.verification_metric is not null
      and (d.due_date is not null or d.cadence is not null)
  ) then
    raise exception 'FAIL R1 valid ACT disposition was not persisted';
  end if;

  if not exists (
    select 1 from action
    where review_issue_id=v_issue
      and decision_id=(select active_decision_id from review_issue where id=v_issue)
  ) then
    raise exception 'FAIL R1 action register row was not created from the decision';
  end if;

  if not exists (
    select 1
    from pack_version p
    join claim c on c.pack_version_id=p.id
    where p.review_id=v_review
      and p.version_no=1
      and p.status='in_review'
      and p.artifact_sha256 is null
      and c.claim_status='accepted'
      and c.review_check_snapshot->>'status_echo'='confirmed_by_reviewer'
  ) then
    raise exception 'FAIL R1 Owner Pack v1 / accepted reviewed claim missing';
  end if;

  raise notice 'PASS R1 shortlist, evidence, decision, action and Owner Pack v1';
end
$$;
