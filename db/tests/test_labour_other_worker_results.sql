\set ON_ERROR_STOP on

do $$
declare
  v_count bigint;
  v_hashes bigint;
  v_first uuid;
  v_second uuid;
  v_bad_grains bigint;
begin
  select count(*) into v_count
  from calculation_request_queue
  where id in (
    '77000000-0000-0000-0000-000000000401',
    '77000000-0000-0000-0000-000000000402'
  )
    and status='completed'
    and completed_run_id is not null;

  if v_count<>2 then
    raise exception 'FAIL Labour/Other worker did not complete both queued requests: %',v_count;
  end if;

  select completed_run_id into v_first
  from calculation_request_queue
  where id='77000000-0000-0000-0000-000000000401';

  select completed_run_id into v_second
  from calculation_request_queue
  where id='77000000-0000-0000-0000-000000000402';

  if v_first=v_second then
    raise exception 'FAIL Labour/Other rerun reused prior calc_run id';
  end if;

  select count(distinct r.result_hash) into v_hashes
  from calculation_request_queue q
  join calc_run r on r.id=q.completed_run_id
  where q.id in (
    '77000000-0000-0000-0000-000000000401',
    '77000000-0000-0000-0000-000000000402'
  );

  if v_hashes<>1 then
    raise exception 'FAIL identical Labour/Other inputs produced different result hashes';
  end if;

  if not exists(
    select 1 from calc_run
    where id=v_first
      and engine_version='labour-other-v1'
      and comparator_scenario='budget'
  ) then
    raise exception 'FAIL Labour/Other run engine/comparator mismatch';
  end if;

  if (select count(*) from calc_run_input where run_id=v_first)<>3 then
    raise exception 'FAIL Labour/Other run must pin exactly T5/T1/T6 inputs';
  end if;

  if (
    select array_agg(input_role order by input_role)
    from calc_run_input where run_id=v_first
  ) is distinct from array[
    'labour_detail',
    'labour_financial_actual',
    'labour_financial_comparator'
  ]::text[] then
    raise exception 'FAIL Labour/Other input roles mismatch';
  end if;

  if (
    select count(*)
    from calc_run_input i
    join import_batch b on b.id=i.batch_id
    join source_file sf on sf.id=b.source_file_id
    where i.run_id=v_first
      and b.status='committed'
      and b.canonical_commit_hash=i.canonical_commit_hash
      and sf.sha256 ~ '^[0-9a-f]{64}$'
      and (
        (i.input_role='labour_detail' and b.template_code='T5')
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
  )<>3 then
    raise exception 'FAIL Labour/Other run lost exact T5/T1/T6 source/commit lineage';
  end if;

  if (select count(*) from calc_result where run_id=v_first)<>54
     or (select count(*) from calc_result where run_id=v_second)<>54 then
    raise exception 'FAIL each Labour/Other run must persist 54 results';
  end if;

  if (select count(*) from calc_dependency where run_id=v_first)<>21
     or (select count(*) from calc_dependency where run_id=v_second)<>21 then
    raise exception 'FAIL each Labour/Other run must persist 21 dependency edges';
  end if;

  if (
    select count(*)
    from calc_result
    where run_id=v_first and calc_id='LB.TOTAL_VARIANCE'
  )<>5 then
    raise exception 'FAIL Labour run must contain five role groups';
  end if;

  if (
    select sum(value_numeric)
    from calc_result
    where run_id=v_first and calc_id='LB.TOTAL_VARIANCE'
  )<>5205 then
    raise exception 'FAIL Amberside Labour total variance mismatch';
  end if;

  select count(*) into v_bad_grains
  from (
    select
      grain_key,
      max(value_numeric) filter(where calc_id='LB.HOURS_EFFECT_RAW') as hours_effect,
      max(value_numeric) filter(where calc_id='LB.RATE_EFFECT_RAW') as rate_effect,
      max(value_numeric) filter(where calc_id='LB.TOTAL_VARIANCE') as total_variance
    from calc_result
    where run_id=v_first
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

  if not exists(
    select 1
    from calc_result
    where run_id=v_first
      and calc_id='LB.COST_PER_ACTIVITY'
      and grain_key->>'role_group'='Kitchen prep'
      and grain_key->>'activity_basis'='total_covers'
      and result_metadata->>'activity_basis'='total_covers'
  ) or not exists(
    select 1
    from calc_result
    where run_id=v_first
      and calc_id='LB.COST_PER_ACTIVITY'
      and grain_key->>'role_group'='Management / shared'
      and grain_key->>'activity_basis'='total_covers'
      and result_metadata->>'activity_basis'='total_covers'
  ) then
    raise exception 'FAIL repeated total-covers Labour denominators lost activity_basis';
  end if;

  if (
    select count(*)
    from calc_result
    where run_id=v_first
      and calc_id='LB.OVERTIME_RATE_EFFECT'
      and calculation_status='NOT_CALCULATED'
      and explanation_code='OVERTIME_RATE_EVIDENCE_MISSING'
      and value_numeric is null
  )<>5 then
    raise exception 'FAIL unsupported overtime-rate evidence was converted into a number';
  end if;

  if exists(
    select 1
    from calc_result
    where run_id=v_first
      and upper(coalesce(value_text,'')) like '%OVERSTAFFED%'
  ) then
    raise exception 'FAIL Labour engine inferred OVERSTAFFED';
  end if;

  if (
    select value_numeric
    from calc_result
    where run_id=v_first
      and calc_id='OC.TOTAL_VARIANCE'
      and grain_key->>'ladder_code'='OTHER_DIRECT_OPERATING'
  )<>200 then
    raise exception 'FAIL Other Direct Operating total variance mismatch';
  end if;

  if (
    select value_numeric
    from calc_result
    where run_id=v_first
      and calc_id='OC.TOTAL_VARIANCE'
      and grain_key->>'ladder_code'='SHARED_RESTAURANT_COST'
  )<>2092 then
    raise exception 'FAIL Shared Restaurant Cost total variance mismatch';
  end if;

  if (
    select value_numeric
    from calc_result
    where run_id=v_first
      and calc_id='OC.TOTAL_VARIANCE'
      and grain_key->>'ladder_code'='OWNER_STRUCTURAL_COST'
  )<>0 then
    raise exception 'FAIL Owner Structural Cost total variance mismatch';
  end if;

  if (
    select count(*)
    from calc_result
    where run_id=v_first
      and calc_id in ('OC.QUANTITY_EFFECT','OC.RATE_EFFECT')
      and calculation_status='NOT_CALCULATED'
      and explanation_code='QUANTITY_RATE_EVIDENCE_MISSING'
      and value_numeric is null
  )<>6 then
    raise exception 'FAIL unsupported OC quantity/rate effects were fabricated';
  end if;

  if not exists(
    select 1
    from calc_result
    where run_id=v_first
      and calc_id='LB.TOTAL_VARIANCE'
      and exists(
        select 1 from jsonb_array_elements_text(input_refs) ref
        where ref like 'labour_fact:%'
      )
  ) then
    raise exception 'FAIL Labour result lost direct T5 fact lineage';
  end if;

  if not exists(
    select 1
    from calc_result
    where run_id=v_first
      and calc_id='OC.TOTAL_VARIANCE'
      and grain_key->>'ladder_code'='SHARED_RESTAURANT_COST'
      and (
        select count(*)
        from jsonb_array_elements_text(input_refs) ref
        where ref like 'financial_fact:%'
      )=2
  ) then
    raise exception 'FAIL OC total variance lost T1/T6 financial fact lineage';
  end if;

  if not exists(
    select 1
    from calc_run
    where id=v_second and supersedes_calc_run_id=v_first
  ) then
    raise exception 'FAIL Labour/Other rerun does not supersede prior module snapshot';
  end if;

  if exists(
    select 1
    from calc_run r
    join calc_run prior on prior.id=r.supersedes_calc_run_id
    where r.id in (v_first,v_second)
      and prior.engine_version<>r.engine_version
  ) then
    raise exception 'FAIL Labour/Other supersession crossed calculation modules';
  end if;

  if (
    select count(*)
    from calc_definition
    where definition_version='v1'
      and module in ('LB','OC')
  )<>12 then
    raise exception 'FAIL LB/OC v1 calculation registry should contain twelve definitions';
  end if;

  raise notice 'PASS Labour/Other worker persists deterministic LB/OC results with pinned T5/T1/T6 lineage';
end
$$;
