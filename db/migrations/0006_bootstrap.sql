-- 0006 · Atomic first-organisation bootstrap
-- SECURITY DEFINER intentionally bypasses RLS only for this constrained first setup.
create or replace function bootstrap_organisation(
  p_organisation_name text,
  p_organisation_slug text,
  p_outlet_name text,
  p_outlet_code text,
  p_currency_code char(3),
  p_timezone text,
  p_fiscal_year_start_month smallint,
  p_correlation_id text default null
)
returns table (organisation_id uuid, outlet_id uuid)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := public.current_app_user_id();
  v_org_id uuid;
  v_outlet_id uuid;
begin
  if v_user_id is null then
    raise exception 'authenticated user context is required'
      using errcode = 'insufficient_privilege';
  end if;

  if not exists (
    select 1 from neon_auth."user" u where u.id = v_user_id
  ) then
    raise exception 'authenticated user does not exist'
      using errcode = 'foreign_key_violation';
  end if;

  if exists (
    select 1
    from public.membership m
    where m.user_id = v_user_id
      and m.active
  ) then
    raise exception 'authenticated user already has an active organisation membership'
      using errcode = 'unique_violation';
  end if;

  insert into public.organisation (name, slug)
  values (trim(p_organisation_name), lower(trim(p_organisation_slug)))
  returning id into v_org_id;

  insert into public.membership (
    organisation_id, user_id, role, outlet_scope_mode
  )
  values (
    v_org_id, v_user_id, 'admin', 'all_outlets'
  );

  insert into public.outlet (
    organisation_id, name, code, currency_code, timezone, fiscal_year_start_month
  )
  values (
    v_org_id,
    trim(p_outlet_name),
    nullif(trim(p_outlet_code), ''),
    upper(p_currency_code),
    p_timezone,
    p_fiscal_year_start_month
  )
  returning id into v_outlet_id;

  insert into public.audit_log (
    actor_user_id, organisation_id, outlet_id,
    action_code, object_type, object_id, correlation_id
  )
  values (
    v_user_id, v_org_id, v_outlet_id,
    'SETUP_BOOTSTRAP', 'organisation', v_org_id::text, p_correlation_id
  );

  return query select v_org_id, v_outlet_id;
end
$$;

revoke all on function bootstrap_organisation(
  text,text,text,text,char(3),text,smallint,text
) from public;

grant execute on function bootstrap_organisation(
  text,text,text,text,char(3),text,smallint,text
) to restaurant_app;
