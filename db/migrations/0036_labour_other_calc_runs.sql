-- 0036 · Labour & Other Cost calculation persistence
-- Slice 7 / S7-3. Extends the immutable calc-run spine for T5 Labour detail
-- plus its accounting T1/T6 anchors and registers stable LB/OC definitions.

create or replace function guard_calc_run_input_insert()
returns trigger
language plpgsql
as $$
declare
  v_run public.calc_run%rowtype;
  v_batch public.import_batch%rowtype;
  v_has_canonical boolean := false;
begin
  select * into v_run from public.calc_run where id=new.run_id;

  if v_run.id is null
     or v_run.organisation_id<>new.organisation_id
     or v_run.outlet_id<>new.outlet_id
     or v_run.status not in ('queued','running') then
    raise exception 'calculation run does not accept inputs'
      using errcode='check_violation';
  end if;

  select * into v_batch from public.import_batch where id=new.batch_id;

  if v_batch.id is null
     or v_batch.organisation_id<>new.organisation_id
     or v_batch.outlet_id<>new.outlet_id
     or v_batch.period_id is distinct from v_run.period_id
     or v_batch.status<>'committed'
     or v_batch.profile_version_id is distinct from new.profile_version_id
     or v_batch.scenario<>new.scenario
     or v_batch.canonical_commit_hash is distinct from new.canonical_commit_hash then
    raise exception 'calc input must reference a committed canonical batch in the run context'
      using errcode='check_violation';
  end if;

  if new.input_role='actual' then
    if new.scenario<>'actual' or v_batch.template_code<>'T1'
       or v_run.engine_version not like 'pl-%' then
      raise exception 'PL actual input must be a committed actual T1 batch'
        using errcode='check_violation';
    end if;
    select exists(select 1 from public.financial_fact f where f.batch_id=v_batch.id)
      into v_has_canonical;

  elsif new.input_role='comparator' then
    if v_batch.template_code<>'T6'
       or v_run.engine_version not like 'pl-%'
       or v_run.comparator_scenario is null
       or new.scenario<>v_run.comparator_scenario then
      raise exception 'PL comparator input must be a committed T6 batch matching the run comparator'
        using errcode='check_violation';
    end if;
    select exists(select 1 from public.financial_fact f where f.batch_id=v_batch.id)
      into v_has_canonical;

  elsif new.input_role='item_sales' then
    if new.scenario<>'actual' or v_batch.template_code<>'T2'
       or v_run.engine_version not like 'food-cost-%' then
      raise exception 'Food Cost item_sales input must be a committed actual T2 batch'
        using errcode='check_violation';
    end if;
    select exists(select 1 from public.item_sales_fact f where f.batch_id=v_batch.id)
      into v_has_canonical;

  elsif new.input_role='stock' then
    if new.scenario<>'actual' or v_batch.template_code<>'T3'
       or v_run.engine_version not like 'food-cost-%' then
      raise exception 'Food Cost stock input must be a committed actual T3 batch'
        using errcode='check_violation';
    end if;
    select exists(select 1 from public.stock_fact f where f.batch_id=v_batch.id)
      into v_has_canonical;

  elsif new.input_role='item_cost' then
    if new.scenario<>'actual' or v_batch.template_code<>'T4A'
       or v_run.engine_version not like 'food-cost-%' then
      raise exception 'Food Cost item_cost input must be a committed actual T4A batch'
        using errcode='check_violation';
    end if;
    select exists(select 1 from public.item_cost_snapshot f where f.batch_id=v_batch.id)
      into v_has_canonical;

  elsif new.input_role='revenue_activity' then
    if new.scenario<>'actual' or v_batch.template_code<>'T1B'
       or v_run.engine_version not like 'revenue-%' then
      raise exception 'Revenue activity input must be a committed actual T1B batch'
        using errcode='check_violation';
    end if;
    select exists(select 1 from public.revenue_activity_fact f where f.batch_id=v_batch.id)
      into v_has_canonical;

  elsif new.input_role='channel_source' then
    if new.scenario<>'actual' or v_batch.template_code<>'T7'
       or v_run.engine_version not like 'revenue-%' then
      raise exception 'Revenue channel_source input must be a committed actual T7 batch'
        using errcode='check_violation';
    end if;
    select exists(select 1 from public.channel_source_fact f where f.batch_id=v_batch.id)
      into v_has_canonical;

  elsif new.input_role='financial_actual' then
    if new.scenario<>'actual' or v_batch.template_code<>'T1'
       or v_run.engine_version not like 'revenue-%' then
      raise exception 'Revenue financial_actual input must be a committed actual T1 batch'
        using errcode='check_violation';
    end if;
    select exists(select 1 from public.financial_fact f where f.batch_id=v_batch.id)
      into v_has_canonical;

  elsif new.input_role='labour_detail' then
    if new.scenario<>'actual' or v_batch.template_code<>'T5'
       or v_run.engine_version not like 'labour-other-%' then
      raise exception 'Labour detail input must be a committed actual T5 batch'
        using errcode='check_violation';
    end if;
    select exists(select 1 from public.labour_fact f where f.batch_id=v_batch.id)
      into v_has_canonical;

  elsif new.input_role='labour_financial_actual' then
    if new.scenario<>'actual' or v_batch.template_code<>'T1'
       or v_run.engine_version not like 'labour-other-%' then
      raise exception 'Labour/OC financial actual input must be a committed actual T1 batch'
        using errcode='check_violation';
    end if;
    select exists(select 1 from public.financial_fact f where f.batch_id=v_batch.id)
      into v_has_canonical;

  elsif new.input_role='labour_financial_comparator' then
    if v_batch.template_code<>'T6'
       or v_run.engine_version not like 'labour-other-%'
       or v_run.comparator_scenario is null
       or new.scenario<>v_run.comparator_scenario then
      raise exception 'Labour/OC comparator input must be committed T6 matching the run comparator'
        using errcode='check_violation';
    end if;
    select exists(select 1 from public.financial_fact f where f.batch_id=v_batch.id)
      into v_has_canonical;

  else
    raise exception 'unsupported calc input role %',new.input_role
      using errcode='check_violation';
  end if;

  if not v_has_canonical then
    raise exception 'calc input batch has no canonical facts for input role %',new.input_role
      using errcode='check_violation';
  end if;
  return new;
end
$$;


insert into calc_definition(
  calc_id,definition_version,module,name,unit,formula_key,active
)
values
  ('LB.ACTUAL_RATE','v1','LB','Actual labour rate','currency_per_hour','actual_cost/actual_hours',true),
  ('LB.COMPARATOR_RATE','v1','LB','Comparator labour rate','currency_per_hour','comparator_cost/comparator_hours',true),
  ('LB.HOURS_EFFECT_RAW','v1','LB','Labour hours effect','currency','(Ha-Hc)*Rc',true),
  ('LB.RATE_EFFECT_RAW','v1','LB','Labour rate effect','currency','Ha*(Ra-Rc)',true),
  ('LB.TOTAL_VARIANCE','v1','LB','Labour total cost variance','currency','Ca-Cc',true),
  ('LB.HOURS_PER_ACTIVITY','v1','LB','Hours per activity unit','hours_per_activity_unit','actual_hours/activity_units',true),
  ('LB.COST_PER_ACTIVITY','v1','LB','Labour cost per activity unit','currency_per_activity_unit','actual_cost/activity_units',true),
  ('LB.OVERTIME_HOURS','v1','LB','Overtime hours','hours','overtime_hours',true),
  ('LB.OVERTIME_RATE_EFFECT','v1','LB','Overtime rate effect','currency','overtime_hours*(actual_ot_rate-comparator_ot_rate)',true),
  ('OC.QUANTITY_EFFECT','v1','OC','Other-cost quantity effect','currency','(Qa-Qc)*Rc',true),
  ('OC.RATE_EFFECT','v1','OC','Other-cost rate effect','currency','Qa*(Ra-Rc)',true),
  ('OC.TOTAL_VARIANCE','v1','OC','Other-cost total variance','currency','Ca-Cc',true)
on conflict(calc_id,definition_version) do nothing;


create or replace function commit_labour_import_batch(
  p_batch_id uuid,
  p_idempotency_key text,
  p_correlation_id text default null,
  p_queue_calc boolean default false
)
returns table (
  committed_batch_id uuid,
  commit_status public.batch_status,
  fact_count bigint,
  commit_hash text,
  reused boolean
)
language plpgsql
security definer
set search_path=''
as $$
declare
  v_result record;
  v_batch public.import_batch%rowtype;
begin
  select * into v_result
  from public._commit_labour_import_batch(
    p_batch_id,p_idempotency_key,p_correlation_id,null
  );

  select * into v_batch from public.import_batch where id=p_batch_id;

  if p_queue_calc then
    if not exists(
      select 1 from public.data_readiness dr
      where dr.organisation_id=v_batch.organisation_id
        and dr.outlet_id=v_batch.outlet_id
        and dr.period_id=v_batch.period_id
        and dr.capability_code='labour_inputs'
        and dr.status='ready'
    ) then
      raise exception 'Labour/Other Cost calculation requires reconciled T5/T1 inputs'
        using errcode='check_violation';
    end if;

    insert into public.calculation_request_queue(
      organisation_id,outlet_id,period_id,source_batch_id,reason,status
    )
    select
      v_batch.organisation_id,v_batch.outlet_id,v_batch.period_id,
      v_batch.id,'labour_inputs_ready','pending'
    where not exists(
      select 1 from public.calculation_request_queue q
      where q.source_batch_id=v_batch.id
        and q.reason='labour_inputs_ready'
    );
  end if;

  return query select
    v_result.committed_batch_id,
    v_result.commit_status,
    v_result.fact_count,
    v_result.commit_hash,
    v_result.reused;
end
$$;

revoke all on function commit_labour_import_batch(uuid,text,text,boolean) from public;
grant execute on function commit_labour_import_batch(uuid,text,text,boolean)
  to restaurant_app;


create or replace function request_labour_other_calculation(
  p_outlet_id uuid,
  p_period_id uuid,
  p_idempotency_key text,
  p_correlation_id text default null
)
returns uuid
language plpgsql
security definer
set search_path=''
as $$
declare
  v_user_id uuid := public.current_app_user_id();
  v_org_id uuid;
  v_source_batch_id uuid;
  v_existing jsonb;
  v_operation text := 'labour_other.calculate:'||p_outlet_id::text||':'||p_period_id::text;
  v_request_id uuid;
begin
  if v_user_id is null then
    raise exception 'authenticated user context is required'
      using errcode='insufficient_privilege';
  end if;
  if p_idempotency_key is null or length(btrim(p_idempotency_key))<8 then
    raise exception 'a valid idempotency key is required'
      using errcode='invalid_parameter_value';
  end if;

  select o.organisation_id into v_org_id
  from public.outlet o
  join public.reporting_period rp
    on rp.organisation_id=o.organisation_id
   and rp.outlet_id=o.id and rp.id=p_period_id
  where o.id=p_outlet_id
    and public.has_org_role(
      o.organisation_id,
      array['admin','editor','setup_analyst']::public.app_role[]
    )
    and public.has_outlet_access(o.organisation_id,o.id);

  if v_org_id is null then
    raise exception 'outlet or reporting period is not available in the current access context'
      using errcode='insufficient_privilege';
  end if;

  if not exists(
    select 1 from public.data_readiness dr
    where dr.organisation_id=v_org_id
      and dr.outlet_id=p_outlet_id
      and dr.period_id=p_period_id
      and dr.capability_code='labour_inputs'
      and dr.status='ready'
  ) then
    raise exception 'Labour/Other Cost calculation requires reconciled T5/T1 inputs'
      using errcode='check_violation';
  end if;

  select b.id into v_source_batch_id
  from public.import_batch b
  where b.organisation_id=v_org_id
    and b.outlet_id=p_outlet_id
    and b.period_id=p_period_id
    and b.template_code='T5'
    and b.status='committed'
  order by b.committed_at desc,b.id desc
  limit 1;

  if v_source_batch_id is null then
    raise exception 'committed T5 Labour batch is required'
      using errcode='check_violation';
  end if;

  insert into public.request_idempotency(user_id,operation,idempotency_key)
  values(v_user_id,v_operation,p_idempotency_key)
  on conflict(user_id,operation,idempotency_key) do nothing;

  select response_json into v_existing
  from public.request_idempotency
  where user_id=v_user_id and operation=v_operation
    and idempotency_key=p_idempotency_key
  for update;

  if coalesce(v_existing ? 'request_id',false) then
    return (v_existing->>'request_id')::uuid;
  end if;

  insert into public.calculation_request_queue(
    organisation_id,outlet_id,period_id,source_batch_id,reason,status
  )
  values(
    v_org_id,p_outlet_id,p_period_id,v_source_batch_id,
    'labour_other_explicit_rerun','pending'
  )
  returning id into v_request_id;

  update public.request_idempotency
  set response_json=jsonb_build_object('request_id',v_request_id)
  where user_id=v_user_id and operation=v_operation
    and idempotency_key=p_idempotency_key;

  insert into public.audit_log(
    actor_user_id,organisation_id,outlet_id,
    action_code,object_type,object_id,correlation_id
  )
  values(
    v_user_id,v_org_id,p_outlet_id,
    'LABOUR_OTHER_CALCULATION_REQUESTED','calculation_request_queue',
    v_request_id::text,p_correlation_id
  );

  return v_request_id;
end
$$;

revoke all on function request_labour_other_calculation(uuid,uuid,text,text) from public;
grant execute on function request_labour_other_calculation(uuid,uuid,text,text)
  to restaurant_app;
