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
    'e0000000-0000-0000-0000-000000000401',
    'e0000000-0000-0000-0000-000000000402'
  )
    and status='completed'
    and completed_run_id is not null;

  if v_count <> 2 then
    raise exception 'FAIL worker did not complete both queued requests: %', v_count;
  end if;

  select count(distinct completed_run_id) into v_count
  from calculation_request_queue
  where id in (
    'e0000000-0000-0000-0000-000000000401',
    'e0000000-0000-0000-0000-000000000402'
  );

  if v_count <> 2 then
    raise exception 'FAIL rerun did not create a distinct immutable calc run';
  end if;

  select count(distinct r.result_hash) into v_hashes
  from calculation_request_queue q
  join calc_run r on r.id=q.completed_run_id
  where q.id in (
    'e0000000-0000-0000-0000-000000000401',
    'e0000000-0000-0000-0000-000000000402'
  );

  if v_hashes <> 1 then
    raise exception 'FAIL repeated identical inputs produced different result hashes';
  end if;

  select completed_run_id into v_first
  from calculation_request_queue
  where id='e0000000-0000-0000-0000-000000000401';

  select completed_run_id into v_second
  from calculation_request_queue
  where id='e0000000-0000-0000-0000-000000000402';

  if (select count(*) from calc_result where run_id=v_first) <> 34
     or (select count(*) from calc_result where run_id=v_second) <> 34 then
    raise exception 'FAIL each completed PL run must persist 34 results including SEQUENCE';
  end if;

  if (select count(*) from calc_run_input where run_id=v_first) <> 2
     or (select count(*) from calc_run_input where run_id=v_second) <> 2 then
    raise exception 'FAIL each run must pin actual and comparator batches';
  end if;

  if (select count(*) from calc_dependency where run_id=v_first) <> 44
     or (select count(*) from calc_dependency where run_id=v_second) <> 44 then
    raise exception 'FAIL each run must persist all 44 PL + SEQUENCE dependency edges';
  end if;

  if (
    select value_numeric
    from calc_result
    where run_id=v_first
      and calc_id='PL.OPERATING_PROFIT'
      and grain_key->>'scenario'='actual'
  ) <> 53549 then
    raise exception 'FAIL actual Operating Profit mismatch';
  end if;

  if (
    select value_numeric
    from calc_result
    where run_id=v_first
      and calc_id='PL.OPERATING_PROFIT'
      and grain_key->>'scenario'='budget'
  ) <> 68220 then
    raise exception 'FAIL budget Operating Profit mismatch';
  end if;

  if (
    select value_numeric
    from calc_result
    where run_id=v_first
      and calc_id='PL.VAR.OPERATING_PROFIT'
  ) <> -14671 then
    raise exception 'FAIL Operating Profit variance mismatch';
  end if;

  if (
    select raw_delta
    from calc_result
    where run_id=v_first
      and calc_id='PL.VAR.PRODUCT_COST'
  ) <> 3374
  or (
    select profit_effect
    from calc_result
    where run_id=v_first
      and calc_id='PL.VAR.PRODUCT_COST'
  ) <> -3374 then
    raise exception 'FAIL raw_delta/profit_effect persistence mismatch';
  end if;

  if not exists (
    select 1
    from calc_result
    where run_id=v_first
      and calc_id='SEQ.FIRST_MATERIAL_MOVEMENT'
      and calculation_status='CALCULATED'
      and value_numeric is null
      and value_text='NET_SALES'
      and result_metadata->>'materiality_reason'='amount_test'
      and result_metadata->>'matched_rules'='amount_test'
      and result_metadata->>'impact'='-3500'
      and result_metadata->>'selection_basis'='materiality_only'
  ) then
    raise exception 'FAIL first material movement mismatch';
  end if;

  if not exists (
    select 1
    from calc_result
    where run_id=v_first
      and calc_id='PL.NET_SALES'
      and grain_key->>'scenario'='actual'
      and jsonb_array_length(input_refs) > 0
  ) then
    raise exception 'FAIL source calc result lost direct financial_fact lineage';
  end if;

  if not exists (
    select 1
    from calc_run
    where id=v_second
      and supersedes_calc_run_id=v_first
  ) then
    raise exception 'FAIL repeated completed run does not link to prior snapshot';
  end if;

  raise notice 'PASS durable worker completes two identical PL runs with stable hash and full lineage';
end
$$;
