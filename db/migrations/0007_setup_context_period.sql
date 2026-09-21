-- 0007 · Idempotent setup context versions and reporting periods
-- These functions keep setup mutations server-authoritative while enforcing
-- the same membership/outlet rules as client RLS.

create or replace function create_restaurant_context_version(
  p_outlet_id uuid,
  p_service_style text,
  p_capacity_json jsonb,
  p_meal_periods_json jsonb,
  p_business_formats_json jsonb,
  p_customer_sources_json jsonb,
  p_recipe_costing_status text,
  p_labour_recording_basis text,
  p_source_tracking_quality text,
  p_evidence_maturity text,
  p_effective_from date,
  p_idempotency_key text,
  p_correlation_id text default null
)
returns table (context_id uuid, version_no int)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := public.current_app_user_id();
  v_org_id uuid;
  v_context_id uuid;
  v_version_no int;
  v_existing jsonb;
  v_operation text := 'setup.context:' || p_outlet_id::text;
begin
  if v_user_id is null then
    raise exception 'authenticated user context is required'
      using errcode = 'insufficient_privilege';
  end if;

  if p_idempotency_key is null or length(trim(p_idempotency_key)) < 8 then
    raise exception 'a valid idempotency key is required'
      using errcode = 'invalid_parameter_value';
  end if;

  select o.organisation_id into v_org_id
  from public.outlet o
  where o.id = p_outlet_id;

  if v_org_id is null
     or not public.has_org_role(v_org_id, array['admin','editor']::public.app_role[])
     or not public.has_outlet_access(v_org_id, p_outlet_id) then
    raise exception 'outlet is not available in the current access context'
      using errcode = 'insufficient_privilege';
  end if;

  insert into public.request_idempotency (user_id, operation, idempotency_key)
  values (v_user_id, v_operation, p_idempotency_key)
  on conflict (user_id, operation, idempotency_key) do nothing;

  select r.response_json into v_existing
  from public.request_idempotency r
  where r.user_id = v_user_id
    and r.operation = v_operation
    and r.idempotency_key = p_idempotency_key;

  if coalesce(v_existing ? 'context_id', false)
     and coalesce(v_existing ? 'version_no', false) then
    return query
      select (v_existing->>'context_id')::uuid,
             (v_existing->>'version_no')::int;
    return;
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_outlet_id::text, 1901)
  );

  select coalesce(max(rc.version_no), 0) + 1
    into v_version_no
  from public.restaurant_context rc
  where rc.outlet_id = p_outlet_id;

  insert into public.restaurant_context (
    organisation_id, outlet_id, version_no,
    service_style, capacity_json, meal_periods_json,
    business_formats_json, customer_sources_json,
    recipe_costing_status, labour_recording_basis,
    source_tracking_quality, evidence_maturity,
    effective_from, created_by
  )
  values (
    v_org_id, p_outlet_id, v_version_no,
    nullif(trim(p_service_style), ''),
    coalesce(p_capacity_json, '{}'::jsonb),
    coalesce(p_meal_periods_json, '[]'::jsonb),
    coalesce(p_business_formats_json, '[]'::jsonb),
    coalesce(p_customer_sources_json, '[]'::jsonb),
    nullif(trim(p_recipe_costing_status), ''),
    nullif(trim(p_labour_recording_basis), ''),
    nullif(trim(p_source_tracking_quality), ''),
    nullif(trim(p_evidence_maturity), ''),
    p_effective_from, v_user_id
  )
  returning id into v_context_id;

  update public.request_idempotency
  set response_json = jsonb_build_object(
    'context_id', v_context_id,
    'version_no', v_version_no
  )
  where user_id = v_user_id
    and operation = v_operation
    and idempotency_key = p_idempotency_key;

  insert into public.audit_log (
    actor_user_id, organisation_id, outlet_id,
    action_code, object_type, object_id, correlation_id
  )
  values (
    v_user_id, v_org_id, p_outlet_id,
    'CONTEXT_VERSION_CREATED', 'restaurant_context',
    v_context_id::text, p_correlation_id
  );

  return query select v_context_id, v_version_no;
end
$$;

revoke all on function create_restaurant_context_version(
  uuid,text,jsonb,jsonb,jsonb,jsonb,text,text,text,text,date,text,text
) from public;
grant execute on function create_restaurant_context_version(
  uuid,text,jsonb,jsonb,jsonb,jsonb,text,text,text,text,date,text,text
) to restaurant_app;


create or replace function create_reporting_period(
  p_outlet_id uuid,
  p_period_start date,
  p_period_end date,
  p_label text,
  p_idempotency_key text,
  p_correlation_id text default null
)
returns table (period_id uuid)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := public.current_app_user_id();
  v_org_id uuid;
  v_period_id uuid;
  v_existing jsonb;
  v_operation text := 'setup.period:' || p_outlet_id::text;
begin
  if v_user_id is null then
    raise exception 'authenticated user context is required'
      using errcode = 'insufficient_privilege';
  end if;

  if p_idempotency_key is null or length(trim(p_idempotency_key)) < 8 then
    raise exception 'a valid idempotency key is required'
      using errcode = 'invalid_parameter_value';
  end if;

  if p_period_end < p_period_start then
    raise exception 'period end must not precede period start'
      using errcode = 'check_violation';
  end if;

  select o.organisation_id into v_org_id
  from public.outlet o
  where o.id = p_outlet_id;

  if v_org_id is null
     or not public.has_org_role(v_org_id, array['admin','editor']::public.app_role[])
     or not public.has_outlet_access(v_org_id, p_outlet_id) then
    raise exception 'outlet is not available in the current access context'
      using errcode = 'insufficient_privilege';
  end if;

  insert into public.request_idempotency (user_id, operation, idempotency_key)
  values (v_user_id, v_operation, p_idempotency_key)
  on conflict (user_id, operation, idempotency_key) do nothing;

  select r.response_json into v_existing
  from public.request_idempotency r
  where r.user_id = v_user_id
    and r.operation = v_operation
    and r.idempotency_key = p_idempotency_key;

  if coalesce(v_existing ? 'period_id', false) then
    return query select (v_existing->>'period_id')::uuid;
    return;
  end if;

  insert into public.reporting_period (
    organisation_id, outlet_id, period_start, period_end, label
  )
  values (
    v_org_id, p_outlet_id, p_period_start, p_period_end, trim(p_label)
  )
  returning id into v_period_id;

  update public.request_idempotency
  set response_json = jsonb_build_object('period_id', v_period_id)
  where user_id = v_user_id
    and operation = v_operation
    and idempotency_key = p_idempotency_key;

  insert into public.audit_log (
    actor_user_id, organisation_id, outlet_id,
    action_code, object_type, object_id, correlation_id
  )
  values (
    v_user_id, v_org_id, p_outlet_id,
    'REPORTING_PERIOD_CREATED', 'reporting_period',
    v_period_id::text, p_correlation_id
  );

  return query select v_period_id;
end
$$;

revoke all on function create_reporting_period(uuid,date,date,text,text,text) from public;
grant execute on function create_reporting_period(uuid,date,date,text,text,text) to restaurant_app;
