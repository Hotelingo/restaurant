\set ON_ERROR_STOP on
begin;

do $$
declare
  v_run uuid;
  v_r1_review uuid;
  v_r1_pack uuid;
  v_r1_run uuid;
  v_bad_grains bigint;
begin
  select q.completed_run_id into v_run
  from calculation_request_queue q
  join outlet o on o.id=q.outlet_id
  where o.code='LBWORKER'
    and q.status='completed'
    and q.reason like 'labour_other%'
  order by q.created_at desc,q.id desc
  limit 1;

  if v_run is null then
    raise exception 'FAIL Slice 7 has no completed Labour/Other run';
  end if;

  if (select engine_version from calc_run where id=v_run) <> 'labour-other-v1' then
    raise exception 'FAIL Slice 7 Labour/Other run is not labour-other-v1';
  end if;

  if (select comparator_scenario::text from calc_run where id=v_run) <> 'budget' then
    raise exception 'FAIL Slice 7 Labour/Other run is not pinned to budget comparator';
  end if;

  if (
    select count(*)
    from calc_result
    where run_id=v_run and calc_id='LB.TOTAL_VARIANCE'
  ) <> 5 then
    raise exception 'FAIL Slice 7 must contain five Labour role groups';
  end if;

  if (
    select sum(value_numeric)
    from calc_result
    where run_id=v_run and calc_id='LB.TOTAL_VARIANCE'
  ) <> 5205 then
    raise exception 'FAIL Amberside Labour total variance is not 5205';
  end if;

  select count(*) into v_bad_grains
  from (
    select
      grain_key,
      max(value_numeric) filter(where calc_id='LB.HOURS_EFFECT_RAW') as hours_effect,
      max(value_numeric) filter(where calc_id='LB.RATE_EFFECT_RAW') as rate_effect,
      max(value_numeric) filter(where calc_id='LB.TOTAL_VARIANCE') as total_variance
    from calc_result
    where run_id=v_run
      and calc_id in (
        'LB.HOURS_EFFECT_RAW',
        'LB.RATE_EFFECT_RAW',
        'LB.TOTAL_VARIANCE'
      )
    group by grain_key
  ) g
  where hours_effect is null
     or rate_effect is null
     or total_variance is null
     or hours_effect + rate_effect <> total_variance;

  if v_bad_grains<>0 then
    raise exception 'FAIL % Labour role groups violate hours + rate = total',v_bad_grains;
  end if;

  if (
    select count(*)
    from calc_run_input i
    join import_batch b on b.id=i.batch_id
    join source_file sf on sf.id=b.source_file_id
    where i.run_id=v_run
      and b.status='committed'
      and b.canonical_commit_hash=i.canonical_commit_hash
      and sf.sha256 ~ '^[0-9a-f]{64}$'
      and (
        (i.input_role='labour_detail' and b.template_code='T5' and i.scenario='actual')
        or (
          i.input_role='labour_financial_actual'
          and b.template_code='T1'
          and i.scenario='actual'
        )
        or (
          i.input_role='labour_financial_comparator'
          and b.template_code='T6'
          and i.scenario='budget'
        )
      )
  ) <> 3 then
    raise exception 'FAIL Labour/Other run lost exact T5/T1/T6 source/commit lineage';
  end if;

  if not exists(
    select 1
    from data_readiness dr
    where dr.outlet_id=(select id from outlet where code='LBWORKER')
      and dr.period_id=(select period_id from calc_run where id=v_run)
      and dr.capability_code='labour_inputs'
      and dr.status='ready'
      and (dr.details_json->>'actual_pnl_tie')::boolean
      and (dr.details_json->>'comparator_pnl_tie')::boolean
      and dr.details_json->>'activity_unit_rollup'='PROHIBITED_ACROSS_ROLE_GROUPS'
      and (dr.details_json->>'t5_actual_labour_cost')::numeric=84317
      and (dr.details_json->>'pnl_direct_labour')::numeric=84317
      and (dr.details_json->>'t5_comparator_labour_cost')::numeric=79112
      and (dr.details_json->>'pnl_comparator_direct_labour')::numeric=79112
  ) then
    raise exception 'FAIL Labour readiness lost T5↔T1/T6 tie-outs or non-additive activity rule';
  end if;

  if (
    select count(*)
    from calc_result
    where run_id=v_run
      and calc_id='LB.COST_PER_ACTIVITY'
      and grain_key->>'activity_basis'='total_covers'
      and grain_key->>'role_group' in ('Kitchen prep','Management / shared')
  ) <> 2 then
    raise exception 'FAIL repeated total-covers Labour context lost role-group activity basis';
  end if;

  if exists(
    select 1
    from calc_result
    where run_id=v_run
      and calc_id in ('LB.HOURS_PER_ACTIVITY','LB.COST_PER_ACTIVITY')
      and (
        nullif(grain_key->>'role_group','') is null
        or grain_key ? 'scope'
      )
  ) then
    raise exception 'FAIL role-group activity denominators were rolled up into a fabricated aggregate';
  end if;

  if (
    select count(*)
    from calc_result
    where run_id=v_run
      and calc_id='LB.OVERTIME_RATE_EFFECT'
      and calculation_status='NOT_CALCULATED'
      and explanation_code='OVERTIME_RATE_EVIDENCE_MISSING'
      and value_numeric is null
  ) <> 5 then
    raise exception 'FAIL unsupported overtime-rate evidence was converted into a number';
  end if;

  if exists(
    select 1
    from calc_result
    where run_id=v_run
      and upper(coalesce(value_text,'')) like '%OVERSTAFFED%'
  ) then
    raise exception 'FAIL Labour engine inferred OVERSTAFFED';
  end if;

  if (
    select value_numeric
    from calc_result
    where run_id=v_run
      and calc_id='OC.TOTAL_VARIANCE'
      and grain_key->>'ladder_code'='OTHER_DIRECT_OPERATING'
  ) <> 200 then
    raise exception 'FAIL Other Direct Operating variance is not 200';
  end if;

  if (
    select value_numeric
    from calc_result
    where run_id=v_run
      and calc_id='OC.TOTAL_VARIANCE'
      and grain_key->>'ladder_code'='SHARED_RESTAURANT_COST'
  ) <> 2092 then
    raise exception 'FAIL Shared Restaurant Cost variance is not 2092';
  end if;

  if (
    select value_numeric
    from calc_result
    where run_id=v_run
      and calc_id='OC.TOTAL_VARIANCE'
      and grain_key->>'ladder_code'='OWNER_STRUCTURAL_COST'
  ) <> 0 then
    raise exception 'FAIL Owner Structural Cost variance is not 0';
  end if;

  if (
    select count(*)
    from calc_result
    where run_id=v_run
      and calc_id in ('OC.QUANTITY_EFFECT','OC.RATE_EFFECT')
      and calculation_status='NOT_CALCULATED'
      and explanation_code='QUANTITY_RATE_EVIDENCE_MISSING'
      and value_numeric is null
  ) <> 6 then
    raise exception 'FAIL unsupported OC quantity/rate effects were fabricated';
  end if;

  if not exists(
    select 1
    from calc_result
    where run_id=v_run
      and calc_id='LB.TOTAL_VARIANCE'
      and exists(
        select 1
        from jsonb_array_elements_text(input_refs) ref
        where ref like 'labour_fact:%'
      )
  ) then
    raise exception 'FAIL Labour result lost direct T5 fact refs';
  end if;

  if not exists(
    select 1
    from calc_result
    where run_id=v_run
      and calc_id='OC.TOTAL_VARIANCE'
      and grain_key->>'ladder_code'='SHARED_RESTAURANT_COST'
      and (
        select count(*)
        from jsonb_array_elements_text(input_refs) ref
        where ref like 'financial_fact:%'
      )=2
  ) then
    raise exception 'FAIL OC result lost direct T1/T6 financial fact refs';
  end if;

  if exists(
    select 1 from calc_run
    where id=v_run and review_id is not null
  ) then
    raise exception 'FAIL Labour/Other run bypassed the core review anchor';
  end if;

  if exists(
    select 1
    from review r
    join calc_run cr on cr.id=r.active_calc_run_id
    where cr.engine_version not like 'pl-%'
  ) then
    raise exception 'FAIL a review is anchored to a non-P&L calculation run';
  end if;

  if exists(
    select 1
    from pack_version p
    join calc_run cr on cr.id=p.calc_run_id
    where cr.engine_version not like 'pl-%'
  ) then
    raise exception 'FAIL an Owner Pack is pinned directly to a supporting module run';
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

  if not exists(
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
    'PASS Slice 7 Labour/Other math + T5/T1/T6 lineage + activity safeguards + existing signed R1 spine';
end
$$;


insert into restaurant_context(
  id,organisation_id,outlet_id,version_no,
  service_style,capacity_json,meal_periods_json,business_formats_json,
  customer_sources_json,recipe_costing_status,labour_recording_basis,
  source_tracking_quality,evidence_maturity,effective_from,created_by
)
select
  '78000000-0000-0000-0000-000000000050',
  o.organisation_id,o.id,1,
  'casual dining','{}','[]','[]','[]',
  'recipe_costed','hours','structured','validated',
  '2026-07-01',
  '77000000-0000-0000-0000-000000000001'
from outlet o
where o.code='LBWORKER'
  and not exists(
    select 1 from restaurant_context rc
    where rc.outlet_id=o.id and rc.version_no=1
  );

set role restaurant_app;
select set_config('app.user_id','77000000-0000-0000-0000-000000000001',true);

do $$
declare
  v_review uuid;
  v_run uuid;
begin
  select created_review_id into v_review
  from public.create_review(
    (select id from public.outlet where code='LBWORKER'),
    '77000000-0000-0000-0000-000000000010',
    's7-lb-review-create',
    'slice7-acceptance'
  );

  select r.id into v_run
  from public.calc_run r
  where r.outlet_id=(select id from public.outlet where code='LBWORKER')
    and r.status='completed'
    and r.engine_version='labour-other-v1'
  order by r.completed_at desc,r.id desc
  limit 1;

  begin
    perform *
    from public.frame_review(
      v_review,
      '78000000-0000-0000-0000-000000000050',
      v_run,
      'budget'::public.scenario_code,
      's7-lb-frame-attempt',
      'slice7-acceptance'
    );
    raise exception 'FAIL Labour/Other run was accepted as the core review FRAME';
  exception
    when check_violation then
      raise notice 'PASS Labour/Other run cannot be used as core review FRAME (%)',sqlerrm;
  end;

  if (select status::text from public.review where id=v_review) <> 'draft' then
    raise exception 'FAIL rejected Labour/Other FRAME mutated the draft review';
  end if;
end
$$;

reset role;


do $$
declare
  v_rejected boolean := false;
begin
  begin
    update review rv
    set
      status='in_review',
      comparator_scenario='budget',
      context_version_id='78000000-0000-0000-0000-000000000050',
      materiality_snapshot=cr.settings_snapshot->'materiality',
      active_calc_run_id=cr.id,
      frame_confirmed_at=now(),
      updated_at=now()
    from calc_run cr,outlet o
    where rv.outlet_id=o.id
      and o.code='LBWORKER'
      and rv.status='draft'
      and cr.outlet_id=o.id
      and cr.period_id=rv.period_id
      and cr.engine_version='labour-other-v1'
      and cr.status='completed';
  exception when others then
    v_rejected := true;
    raise notice 'PASS database rejects direct Labour/Other review FRAME bypass (%)',sqlerrm;
  end;

  if not v_rejected then
    raise exception 'FAIL database accepted direct Labour/Other review FRAME bypass';
  end if;
end
$$;


set role restaurant_app;
select set_config('app.user_id','77000000-0000-0000-0000-000000000001',true);

do $$
declare
  v_review uuid;
  v_result uuid;
begin
  select r.id into v_review
  from public.review r
  join public.outlet o on o.id=r.outlet_id
  where o.code='LBWORKER'
    and r.status='draft'
  order by r.created_at desc
  limit 1;

  select cr.id into v_result
  from public.calc_result cr
  join public.calc_run run on run.id=cr.run_id
  where run.outlet_id=(select id from public.outlet where code='LBWORKER')
    and run.engine_version='labour-other-v1'
    and run.status='completed'
    and cr.calc_id='LB.TOTAL_VARIANCE'
    and cr.grain_key->>'role_group'='Kitchen prep'
  order by run.completed_at desc
  limit 1;

  if v_review is null or v_result is null then
    raise exception 'FAIL Slice 7 shortlist guard fixture is incomplete';
  end if;

  begin
    perform *
    from public.add_review_issue(
      v_review,
      v_result,
      'Labour diagnostic',
      'Slice 7 bypass test',
      's7-lb-issue-attempt',
      'slice7-acceptance'
    );
    raise exception 'FAIL Labour/Other result was promoted outside the core FRAME';
  exception
    when check_violation then
      raise notice
        'PASS Labour/Other cannot bypass FRAME into issue/decision/action workflow (%)',
        sqlerrm;
  end;
end
$$;

reset role;

rollback;
