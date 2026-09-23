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
    'f0000000-0000-0000-0000-000000000401',
    'f0000000-0000-0000-0000-000000000402'
  )
    and status='completed'
    and completed_run_id is not null;

  if v_count <> 2 then
    raise exception 'FAIL Food Cost worker did not complete both queued requests: %',v_count;
  end if;

  select completed_run_id into v_first
  from calculation_request_queue
  where id='f0000000-0000-0000-0000-000000000401';

  select completed_run_id into v_second
  from calculation_request_queue
  where id='f0000000-0000-0000-0000-000000000402';

  if v_first = v_second then
    raise exception 'FAIL Food Cost rerun reused the prior calc_run id';
  end if;

  select count(distinct r.result_hash) into v_hashes
  from calculation_request_queue q
  join calc_run r on r.id=q.completed_run_id
  where q.id in (
    'f0000000-0000-0000-0000-000000000401',
    'f0000000-0000-0000-0000-000000000402'
  );

  if v_hashes <> 1 then
    raise exception 'FAIL identical Food Cost inputs produced different result hashes';
  end if;

  if not exists(
    select 1 from calc_run
    where id=v_first and engine_version='food-cost-v1'
  ) then
    raise exception 'FAIL Food Cost run engine_version mismatch';
  end if;

  if (select count(*) from calc_run_input where run_id=v_first) <> 3 then
    raise exception 'FAIL Food Cost run must pin exactly T2/T3/T4A inputs';
  end if;

  if (
    select array_agg(input_role order by input_role)
    from calc_run_input where run_id=v_first
  ) is distinct from array['item_cost','item_sales','stock']::text[] then
    raise exception 'FAIL Food Cost input roles mismatch';
  end if;

  if (
    select count(*)
    from calc_run_input i
    join import_batch b on b.id=i.batch_id
    where i.run_id=v_first
      and (
        (i.input_role='item_sales' and b.template_code='T2')
        or (i.input_role='stock' and b.template_code='T3')
        or (i.input_role='item_cost' and b.template_code='T4A')
      )
  ) <> 3 then
    raise exception 'FAIL Food Cost run did not pin exact canonical templates';
  end if;

  if (select count(*) from calc_result where run_id=v_first) <> 22
     or (select count(*) from calc_result where run_id=v_second) <> 22 then
    raise exception 'FAIL each Food Cost run must persist 22 results';
  end if;

  if (select count(*) from calc_dependency where run_id=v_first) <> 26
     or (select count(*) from calc_dependency where run_id=v_second) <> 26 then
    raise exception 'FAIL each Food Cost run must persist 26 dependency edges';
  end if;

  if (
    select value_numeric
    from calc_result
    where run_id=v_first
      and calc_id='FC.ACTUAL_CONSUMPTION'
      and grain_key->>'product_group'='food'
  ) <> 61343 then
    raise exception 'FAIL Food actual consumption mismatch';
  end if;

  if (
    select value_numeric
    from calc_result
    where run_id=v_first
      and calc_id='FC.EXPECTED_USAGE'
      and grain_key->>'product_group'='food'
  ) <> 60400 then
    raise exception 'FAIL Food expected usage mismatch';
  end if;

  if (
    select value_numeric
    from calc_result
    where run_id=v_first
      and calc_id='FC.ACTUAL_VS_EXPECTED'
      and grain_key->>'product_group'='food'
  ) <> 943 then
    raise exception 'FAIL Food actual-vs-expected mismatch';
  end if;

  if (
    select value_numeric
    from calc_result
    where run_id=v_first
      and calc_id='FC.BUDGET_BENCHMARK'
      and grain_key->>'product_group'='food'
  ) <> 57330 then
    raise exception 'FAIL Food budget benchmark mismatch';
  end if;

  if (
    select value_numeric
    from calc_result
    where run_id=v_first
      and calc_id='FC.BUDGET_GAP'
      and grain_key->>'product_group'='food'
  ) <> 4013 then
    raise exception 'FAIL Food budget gap mismatch';
  end if;

  if (
    select value_numeric
    from calc_result
    where run_id=v_first
      and calc_id='FC.MENU_MIX_EFFECT'
      and grain_key->>'product_group'='food'
  ) <> 3070 then
    raise exception 'FAIL Food menu-mix effect mismatch';
  end if;

  if (
    select value_numeric
    from calc_result
    where run_id=v_first
      and calc_id='FC.RESIDUAL'
      and grain_key->>'product_group'='food'
  ) <> 943 then
    raise exception 'FAIL Food residual mismatch';
  end if;

  if (
    select value_text
    from calc_result
    where run_id=v_first
      and calc_id='FC.DECISION_PATH'
      and grain_key->>'product_group'='food'
  ) <> 'MENU_ECONOMIC_HANDOFF' then
    raise exception 'FAIL Food decision path should hand off to menu economics';
  end if;

  if (
    select value_text
    from calc_result
    where run_id=v_first
      and calc_id='FC.DECISION_PATH'
      and grain_key->>'product_group'='beverage'
  ) <> 'NO_MATERIAL_GAP' then
    raise exception 'FAIL Beverage decision path should be no material gap';
  end if;

  if not exists(
    select 1
    from calc_result
    where run_id=v_first
      and calc_id='FC.EXPECTED_USAGE'
      and grain_key->>'product_group'='food'
      and exists(
        select 1 from jsonb_array_elements_text(input_refs) r
        where r like 'item_sales_fact:%'
      )
      and exists(
        select 1 from jsonb_array_elements_text(input_refs) r
        where r like 'item_cost_snapshot:%'
      )
  ) then
    raise exception 'FAIL expected usage lost T2/T4A direct fact lineage';
  end if;

  if not exists(
    select 1
    from calc_result
    where run_id=v_first
      and calc_id='FC.ACTUAL_CONSUMPTION'
      and grain_key->>'product_group'='food'
      and exists(
        select 1 from jsonb_array_elements_text(input_refs) r
        where r like 'stock_fact:%'
      )
  ) then
    raise exception 'FAIL actual consumption lost T3 direct fact lineage';
  end if;

  if not exists(
    select 1 from calc_run
    where id=v_second and supersedes_calc_run_id=v_first
  ) then
    raise exception 'FAIL Food Cost rerun does not supersede prior Food Cost snapshot';
  end if;

  if exists(
    select 1
    from calc_run r
    join calc_run prior on prior.id=r.supersedes_calc_run_id
    where r.id in (v_first,v_second)
      and prior.engine_version<>r.engine_version
  ) then
    raise exception 'FAIL Food Cost supersession crossed calculation modules';
  end if;

  if (
    select count(*)
    from calc_definition
    where definition_version='v1' and module='FC'
  ) <> 11 then
    raise exception 'FAIL FC v1 calculation registry should contain eleven definitions';
  end if;

  raise notice 'PASS Food Cost worker persists deterministic Amberside bridge with pinned T2/T3/T4A lineage';
end
$$;
