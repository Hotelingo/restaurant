\set ON_ERROR_STOP on
begin;

create or replace function s6_assert_rejects(stmt text, label text)
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
  v_run uuid;
  v_r1_review uuid;
  v_r1_pack uuid;
  v_r1_run uuid;
  v_bad_grains bigint;
begin
  select q.completed_run_id into v_run
  from calculation_request_queue q
  join outlet o on o.id=q.outlet_id
  where o.code='RVWORKER'
    and q.status='completed'
    and q.reason like 'revenue%'
  order by q.created_at desc,q.id desc
  limit 1;

  if v_run is null then
    raise exception 'FAIL Slice 6 has no completed Revenue run';
  end if;

  if (select engine_version from calc_run where id=v_run) <> 'revenue-v1' then
    raise exception 'FAIL Slice 6 Revenue run is not revenue-v1';
  end if;

  if (
    select count(*)
    from calc_result
    where run_id=v_run
      and calc_id='RV.TOTAL_VARIANCE'
  ) <> 6 then
    raise exception 'FAIL Slice 6 must contain six Revenue business-view grains';
  end if;

  if (
    select sum(value_numeric)
    from calc_result
    where run_id=v_run
      and calc_id='RV.VOLUME_EFFECT'
  ) <> -5360 then
    raise exception 'FAIL Amberside Revenue volume effect is not -5360';
  end if;

  if (
    select sum(value_numeric)
    from calc_result
    where run_id=v_run
      and calc_id='RV.SPEND_EFFECT'
  ) <> 1860 then
    raise exception 'FAIL Amberside Revenue spend effect is not +1860';
  end if;

  if (
    select sum(value_numeric)
    from calc_result
    where run_id=v_run
      and calc_id='RV.TOTAL_VARIANCE'
  ) <> -3500 then
    raise exception 'FAIL Amberside Revenue total variance is not -3500';
  end if;

  select count(*) into v_bad_grains
  from (
    select
      grain_key,
      max(value_numeric) filter(where calc_id='RV.VOLUME_EFFECT') as volume_effect,
      max(value_numeric) filter(where calc_id='RV.SPEND_EFFECT') as spend_effect,
      max(value_numeric) filter(where calc_id='RV.TOTAL_VARIANCE') as total_variance
    from calc_result
    where run_id=v_run
      and calc_id in (
        'RV.VOLUME_EFFECT',
        'RV.SPEND_EFFECT',
        'RV.TOTAL_VARIANCE'
      )
    group by grain_key
  ) g
  where volume_effect is null
     or spend_effect is null
     or total_variance is null
     or volume_effect + spend_effect <> total_variance;

  if v_bad_grains<>0 then
    raise exception 'FAIL % Revenue grains violate volume + spend = total',v_bad_grains;
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
        (i.input_role='revenue_activity' and b.template_code='T1B')
        or (i.input_role='channel_source' and b.template_code='T7')
        or (i.input_role='financial_actual' and b.template_code='T1')
      )
  ) <> 3 then
    raise exception 'FAIL Revenue run lost exact T1B/T7/T1 source/commit lineage';
  end if;

  if (
    select value_numeric
    from calc_result
    where run_id=v_run
      and calc_id='CT.CONTRIBUTION'
      and grain_key->>'scope'='outlet'
  ) <> 67801 then
    raise exception 'FAIL Amberside outlet contribution is not 67801';
  end if;

  if not exists(
    select 1
    from calc_result
    where run_id=v_run
      and calc_id='CT.CONTRIBUTION_PER_ACTIVITY_UNIT'
      and grain_key->>'scope'='outlet'
      and calculation_status='NOT_CALCULATED'
      and explanation_code='ACTIVITY_UNITS_MISSING'
      and value_numeric is null
  ) then
    raise exception 'FAIL mixed covers/orders/guests were aggregated into a fabricated contribution/unit';
  end if;

  if (
    select value_numeric
    from calc_result
    where run_id=v_run
      and calc_id='CT.CONTRIBUTION_MARGIN_PCT'
      and grain_key->>'scope'='outlet'
  ) <> 0.2967 then
    raise exception 'FAIL Amberside contribution margin is not 0.2967';
  end if;

  if not exists(
    select 1
    from calc_result
    where run_id=v_run
      and calc_id='RV.TOTAL_VARIANCE'
      and exists(
        select 1
        from jsonb_array_elements_text(input_refs) ref
        where ref like 'revenue_activity_fact:%'
      )
  ) then
    raise exception 'FAIL Revenue bridge lost direct T1B fact refs';
  end if;

  if not exists(
    select 1
    from calc_result
    where run_id=v_run
      and calc_id='CT.CONTRIBUTION'
      and exists(
        select 1
        from jsonb_array_elements_text(input_refs) ref
        where ref like 'financial_fact:%'
      )
      and exists(
        select 1
        from jsonb_array_elements_text(input_refs) ref
        where ref like 'channel_source_fact:%'
      )
  ) then
    raise exception 'FAIL contribution lost T1 accounting / corroborating T7 lineage';
  end if;

  if exists(
    select 1 from calc_run
    where id=v_run and review_id is not null
  ) then
    raise exception 'FAIL Revenue run bypassed the core review anchor';
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
    'PASS Slice 6 six-grain RV/CT math + T1B/T7/T1 lineage + existing signed R1 spine';
end
$$;


-- Build a temporary review context solely to prove that a Revenue supporting
-- snapshot cannot become the core review FRAME.
insert into restaurant_context(
  id,organisation_id,outlet_id,version_no,
  service_style,capacity_json,meal_periods_json,business_formats_json,
  customer_sources_json,recipe_costing_status,labour_recording_basis,
  source_tracking_quality,evidence_maturity,effective_from,created_by
)
select
  '66000000-0000-0000-0000-000000000050',
  o.organisation_id,o.id,1,
  'casual dining','{}','[]','[]','[]',
  'recipe_costed','hours','structured','validated',
  '2026-07-01',
  '66000000-0000-0000-0000-000000000001'
from outlet o
where o.code='RVWORKER'
  and not exists(
    select 1 from restaurant_context rc
    where rc.outlet_id=o.id and rc.version_no=1
  );

set role restaurant_app;
select set_config('app.user_id','66000000-0000-0000-0000-000000000001',true);

do $$
declare
  v_review uuid;
  v_run uuid;
begin
  select created_review_id into v_review
  from public.create_review(
    (select id from public.outlet where code='RVWORKER'),
    '66000000-0000-0000-0000-000000000010',
    's6-rv-review-create',
    'slice6-acceptance'
  );

  select r.id into v_run
  from public.calc_run r
  where r.outlet_id=(select id from public.outlet where code='RVWORKER')
    and r.status='completed'
    and r.engine_version='revenue-v1'
  order by r.completed_at desc,r.id desc
  limit 1;

  begin
    perform *
    from public.frame_review(
      v_review,
      '66000000-0000-0000-0000-000000000050',
      v_run,
      'budget'::public.scenario_code,
      's6-rv-frame-attempt',
      'slice6-acceptance'
    );
    raise exception 'FAIL Revenue run was accepted as the core review FRAME';
  exception
    when check_violation then
      raise notice 'PASS Revenue run cannot be used as core review FRAME (%)',sqlerrm;
  end;

  if (select status::text from public.review where id=v_review) <> 'draft' then
    raise exception 'FAIL rejected Revenue FRAME mutated the draft review';
  end if;
end
$$;

reset role;


select s6_assert_rejects(
  $q$
    update review rv
    set
      status='in_review',
      comparator_scenario='budget',
      context_version_id='66000000-0000-0000-0000-000000000050',
      materiality_snapshot=cr.settings_snapshot->'materiality',
      active_calc_run_id=cr.id,
      frame_confirmed_at=now(),
      updated_at=now()
    from calc_run cr,outlet o
    where rv.outlet_id=o.id
      and o.code='RVWORKER'
      and rv.status='draft'
      and cr.outlet_id=o.id
      and cr.period_id=rv.period_id
      and cr.engine_version='revenue-v1'
      and cr.status='completed'
  $q$,
  'database rejects direct Revenue review FRAME bypass'
);


set role restaurant_app;
select set_config('app.user_id','66000000-0000-0000-0000-000000000001',true);

do $$
declare
  v_review uuid;
  v_result uuid;
begin
  select r.id into v_review
  from public.review r
  join public.outlet o on o.id=r.outlet_id
  where o.code='RVWORKER'
    and r.status='draft'
  order by r.created_at desc
  limit 1;

  select cr.id into v_result
  from public.calc_result cr
  join public.calc_run run on run.id=cr.run_id
  where run.outlet_id=(select id from public.outlet where code='RVWORKER')
    and run.engine_version='revenue-v1'
    and run.status='completed'
    and cr.calc_id='RV.TOTAL_VARIANCE'
    and cr.grain_key->>'business_view_key'='Brunch'
  order by run.completed_at desc
  limit 1;

  if v_review is null or v_result is null then
    raise exception 'FAIL Slice 6 shortlist guard fixture is incomplete';
  end if;

  begin
    perform *
    from public.add_review_issue(
      v_review,
      v_result,
      'Revenue diagnostic',
      'Slice 6 bypass test',
      's6-rv-issue-attempt',
      'slice6-acceptance'
    );
    raise exception 'FAIL Revenue result was promoted outside the core FRAME';
  exception
    when check_violation then
      raise notice
        'PASS Revenue cannot bypass FRAME into issue/decision/action workflow (%)',
        sqlerrm;
  end;
end
$$;

reset role;

drop function s6_assert_rejects(text,text);

rollback;
