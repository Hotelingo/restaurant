\set ON_ERROR_STOP on

begin;

create or replace function s5_assert_rejects(stmt text, label text)
returns void language plpgsql as $$
begin
  begin
    execute stmt;
  exception when others then
    raise notice 'PASS % (%)',label,sqlerrm;
    return;
  end;
  raise exception 'FAIL % -- statement was accepted unexpectedly',label;
end
$$;

do $$
declare
  v_fc_run uuid;
  v_r1_review uuid;
  v_r1_pack uuid;
  v_r1_run uuid;
begin
  select q.completed_run_id into v_fc_run
  from calculation_request_queue q
  join outlet o on o.id=q.outlet_id
  where o.code='FCWORKER'
    and q.status='completed'
    and q.reason like 'food_cost%'
  order by q.created_at desc,q.id desc
  limit 1;

  if v_fc_run is null then
    raise exception 'FAIL Slice 5 has no completed Food Cost run';
  end if;

  if (select engine_version from calc_run where id=v_fc_run) <> 'food-cost-v1' then
    raise exception 'FAIL Slice 5 Food Cost run is not food-cost-v1';
  end if;

  if (
    select value_text
    from calc_result
    where run_id=v_fc_run
      and calc_id='FC.DECISION_PATH'
      and grain_key->>'product_group'='food'
  ) <> 'MENU_ECONOMIC_HANDOFF' then
    raise exception 'FAIL Amberside Food does not route to MENU_ECONOMIC_HANDOFF';
  end if;

  if (
    select value_text
    from calc_result
    where run_id=v_fc_run
      and calc_id='FC.DECISION_PATH'
      and grain_key->>'product_group'='beverage'
  ) <> 'NO_MATERIAL_GAP' then
    raise exception 'FAIL Amberside Beverage does not route to NO_MATERIAL_GAP';
  end if;

  if (
    select value_numeric
    from calc_result
    where run_id=v_fc_run
      and calc_id='FC.ACTUAL_VS_EXPECTED'
      and grain_key->>'product_group'='food'
  ) <> 943 then
    raise exception 'FAIL Amberside Food actual-vs-expected gap is not 943';
  end if;

  if (
    select count(*)
    from calc_run_input i
    join import_batch b on b.id=i.batch_id
    join source_file sf on sf.id=b.source_file_id
    where i.run_id=v_fc_run
      and b.status='committed'
      and b.canonical_commit_hash=i.canonical_commit_hash
      and sf.sha256 ~ '^[0-9a-f]{64}$'
      and (
        (i.input_role='item_sales' and b.template_code='T2')
        or (i.input_role='stock' and b.template_code='T3')
        or (i.input_role='item_cost' and b.template_code='T4A')
      )
  ) <> 3 then
    raise exception 'FAIL Food Cost run lost T2/T3/T4A source/commit lineage';
  end if;

  if exists (
    select 1
    from calc_run r
    where r.id=v_fc_run
      and r.review_id is not null
  ) then
    raise exception 'FAIL Food Cost run bypassed the core review anchor';
  end if;

  if exists (
    select 1
    from review r
    join calc_run cr on cr.id=r.active_calc_run_id
    where cr.engine_version not like 'pl-%'
  ) then
    raise exception 'FAIL a review is anchored to a non-P&L calculation run';
  end if;

  if exists (
    select 1
    from pack_version p
    join calc_run cr on cr.id=p.calc_run_id
    where cr.engine_version not like 'pl-%'
  ) then
    raise exception 'FAIL an Owner Pack is pinned directly to a module calculation run';
  end if;

  select r.id,r.active_calc_run_id
    into v_r1_review,v_r1_run
  from review r
  join outlet o on o.id=r.outlet_id
  where o.code='R1ACC'
  order by r.created_at desc,r.id desc
  limit 1;

  select p.id into v_r1_pack
  from pack_version p
  where p.review_id=v_r1_review
  order by p.version_no desc,p.id desc
  limit 1;

  if v_r1_review is null or v_r1_pack is null or v_r1_run is null then
    raise exception 'FAIL existing R1 review/pack acceptance spine is missing';
  end if;

  if (select engine_version from calc_run where id=v_r1_run) not like 'pl-%' then
    raise exception 'FAIL R1 review FRAME no longer pins Management P&L';
  end if;

  if (select status::text from pack_version where id=v_r1_pack) <> 'signed' then
    raise exception 'FAIL existing R1 Owner Pack is no longer signed';
  end if;

  if not exists (
    select 1
    from signoff s
    where s.pack_version_id=v_r1_pack
      and s.decision='signed'
      and s.calc_run_id=v_r1_run
      and coalesce((s.gate_snapshot->>'passed')::boolean,false)
  ) then
    raise exception 'FAIL signed R1 pack lost its passing review-gate snapshot';
  end if;

  raise notice
    'PASS Slice 5 golden routing + T2/T3/T4A lineage + existing signed R1 spine';
end
$$;


-- Create only temporary review setup for the Food Cost test organisation.
insert into restaurant_context(
  id,organisation_id,outlet_id,version_no,
  service_style,capacity_json,meal_periods_json,business_formats_json,
  customer_sources_json,recipe_costing_status,labour_recording_basis,
  source_tracking_quality,evidence_maturity,effective_from,created_by
)
select
  'f0000000-0000-0000-0000-000000000050',
  o.organisation_id,o.id,1,
  'casual dining','{}','[]','[]','[]',
  'recipe_costed','hours','structured','validated',
  '2026-07-01',
  'f0000000-0000-0000-0000-000000000001'
from outlet o
where o.code='FCWORKER'
  and not exists (
    select 1 from restaurant_context rc
    where rc.outlet_id=o.id and rc.version_no=1
  );

set role restaurant_app;
select set_config('app.user_id','f0000000-0000-0000-0000-000000000001',true);

do $$
declare
  v_review uuid;
  v_fc_run uuid;
begin
  select created_review_id into v_review
  from public.create_review(
    (select id from public.outlet where code='FCWORKER'),
    'f0000000-0000-0000-0000-000000000010',
    's5-fc-review-create',
    'slice5-acceptance'
  );

  select r.id into v_fc_run
  from public.calc_run r
  where r.outlet_id=(select id from public.outlet where code='FCWORKER')
    and r.status='completed'
    and r.engine_version='food-cost-v1'
  order by r.completed_at desc,r.id desc
  limit 1;

  begin
    perform *
    from public.frame_review(
      v_review,
      'f0000000-0000-0000-0000-000000000050',
      v_fc_run,
      'budget'::public.scenario_code,
      's5-fc-frame-attempt',
      'slice5-acceptance'
    );
    raise exception 'FAIL Food Cost run was accepted as the core review FRAME';
  exception
    when check_violation then
      raise notice 'PASS Food Cost run cannot be used as core review FRAME (%)',sqlerrm;
  end;

  if (select status::text from public.review where id=v_review) <> 'draft' then
    raise exception 'FAIL rejected Food Cost FRAME mutated the draft review';
  end if;
end
$$;

reset role;


-- The database invariant independently rejects privileged/server attempts to
-- construct an in-review record directly on a Food Cost calc snapshot.
select s5_assert_rejects(
  $q$
    update review rv
    set
      status='in_review',
      comparator_scenario='budget',
      context_version_id='f0000000-0000-0000-0000-000000000050',
      materiality_snapshot=cr.settings_snapshot->'materiality',
      active_calc_run_id=cr.id,
      frame_confirmed_at=now(),
      updated_at=now()
    from calc_run cr,outlet o
    where rv.outlet_id=o.id
      and o.code='FCWORKER'
      and rv.status='draft'
      and cr.outlet_id=o.id
      and cr.period_id=rv.period_id
      and cr.engine_version='food-cost-v1'
      and cr.status='completed'
  $q$,
  'database rejects direct Food Cost review FRAME bypass'
);

-- Food Cost results also cannot be injected into the R1 shortlist because the
-- shortlist accepts only calculated Management P&L variance results from the
-- review's one pinned core calc snapshot.
set role restaurant_app;
select set_config('app.user_id','29000000-0000-0000-0000-000000000001',true);

do $$
declare
  v_review uuid;
  v_fc_result uuid;
begin
  select r.id into v_review
  from public.review r
  join public.outlet o on o.id=r.outlet_id
  where o.code='R1ACC'
  order by r.created_at desc
  limit 1;

  select cr.id into v_fc_result
  from public.calc_result cr
  join public.calc_run run on run.id=cr.run_id
  join public.outlet o on o.id=run.outlet_id
  where o.code='FCWORKER'
    and cr.calc_id='FC.ACTUAL_VS_EXPECTED'
    and cr.grain_key->>'product_group'='food'
  order by run.completed_at desc
  limit 1;

  begin
    perform *
    from public.add_review_issue(
      v_review,
      v_fc_result,
      'Food Cost control gap',
      'Slice 5 bypass test',
      's5-fc-issue-attempt',
      'slice5-acceptance'
    );
    raise exception 'FAIL Food Cost result was injected into the P&L shortlist';
  exception
    when check_violation then
      raise notice 'PASS Food Cost cannot bypass the pinned review shortlist (%)',sqlerrm;
    when insufficient_privilege then
      -- Cross-tenant neutral denial is also correct for this intentionally
      -- foreign source result.
      raise notice 'PASS Food Cost cannot cross scope into the R1 shortlist (%)',sqlerrm;
  end;
end
$$;

reset role;

drop function s5_assert_rejects(text,text);

rollback;
