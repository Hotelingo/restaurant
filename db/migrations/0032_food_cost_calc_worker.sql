-- 0032 · Food Cost calculation persistence and durable worker routing
-- Adds explicit calculation-module routing to the existing durable queue/run
-- model, preserves PL behavior, registers FC v1 definitions, and allows a
-- controlled FC request only when committed T2/T3/T4A inputs are ready.

alter table calculation_request_queue
  add column module text not null default 'PL'
  check (module in ('PL','FC'));

create index calculation_request_queue_module_available_idx
  on calculation_request_queue(module,available_at,created_at)
  where status='pending';

alter table calc_run
  add column module text not null default 'PL'
  check (module in ('PL','FC'));

create index calc_run_module_period_idx
  on calc_run(outlet_id,period_id,module,created_at desc);


-- Calc inputs are still immutable committed-batch snapshots, but the accepted
-- canonical fact family and input role now depend on run.module.
create or replace function guard_calc_run_input_insert()
returns trigger
language plpgsql
as $$
declare
  v_run public.calc_run%rowtype;
  v_batch public.import_batch%rowtype;
  v_has_canonical boolean := false;
begin
  select * into v_run
  from public.calc_run
  where id=new.run_id;

  if v_run.id is null
     or v_run.organisation_id<>new.organisation_id
     or v_run.outlet_id<>new.outlet_id
     or v_run.status not in ('queued','running') then
    raise exception 'calculation run does not accept inputs'
      using errcode='check_violation';
  end if;

  select * into v_batch
  from public.import_batch
  where id=new.batch_id;

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

  if v_run.module='PL' then
    if v_batch.template_code not in ('T1','T6') then
      raise exception 'PL calc run accepts T1/T6 inputs only'
        using errcode='check_violation';
    end if;

    select exists(
      select 1 from public.financial_fact ff where ff.batch_id=v_batch.id
    ) into v_has_canonical;

    if not v_has_canonical then
      raise exception 'PL calc input requires canonical financial facts'
        using errcode='check_violation';
    end if;

    if new.input_role='actual' then
      if v_batch.template_code<>'T1' or new.scenario<>'actual' then
        raise exception 'PL actual input must be committed T1 actual'
          using errcode='check_violation';
      end if;
    elsif new.input_role='comparator' then
      if v_batch.template_code<>'T6'
         or v_run.comparator_scenario is null
         or new.scenario<>v_run.comparator_scenario then
        raise exception 'PL comparator input must be T6 matching run comparator'
          using errcode='check_violation';
      end if;
    else
      raise exception 'PL calc input role must be actual or comparator'
        using errcode='check_violation';
    end if;

  elsif v_run.module='FC' then
    if v_run.comparator_scenario is not null then
      raise exception 'FC calc run stores comparator benchmark inside FC results, not calc_run comparator_scenario'
        using errcode='check_violation';
    end if;

    if new.scenario<>'actual' then
      raise exception 'FC canonical inputs use actual scenario'
        using errcode='check_violation';
    end if;

    if new.input_role='item_sales' and v_batch.template_code='T2' then
      select exists(
        select 1 from public.item_sales_fact f where f.batch_id=v_batch.id
      ) into v_has_canonical;
    elsif new.input_role='stock' and v_batch.template_code='T3' then
      select exists(
        select 1 from public.stock_fact f where f.batch_id=v_batch.id
      ) into v_has_canonical;
    elsif new.input_role='item_cost' and v_batch.template_code='T4A' then
      select exists(
        select 1 from public.item_cost_snapshot f where f.batch_id=v_batch.id
      ) into v_has_canonical;
    else
      raise exception 'FC calc inputs must be T2/item_sales, T3/stock or T4A/item_cost'
        using errcode='check_violation';
    end if;

    if not v_has_canonical then
      raise exception 'FC calc input requires its canonical fact family'
        using errcode='check_violation';
    end if;
  else
    raise exception 'unsupported calculation module %',v_run.module
      using errcode='check_violation';
  end if;

  return new;
end
$$;


insert into calc_definition(
  calc_id,definition_version,module,name,unit,formula_key,active
)
values
  ('FC.ACTUAL_CONSUMPTION','v1','FC','Actual Consumption','currency','opening+purchases-closing',true),
  ('FC.ACTUAL_COST_PCT','v1','FC','Actual Cost %','ratio','actual_consumption/product_revenue',true),
  ('FC.BUDGET_BENCHMARK','v1','FC','Budget Benchmark','currency','product_revenue*comparator_cost_pct',true),
  ('FC.BUDGET_GAP','v1','FC','Budget Gap','currency','actual_consumption-budget_benchmark',true),
  ('FC.EXPECTED_USAGE','v1','FC','Expected Usage','currency','sum:T2.units*T4A.approved_cost',true),
  ('FC.EXPECTED_COST_PCT','v1','FC','Expected Cost %','ratio','expected_usage/product_revenue',true),
  ('FC.MENU_MIX_EFFECT','v1','FC','Menu / Mix Effect','currency','expected_usage-budget_benchmark',true),
  ('FC.ACTUAL_VS_EXPECTED','v1','FC','Actual vs Expected','currency','actual_consumption-expected_usage',true),
  ('FC.DECISION_PATH','v1','FC','Food Cost Decision Path','decision_path','decision:actual_vs_expected',true),
  ('FC.SUPPORTED_DRIVER_TOTAL','v1','FC','Supported Driver Total','currency','sum:supported_driver_impacts',true),
  ('FC.RESIDUAL','v1','FC','Residual','currency','actual_vs_expected-supported_driver_total',true)
on conflict(calc_id,definition_version) do nothing;


-- Add module to the worker claim contract. Existing requests are PL by default.
drop function claim_calculation_request(text,integer,integer);

create function claim_calculation_request(
  p_worker_id text,
  p_lease_seconds integer default 300,
  p_max_attempts integer default 5
)
returns table(
  request_id uuid,
  organisation_id uuid,
  outlet_id uuid,
  period_id uuid,
  source_batch_id uuid,
  reason text,
  module text,
  attempt_no integer,
  lease_expires_at timestamptz
)
language plpgsql
security definer
set search_path=''
as $$
declare
  v_request_id uuid;
begin
  if p_worker_id is null or length(btrim(p_worker_id))=0 then
    raise exception 'worker id is required'
      using errcode='invalid_parameter_value';
  end if;
  if p_lease_seconds<30 or p_lease_seconds>3600 then
    raise exception 'lease seconds must be between 30 and 3600'
      using errcode='invalid_parameter_value';
  end if;
  if p_max_attempts<1 or p_max_attempts>20 then
    raise exception 'max attempts must be between 1 and 20'
      using errcode='invalid_parameter_value';
  end if;

  update public.calc_run r
  set status='failed',
      completed_at=now(),
      error_code='WORKER_LEASE_EXPIRED',
      error_message='Calculation worker lease expired before completion'
  from public.calculation_request_queue q
  where r.request_id=q.id
    and r.status='running'
    and q.status='running'
    and q.lease_expires_at is not null
    and q.lease_expires_at<now();

  update public.calculation_request_queue q
  set status='failed',
      completed_at=now(),
      last_error=coalesce(q.last_error,'Calculation worker lease expired after maximum attempts'),
      claimed_by=null,
      heartbeat_at=null,
      lease_expires_at=null
  where q.status='running'
    and q.lease_expires_at is not null
    and q.lease_expires_at<now()
    and q.attempts>=p_max_attempts;

  select q.id into v_request_id
  from public.calculation_request_queue q
  where (
      (q.status='pending' and q.available_at<=now())
      or (
        q.status='running'
        and q.lease_expires_at is not null
        and q.lease_expires_at<now()
      )
    )
    and q.attempts<p_max_attempts
  order by q.available_at,q.created_at,q.id
  for update skip locked
  limit 1;

  if v_request_id is null then
    return;
  end if;

  return query
  update public.calculation_request_queue q
  set status='running',
      attempts=q.attempts+1,
      started_at=coalesce(q.started_at,now()),
      completed_at=null,
      claimed_by=btrim(p_worker_id),
      heartbeat_at=now(),
      lease_expires_at=now()+make_interval(secs=>p_lease_seconds),
      last_error=null
  where q.id=v_request_id
  returning
    q.id,q.organisation_id,q.outlet_id,q.period_id,q.source_batch_id,
    q.reason,q.module,q.attempts,q.lease_expires_at;
end
$$;

revoke all on function claim_calculation_request(text,integer,integer) from public;


-- Explicit FC request: pin readiness at request time, then the worker pins the
-- exact latest committed T2/T3/T4A batches into calc_run_input.
create or replace function request_food_cost_calculation(
  p_outlet_id uuid,
  p_period_id uuid,
  p_idempotency_key text,
  p_correlation_id text default null
)
returns table(
  request_id uuid,
  reused boolean
)
language plpgsql
security definer
set search_path=''
as $$
declare
  v_user_id uuid := public.current_app_user_id();
  v_org_id uuid;
  v_t2 public.import_batch%rowtype;
  v_t3 public.import_batch%rowtype;
  v_t4a public.import_batch%rowtype;
  v_existing jsonb;
  v_request_id uuid;
  v_operation text := 'calc.food_cost.request:'||p_outlet_id::text||':'||p_period_id::text;
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
   and rp.outlet_id=o.id
   and rp.id=p_period_id
  where o.id=p_outlet_id;

  if v_org_id is null
     or not public.has_org_role(
       v_org_id,array['admin','editor','setup_analyst']::public.app_role[]
     )
     or not public.has_outlet_access(v_org_id,p_outlet_id) then
    raise exception 'food-cost calculation context is not available'
      using errcode='insufficient_privilege';
  end if;

  insert into public.request_idempotency(user_id,operation,idempotency_key)
  values(v_user_id,v_operation,p_idempotency_key)
  on conflict(user_id,operation,idempotency_key) do nothing;

  select response_json into v_existing
  from public.request_idempotency
  where user_id=v_user_id
    and operation=v_operation
    and idempotency_key=p_idempotency_key
  for update;

  if coalesce(v_existing ? 'request_id',false) then
    return query select (v_existing->>'request_id')::uuid,true;
    return;
  end if;

  select * into v_t2
  from public.import_batch b
  where b.organisation_id=v_org_id
    and b.outlet_id=p_outlet_id
    and b.period_id=p_period_id
    and b.template_code='T2'
    and b.scenario='actual'
    and b.status='committed'
  order by b.committed_at desc,b.id desc
  limit 1;

  select * into v_t3
  from public.import_batch b
  where b.organisation_id=v_org_id
    and b.outlet_id=p_outlet_id
    and b.period_id=p_period_id
    and b.template_code='T3'
    and b.scenario='actual'
    and b.status='committed'
  order by b.committed_at desc,b.id desc
  limit 1;

  select * into v_t4a
  from public.import_batch b
  where b.organisation_id=v_org_id
    and b.outlet_id=p_outlet_id
    and b.period_id=p_period_id
    and b.template_code='T4A'
    and b.scenario='actual'
    and b.status='committed'
  order by b.committed_at desc,b.id desc
  limit 1;

  if v_t2.id is null or v_t3.id is null or v_t4a.id is null then
    raise exception 'food-cost calculation requires committed T2, T3 and T4A inputs'
      using errcode='check_violation';
  end if;

  if not exists(
    select 1 from public.data_readiness dr
    where dr.organisation_id=v_org_id
      and dr.outlet_id=p_outlet_id
      and dr.period_id=p_period_id
      and dr.capability_code='food_cost_inputs'
      and dr.status='ready'
  ) then
    raise exception 'food-cost input readiness is not ready'
      using errcode='check_violation';
  end if;

  insert into public.calculation_request_queue(
    organisation_id,outlet_id,period_id,source_batch_id,reason,module
  )
  values(
    v_org_id,p_outlet_id,p_period_id,v_t3.id,
    'food_cost_explicit_request','FC'
  )
  returning id into v_request_id;

  insert into public.audit_log(
    actor_user_id,organisation_id,outlet_id,
    action_code,object_type,object_id,correlation_id
  )
  values(
    v_user_id,v_org_id,p_outlet_id,
    'FOOD_COST_CALCULATION_REQUESTED','calculation_request',
    v_request_id::text,p_correlation_id
  );

  update public.request_idempotency
  set response_json=jsonb_build_object('request_id',v_request_id)
  where user_id=v_user_id
    and operation=v_operation
    and idempotency_key=p_idempotency_key;

  return query select v_request_id,false;
end
$$;

revoke all on function request_food_cost_calculation(uuid,uuid,text,text) from public;
grant execute on function request_food_cost_calculation(uuid,uuid,text,text)
  to restaurant_app;
