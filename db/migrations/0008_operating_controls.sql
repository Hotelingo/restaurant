-- 0008 · Slice 1 operating controls
-- Additional outlets, controlled outlet settings, materiality versioning and audit-safe mutations.

alter table setting
  add constraint setting_supported_key_check
  check (
    key in (
      'primary_comparator',
      'tax_basis',
      'sign_convention',
      'popularity_factor',
      'reconciliation_pos_to_pl_pct',
      'reconciliation_purchases_to_pl_pct',
      'reconciliation_pos_item_to_ledger_pct',
      'food_benchmark_pct',
      'beverage_benchmark_pct',
      'gap_benchmark',
      'reporting_calendar',
      'display_preferences'
    )
  );

-- Approved materiality content is immutable. A controlled retirement may only fill
-- effective_to, leaving every approved business value unchanged.
create or replace function forbid_mutation_when_approved() returns trigger
language plpgsql as $$
begin
  if tg_op = 'DELETE' and old.approved_at is not null then
    raise exception
      'record is immutable: %.% was approved at %, so % is not permitted',
      tg_table_schema, tg_table_name, old.approved_at, tg_op
      using errcode = 'restrict_violation';
  end if;

  if tg_op = 'UPDATE' and old.approved_at is not null then
    if old.effective_to is null
       and new.effective_to is not null
       and new.effective_to >= old.effective_from
       and (to_jsonb(new) - 'effective_to') = (to_jsonb(old) - 'effective_to') then
      return new;
    end if;

    raise exception
      'record is immutable: %.% was approved at %, so % is not permitted',
      tg_table_schema, tg_table_name, old.approved_at, tg_op
      using errcode = 'restrict_violation';
  end if;

  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;


create or replace function create_outlet(
  p_organisation_id uuid,
  p_name text,
  p_code text,
  p_currency_code char(3),
  p_timezone text,
  p_fiscal_year_start_month smallint,
  p_idempotency_key text,
  p_correlation_id text default null
)
returns table (outlet_id uuid)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := public.current_app_user_id();
  v_outlet_id uuid;
  v_existing jsonb;
  v_operation text := 'outlet.create:' || p_organisation_id::text;
begin
  if v_user_id is null then
    raise exception 'authenticated user context is required'
      using errcode = 'insufficient_privilege';
  end if;

  if not public.has_full_admin_access(p_organisation_id) then
    raise exception 'organisation is not available in the current access context'
      using errcode = 'insufficient_privilege';
  end if;

  if p_idempotency_key is null or length(trim(p_idempotency_key)) < 8 then
    raise exception 'a valid idempotency key is required'
      using errcode = 'invalid_parameter_value';
  end if;

  insert into public.request_idempotency (user_id, operation, idempotency_key)
  values (v_user_id, v_operation, p_idempotency_key)
  on conflict (user_id, operation, idempotency_key) do nothing;

  select r.response_json into v_existing
  from public.request_idempotency r
  where r.user_id = v_user_id
    and r.operation = v_operation
    and r.idempotency_key = p_idempotency_key;

  if coalesce(v_existing ? 'outlet_id', false) then
    return query select (v_existing->>'outlet_id')::uuid;
    return;
  end if;

  insert into public.outlet (
    organisation_id, name, code, currency_code, timezone, fiscal_year_start_month
  )
  values (
    p_organisation_id,
    trim(p_name),
    nullif(trim(p_code), ''),
    upper(p_currency_code),
    trim(p_timezone),
    p_fiscal_year_start_month
  )
  returning id into v_outlet_id;

  update public.request_idempotency
  set response_json = jsonb_build_object('outlet_id', v_outlet_id)
  where user_id = v_user_id
    and operation = v_operation
    and idempotency_key = p_idempotency_key;

  insert into public.audit_log (
    actor_user_id, organisation_id, outlet_id,
    action_code, object_type, object_id, correlation_id
  )
  values (
    v_user_id, p_organisation_id, v_outlet_id,
    'OUTLET_CREATED', 'outlet', v_outlet_id::text, p_correlation_id
  );

  return query select v_outlet_id;
end
$$;

revoke all on function create_outlet(uuid,text,text,char(3),text,smallint,text,text) from public;
grant execute on function create_outlet(uuid,text,text,char(3),text,smallint,text,text)
  to restaurant_app;


create or replace function put_outlet_setting(
  p_outlet_id uuid,
  p_key text,
  p_value_json jsonb,
  p_idempotency_key text,
  p_correlation_id text default null
)
returns table (setting_id uuid)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := public.current_app_user_id();
  v_org_id uuid;
  v_setting_id uuid;
  v_before jsonb;
  v_after jsonb;
  v_existing jsonb;
  v_operation text := 'setting.put:' || p_outlet_id::text || ':' || p_key;
begin
  if v_user_id is null then
    raise exception 'authenticated user context is required'
      using errcode = 'insufficient_privilege';
  end if;

  select o.organisation_id into v_org_id
  from public.outlet o
  where o.id = p_outlet_id;

  if v_org_id is null
     or not public.has_org_role(v_org_id, array['admin']::public.app_role[])
     or not public.has_outlet_access(v_org_id, p_outlet_id) then
    raise exception 'outlet is not available in the current access context'
      using errcode = 'insufficient_privilege';
  end if;

  if p_key not in (
    'primary_comparator',
    'tax_basis',
    'sign_convention',
    'popularity_factor',
    'reconciliation_pos_to_pl_pct',
    'reconciliation_purchases_to_pl_pct',
    'reconciliation_pos_item_to_ledger_pct',
    'food_benchmark_pct',
    'beverage_benchmark_pct',
    'gap_benchmark',
    'reporting_calendar',
    'display_preferences'
  ) then
    raise exception 'unsupported setting key: %', p_key
      using errcode = 'invalid_parameter_value';
  end if;

  if p_idempotency_key is null or length(trim(p_idempotency_key)) < 8 then
    raise exception 'a valid idempotency key is required'
      using errcode = 'invalid_parameter_value';
  end if;

  insert into public.request_idempotency (user_id, operation, idempotency_key)
  values (v_user_id, v_operation, p_idempotency_key)
  on conflict (user_id, operation, idempotency_key) do nothing;

  select r.response_json into v_existing
  from public.request_idempotency r
  where r.user_id = v_user_id
    and r.operation = v_operation
    and r.idempotency_key = p_idempotency_key;

  if coalesce(v_existing ? 'setting_id', false) then
    return query select (v_existing->>'setting_id')::uuid;
    return;
  end if;

  select to_jsonb(s) into v_before
  from public.setting s
  where s.outlet_id = p_outlet_id and s.key = p_key
  for update;

  insert into public.setting (
    organisation_id, outlet_id, key, value_json, updated_by
  )
  values (
    v_org_id, p_outlet_id, p_key, p_value_json, v_user_id
  )
  on conflict (outlet_id, key) do update
    set value_json = excluded.value_json,
        updated_by = excluded.updated_by,
        updated_at = now()
  returning id into v_setting_id;

  select to_jsonb(s) into v_after
  from public.setting s
  where s.id = v_setting_id;

  update public.request_idempotency
  set response_json = jsonb_build_object('setting_id', v_setting_id)
  where user_id = v_user_id
    and operation = v_operation
    and idempotency_key = p_idempotency_key;

  insert into public.audit_log (
    actor_user_id, organisation_id, outlet_id,
    action_code, object_type, object_id,
    before_hash, after_hash, correlation_id
  )
  values (
    v_user_id, v_org_id, p_outlet_id,
    'SETTING_UPSERTED', 'setting', v_setting_id::text,
    case when v_before is null then null
         else encode(public.digest(convert_to(v_before::text,'UTF8'),'sha256'),'hex') end,
    encode(public.digest(convert_to(v_after::text,'UTF8'),'sha256'),'hex'),
    p_correlation_id
  );

  return query select v_setting_id;
end
$$;

revoke all on function put_outlet_setting(uuid,text,jsonb,text,text) from public;
grant execute on function put_outlet_setting(uuid,text,jsonb,text,text) to restaurant_app;


create or replace function create_materiality_version(
  p_outlet_id uuid,
  p_scope_type public.materiality_scope,
  p_absolute_threshold numeric,
  p_percent_threshold numeric,
  p_proposal_basis jsonb,
  p_recurrence_rule jsonb,
  p_risk_override_enabled boolean,
  p_effective_from date,
  p_idempotency_key text,
  p_correlation_id text default null
)
returns table (materiality_id uuid, source_kind public.materiality_source)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := public.current_app_user_id();
  v_org_id uuid;
  v_materiality_id uuid;
  v_source_kind public.materiality_source;
  v_existing jsonb;
  v_operation text := 'materiality.create:' || p_outlet_id::text || ':' || p_scope_type::text;
begin
  if v_user_id is null then
    raise exception 'authenticated user context is required'
      using errcode = 'insufficient_privilege';
  end if;

  select o.organisation_id into v_org_id
  from public.outlet o
  where o.id = p_outlet_id;

  if v_org_id is null
     or not public.has_org_role(v_org_id, array['admin']::public.app_role[])
     or not public.has_outlet_access(v_org_id, p_outlet_id) then
    raise exception 'outlet is not available in the current access context'
      using errcode = 'insufficient_privilege';
  end if;

  if p_absolute_threshold is null and p_percent_threshold is null then
    raise exception 'at least one materiality threshold is required'
      using errcode = 'check_violation';
  end if;
  if p_absolute_threshold is not null and p_absolute_threshold <= 0 then
    raise exception 'absolute threshold must be positive'
      using errcode = 'check_violation';
  end if;
  if p_percent_threshold is not null
     and (p_percent_threshold <= 0 or p_percent_threshold > 1) then
    raise exception 'percent threshold must be greater than zero and at most one'
      using errcode = 'check_violation';
  end if;

  if p_idempotency_key is null or length(trim(p_idempotency_key)) < 8 then
    raise exception 'a valid idempotency key is required'
      using errcode = 'invalid_parameter_value';
  end if;

  insert into public.request_idempotency (user_id, operation, idempotency_key)
  values (v_user_id, v_operation, p_idempotency_key)
  on conflict (user_id, operation, idempotency_key) do nothing;

  select r.response_json into v_existing
  from public.request_idempotency r
  where r.user_id = v_user_id
    and r.operation = v_operation
    and r.idempotency_key = p_idempotency_key;

  if coalesce(v_existing ? 'materiality_id', false) then
    return query
      select
        (v_existing->>'materiality_id')::uuid,
        (v_existing->>'source_kind')::public.materiality_source;
    return;
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_outlet_id::text || ':' || p_scope_type::text, 1902)
  );

  if exists (
    select 1
    from public.materiality_setting m
    where m.outlet_id = p_outlet_id
      and m.scope_type = p_scope_type
      and m.effective_from >= p_effective_from
  ) then
    raise exception 'effective date must be later than existing materiality versions'
      using errcode = 'check_violation';
  end if;

  update public.materiality_setting
  set effective_to = p_effective_from - 1
  where outlet_id = p_outlet_id
    and scope_type = p_scope_type
    and effective_to is null;

  if exists (
    select 1
    from public.materiality_setting m
    where m.outlet_id = p_outlet_id
      and m.scope_type = p_scope_type
  ) then
    v_source_kind := 'user_modified';
  else
    v_source_kind := 'user_confirmed';
  end if;

  insert into public.materiality_setting (
    organisation_id, outlet_id, scope_type,
    absolute_threshold, percent_threshold,
    source_kind, proposal_basis, recurrence_rule,
    risk_override_enabled, effective_from,
    approved_by, approved_at
  )
  values (
    v_org_id, p_outlet_id, p_scope_type,
    p_absolute_threshold, p_percent_threshold,
    v_source_kind,
    coalesce(p_proposal_basis, '{}'::jsonb),
    coalesce(p_recurrence_rule, '{}'::jsonb),
    coalesce(p_risk_override_enabled, false),
    p_effective_from,
    v_user_id, now()
  )
  returning id into v_materiality_id;

  update public.request_idempotency
  set response_json = jsonb_build_object(
    'materiality_id', v_materiality_id,
    'source_kind', v_source_kind::text
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
    'MATERIALITY_VERSION_CREATED', 'materiality_setting',
    v_materiality_id::text, p_correlation_id
  );

  return query select v_materiality_id, v_source_kind;
end
$$;

revoke all on function create_materiality_version(
  uuid,public.materiality_scope,numeric,numeric,jsonb,jsonb,boolean,date,text,text
) from public;
grant execute on function create_materiality_version(
  uuid,public.materiality_scope,numeric,numeric,jsonb,jsonb,boolean,date,text,text
) to restaurant_app;
