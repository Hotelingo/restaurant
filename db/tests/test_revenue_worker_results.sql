\set ON_ERROR_STOP on

do $$
declare
  v_count bigint;
  v_hashes bigint;
  v_first uuid;
  v_second uuid;
begin
  select count(*) into v_count
  from calculation_request_queue
  where id in (
    '66000000-0000-0000-0000-000000000401',
    '66000000-0000-0000-0000-000000000402'
  )
    and status='completed'
    and completed_run_id is not null;

  if v_count<>2 then
    raise exception 'FAIL Revenue worker did not complete both queued requests: %',v_count;
  end if;

  select completed_run_id into v_first
  from calculation_request_queue
  where id='66000000-0000-0000-0000-000000000401';

  select completed_run_id into v_second
  from calculation_request_queue
  where id='66000000-0000-0000-0000-000000000402';

  if v_first=v_second then
    raise exception 'FAIL Revenue rerun reused prior calc_run id';
  end if;

  select count(distinct r.result_hash) into v_hashes
  from calculation_request_queue q
  join calc_run r on r.id=q.completed_run_id
  where q.id in (
    '66000000-0000-0000-0000-000000000401',
    '66000000-0000-0000-0000-000000000402'
  );

  if v_hashes<>1 then
    raise exception 'FAIL identical Revenue inputs produced different result hashes';
  end if;

  if not exists(
    select 1 from calc_run
    where id=v_first and engine_version='revenue-v1'
  ) then
    raise exception 'FAIL Revenue run engine_version mismatch';
  end if;

  if (select count(*) from calc_run_input where run_id=v_first)<>3 then
    raise exception 'FAIL Revenue run must pin exactly T1B/T7/T1 inputs';
  end if;

  if (
    select array_agg(input_role order by input_role)
    from calc_run_input where run_id=v_first
  ) is distinct from array[
    'channel_source','financial_actual','revenue_activity'
  ]::text[] then
    raise exception 'FAIL Revenue input roles mismatch';
  end if;

  if (
    select count(*)
    from calc_run_input i
    join import_batch b on b.id=i.batch_id
    where i.run_id=v_first
      and (
        (i.input_role='revenue_activity' and b.template_code='T1B')
        or (i.input_role='channel_source' and b.template_code='T7')
        or (i.input_role='financial_actual' and b.template_code='T1')
      )
  )<>3 then
    raise exception 'FAIL Revenue run did not pin exact canonical templates';
  end if;

  if (select count(*) from calc_result where run_id=v_first)<>39
     or (select count(*) from calc_result where run_id=v_second)<>39 then
    raise exception 'FAIL each Revenue run must persist 39 results';
  end if;

  if (select count(*) from calc_dependency where run_id=v_first)<>26
     or (select count(*) from calc_dependency where run_id=v_second)<>26 then
    raise exception 'FAIL each Revenue run must persist 26 dependency edges';
  end if;

  if (
    select sum(value_numeric)
    from calc_result
    where run_id=v_first and calc_id='RV.VOLUME_EFFECT'
  )<>-5360 then
    raise exception 'FAIL Revenue total volume effect mismatch';
  end if;

  if (
    select sum(value_numeric)
    from calc_result
    where run_id=v_first and calc_id='RV.SPEND_EFFECT'
  )<>1860 then
    raise exception 'FAIL Revenue total spend effect mismatch';
  end if;

  if (
    select sum(value_numeric)
    from calc_result
    where run_id=v_first and calc_id='RV.TOTAL_VARIANCE'
  )<>-3500 then
    raise exception 'FAIL Revenue total variance mismatch';
  end if;

  if (
    select value_numeric
    from calc_result
    where run_id=v_first
      and calc_id='RV.VOLUME_EFFECT'
      and grain_key->>'business_view_key'='Brunch'
  )<>1800 then
    raise exception 'FAIL Brunch volume effect mismatch';
  end if;

  if (
    select value_numeric
    from calc_result
    where run_id=v_first
      and calc_id='RV.SPEND_EFFECT'
      and grain_key->>'business_view_key'='Brunch'
  )<>700 then
    raise exception 'FAIL Brunch spend effect mismatch';
  end if;

  if (
    select value_numeric
    from calc_result
    where run_id=v_first
      and calc_id='CT.CONTRIBUTION'
      and grain_key->>'scope'='outlet'
  )<>67801 then
    raise exception 'FAIL outlet contribution mismatch';
  end if;

  if not exists(
    select 1
    from calc_result
    where run_id=v_first
      and calc_id='CT.CONTRIBUTION_PER_ACTIVITY_UNIT'
      and grain_key->>'scope'='outlet'
      and calculation_status='NOT_CALCULATED'
      and explanation_code='ACTIVITY_UNITS_MISSING'
      and value_numeric is null
  ) then
    raise exception 'FAIL mixed activity units were fabricated into outlet contribution/unit';
  end if;

  if (
    select value_numeric
    from calc_result
    where run_id=v_first
      and calc_id='CT.CONTRIBUTION_MARGIN_PCT'
      and grain_key->>'scope'='outlet'
  )<>0.2967 then
    raise exception 'FAIL contribution margin mismatch';
  end if;

  if not exists(
    select 1
    from calc_result
    where run_id=v_first
      and calc_id='RV.TOTAL_VARIANCE'
      and grain_key->>'business_view_key'='Brunch'
      and exists(
        select 1 from jsonb_array_elements_text(input_refs) ref
        where ref like 'revenue_activity_fact:%'
      )
  ) then
    raise exception 'FAIL RV result lost direct T1B fact lineage';
  end if;

  if not exists(
    select 1
    from calc_result
    where run_id=v_first
      and calc_id='CT.CONTRIBUTION'
      and exists(
        select 1 from jsonb_array_elements_text(input_refs) ref
        where ref like 'financial_fact:%'
      )
      and exists(
        select 1 from jsonb_array_elements_text(input_refs) ref
        where ref like 'channel_source_fact:%'
      )
  ) then
    raise exception 'FAIL CT result lost accounting/channel-source lineage';
  end if;

  if not exists(
    select 1
    from calc_run
    where id=v_second and supersedes_calc_run_id=v_first
  ) then
    raise exception 'FAIL Revenue rerun does not supersede prior Revenue snapshot';
  end if;

  if exists(
    select 1
    from calc_run r
    join calc_run prior on prior.id=r.supersedes_calc_run_id
    where r.id in (v_first,v_second)
      and prior.engine_version<>r.engine_version
  ) then
    raise exception 'FAIL Revenue supersession crossed calculation modules';
  end if;

  if (
    select count(*)
    from calc_definition
    where definition_version='v1'
      and module in ('RV','CT')
  )<>9 then
    raise exception 'FAIL RV/CT v1 calculation registry should contain nine definitions';
  end if;

  raise notice 'PASS Revenue worker persists deterministic Amberside RV/CT results with pinned T1B/T7/T1 lineage';
end
$$;
