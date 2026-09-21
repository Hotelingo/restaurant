-- 0010 · Audited staff-read gate
-- Staff assignments never grant silent data access. A staff request must first
-- call authorize_staff_read(...) inside the same transaction; that function
-- verifies an active assignment, records the audit event and sets a transaction-
-- local scope grant that the existing RLS helpers then enforce.

create or replace function staff_read_scope_granted(
  target_org uuid,
  target_outlet uuid default null
)
returns boolean
language sql
stable
as $$
  select
    nullif(current_setting('app.staff_read_org', true), '')::uuid = target_org
    and (
      target_outlet is null
      or nullif(current_setting('app.staff_read_outlet', true), '')::uuid = target_outlet
    )
$$;

create or replace function has_staff_access(target_org uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select
    public.staff_read_scope_granted(target_org, null)
    and exists (
      select 1
      from public.staff_assignment s
      where s.organisation_id = target_org
        and s.user_id = public.current_app_user_id()
        and s.active
        and now() between s.starts_at and s.expires_at
    )
$$;

create or replace function has_staff_outlet_access(target_org uuid, target_outlet uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select
    public.staff_read_scope_granted(target_org, target_outlet)
    and exists (
      select 1
      from public.staff_assignment s
      where s.organisation_id = target_org
        and s.user_id = public.current_app_user_id()
        and s.active
        and now() between s.starts_at and s.expires_at
        and (s.outlet_id is null or s.outlet_id = target_outlet)
    )
$$;

create or replace function authorize_staff_read(
  p_organisation_id uuid,
  p_outlet_id uuid,
  p_action_code text,
  p_object_type text,
  p_object_id text default null,
  p_correlation_id text default null
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := public.current_app_user_id();
  v_assignment_id uuid;
begin
  if v_user_id is null then
    raise exception 'authenticated user context is required'
      using errcode = 'insufficient_privilege';
  end if;

  if p_action_code is null
     or p_action_code !~ '^STAFF_[A-Z0-9_]+$'
     or p_object_type is null
     or length(trim(p_object_type)) = 0 then
    raise exception 'staff read audit metadata is invalid'
      using errcode = 'invalid_parameter_value';
  end if;

  select s.id into v_assignment_id
  from public.staff_assignment s
  where s.organisation_id = p_organisation_id
    and s.user_id = v_user_id
    and s.active
    and now() between s.starts_at and s.expires_at
    and (
      p_outlet_id is null
      or s.outlet_id is null
      or s.outlet_id = p_outlet_id
    )
  order by
    case when s.outlet_id = p_outlet_id then 0 else 1 end,
    s.expires_at desc
  limit 1;

  if v_assignment_id is null then
    raise exception 'active staff assignment is required'
      using errcode = 'insufficient_privilege';
  end if;

  perform pg_catalog.set_config(
    'app.staff_read_org',
    p_organisation_id::text,
    true
  );
  perform pg_catalog.set_config(
    'app.staff_read_outlet',
    coalesce(p_outlet_id::text, ''),
    true
  );

  insert into public.audit_log (
    actor_user_id,
    organisation_id,
    outlet_id,
    action_code,
    object_type,
    object_id,
    correlation_id
  )
  values (
    v_user_id,
    p_organisation_id,
    p_outlet_id,
    p_action_code,
    p_object_type,
    coalesce(p_object_id, v_assignment_id::text),
    p_correlation_id
  );

  return true;
end
$$;

revoke all on function staff_read_scope_granted(uuid,uuid) from public;
revoke all on function authorize_staff_read(uuid,uuid,text,text,text,text) from public;

grant execute on function staff_read_scope_granted(uuid,uuid) to restaurant_app;
grant execute on function authorize_staff_read(uuid,uuid,text,text,text,text) to restaurant_app;
